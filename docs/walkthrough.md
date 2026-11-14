# Playbook walkthrough

For day-to-day operations see [maintenance.md](maintenance.md).

This document explains every part of the playbook: what each task does, why it is there, and how to check it. Read it side by side with the code. Task names here match the `name:` fields in the roles, so you can search for them.

Contents:

1. [How a run works](#1-how-a-run-works)
2. [ansible.cfg](#2-ansiblecfg)
3. [Inventory and variables](#3-inventory-and-variables)
4. [Role: base](#4-role-base)
5. [Role: hardening](#5-role-hardening)
6. [Role: network](#6-role-network)
7. [Role: firewall_host](#7-role-firewall_host)
8. [Role: docker_rootless](#8-role-docker_rootless)
9. [Role: notify](#9-role-notify)
10. [Role: clamav](#10-role-clamav)
11. [Role: monitoring](#11-role-monitoring)
12. [Role: integrity](#12-role-integrity)
13. [Role: yara](#13-role-yara)
14. [Role: backup](#14-role-backup)
15. [Role: traefik](#15-role-traefik)
16. [Role: vaultwarden](#16-role-vaultwarden)
17. [Role: immich](#17-role-immich)
18. [Role: opencloud](#18-role-opencloud)
19. [Role: paperless](#19-role-paperless)
20. [Role: uptime_kuma](#20-role-uptime_kuma)
21. [Renovate (image updates)](#21-renovate-image-updates)
22. [Role: update_os](#22-role-update_os)
23. [The pre-commit hook](#23-the-pre-commit-hook)
24. [Files the playbook creates on the server](#24-files-the-playbook-creates-on-the-server)
25. [Known limits and points to review](#25-known-limits-and-points-to-review)
26. [How it was tested](#26-how-it-was-tested)

---

## 1. How a run works

### site.yml

There is a single playbook, `site.yml`, with a single play that targets the `prod_servers` group.

1. **Fact gathering** (`gather_facts: true`). Ansible collects information about the server (distribution, interfaces, architecture, virtualization) into `ansible_facts`. Several roles use these facts.
2. **Pre-task "Check that the target runs Debian 13"**. It stops the play on any other system. It carries the `always` tag, so it also runs when you select other tags.
3. **Roles**, in order: `base`, `hardening`, `network`, `firewall_host`, `docker_rootless`, `clamav`, `monitoring`, `integrity`, `yara`, `backup`, then the container services (`traefik`, `vaultwarden`, `immich`, `opencloud`, `paperless`, `uptime_kuma`), then `update_os`. `notify` is not in the list: it runs as a dependency of `base`, `clamav`, `monitoring`, `integrity`, `yara` and `backup` (see their `meta/main.yml`), so it runs once, before `base`.

The order matters:

- `hardening` runs before `firewall_host`, so SSH is already restricted when the firewall comes up.
- `network` sits before `firewall_host`, so when you run them together the firewall sees the final addresses.
- `docker_rootless` needs the `acl` package that `base` installs.
- The container services come after every host role: if one of them is missing a setting (a token, a password), the play stops there, and the host is already configured.

### Tags

| Tag | Roles |
| --- | --- |
| `base` | base (+ notify) |
| `hardening`, `security` | hardening |
| `firewall`, `security` | firewall_host |
| `docker` | docker_rootless |
| `traefik`, `update-containers` | traefik |
| `vaultwarden`, `update-containers` | vaultwarden |
| `immich`, `update-containers` | immich |
| `opencloud`, `update-containers` | opencloud |
| `paperless`, `update-containers` | paperless |
| `uptime-kuma`, `update-containers` | uptime_kuma |
| `clamav` | clamav (+ notify) |
| `monitoring` | monitoring (+ notify) |
| `integrity` | integrity (+ notify) |
| `yara` | yara (+ notify) |
| `backup` | backup (+ notify) |
| `network`, `never` | network |
| `update-os`, `never` | update_os |

`never` is a special Ansible tag: a role that has it runs only when one of its other tags is named explicitly. A plain `ansible-playbook site.yml` therefore never changes the network and never upgrades packages. Those two operations can cut access or reboot the server, so they are opt-in.

Tags on a role apply to all of its tasks and to its dependencies. That is why `--tags clamav` also runs `notify`.

### Where variables come from

From lowest to highest precedence, as used here:

1. `roles/<role>/defaults/main.yml`: the default of every variable a role uses.
2. `inventory/group_vars/prod_servers/main.yml`: the site-specific values (users, keys, addresses, VLANs).
3. `inventory/group_vars/prod_servers/vault.yml`: the secrets, encrypted with Ansible Vault.
4. `inventory/hosts.ini`: `ansible_host` and `ansible_user`.
5. `-e` on the command line: overrides everything (used for the tests).

Some variables appear in the defaults of more than one role (`ssh_port`, `docker_user`, `mgmt_address`). This is deliberate: each role can run on its own, and the value in `group_vars` wins over all of those defaults.

### Drop-in files

Almost every configuration change in this playbook is a **drop-in**: a small file in a `*.d/` directory that changes a few settings, while the main configuration file shipped by the package stays untouched.

**Why not edit the main file.** For Debian, files like `/etc/systemd/journald.conf` are *conffiles*: they belong to a package. If you edit one and an upgrade ships a new version, dpkg has two versions to choose from. In an interactive upgrade it asks which one to keep. In an automatic one (unattended-upgrades, or Ansible's `apt` module, which uses `--force-confold`) it silently keeps yours and drops the new one, along with any new setting or fix it contained. Ansible would also have to edit lines inside someone else's file, which is fragile.

A drop-in avoids both problems. dpkg manages only the files a package ships, and `/etc/systemd/journald.conf.d/10-size.conf` belongs to no package, so upgrades replace the main file freely and the drop-in keeps applying on top of it. To check that no package owns it:

```bash
dpkg -S /etc/systemd/journald.conf.d/10-size.conf    # "no path found matching pattern"
```

**How systemd combines the files** (journald and timesyncd here; see `man systemd.conf.d`):

1. It reads the main file, then every `*.conf` in `journald.conf.d/` under `/usr/lib/systemd/` (shipped by packages), `/run/systemd/` (runtime only, gone at reboot) and `/etc/systemd/` (the administrator's, which is where Ansible writes).
2. All drop-ins are applied in **alphabetical order of their file name**, whatever directory they come from. For a single-value setting, the last one read wins. That is why names start with a number: `10-size.conf` sorts before `90-something.conf`.
3. If the same file name exists in more than one directory, only the one in `/etc` is used. This is how you replace a drop-in shipped by a package.
4. A drop-in contains only the lines it changes. Every other setting keeps its default.

**Empty assignments reset lists.** For settings that hold a list, an empty assignment clears everything collected so far. The timesyncd drop-in relies on this:

```ini
[Time]
NTP=10.0.10.1
FallbackNTP=
```

`FallbackNTP=` with no value removes Debian's fallback pools (`*.debian.pool.ntp.org`), so timesyncd uses OPNsense only. The pools would be blocked by egress filtering anyway.

**Seeing the effective configuration.** This prints every file systemd reads, in the order it applies them, each with its path:

```bash
systemd-analyze cat-config systemd/journald.conf
systemd-analyze cat-config systemd/timesyncd.conf
```

It is the quickest way to find out where a value comes from.

**The same idea elsewhere in the playbook.** The `*.d/` pattern is common on Linux, but the precedence rule is not always the same:

| Drop-in | Directory | Which value wins |
| --- | --- | --- |
| `10-local.conf`, `10-size.conf` | `/etc/systemd/{timesyncd,journald}.conf.d/` | The **last** one read |
| `00-hardening.conf` | `/etc/ssh/sshd_config.d/` | The **first** one read: hence `00`, and the `Include` at the top of `sshd_config` |
| `90-admin` | `/etc/sudoers.d/` | Rules add up; for conflicting ones the last match wins |
| `52unattended-upgrades-local` | `/etc/apt/apt.conf.d/` | The last one read, while lists add up unless cleared with `#clear` |
| `60-hardening.conf`, `60-rootless-docker.conf` | `/etc/sysctl.d/` | The last one read |
| `50-ansible.conf` | `/etc/needrestart/conf.d/` | The last one read |

Services work the same way: `systemctl edit <name>.service` creates `/etc/systemd/system/<name>.service.d/override.conf`, which changes a unit without touching the package's file.

### Handlers

A handler is a task that runs only when another task reports "changed" and names it in `notify:`. Handlers run once, at the end of the play or at a `meta: flush_handlers`. For example, sshd is restarted only if its configuration actually changed.

---

## 2. ansible.cfg

| Setting | Meaning |
| --- | --- |
| `inventory = inventory/hosts.ini` | Default inventory, so `-i` is not needed. |
| `roles_path = roles` | Where Ansible looks for roles. |
| `host_key_checking = True` | Ansible refuses a server whose SSH host key changed. On a reinstall, remove the old key from `~/.ssh/known_hosts` on purpose. |
| `interpreter_python = auto_silent` | Uses the server's Python 3 without the discovery warning. |
| `callback_result_format = yaml` | Output in YAML, easier to read than JSON. |
| `force_handlers = True` | The notified handlers (service restarts) run even when a later task fails. Without it, a failed run leaves new configuration on disk that the running service never loads, and later runs do not notify again because the file no longer changes. It happened on the first deployment: timesyncd kept Debian's public NTP pool instead of OPNsense. |
| `become = True`, `become_method = sudo` | Every task runs as root through sudo, unless a task says otherwise. |
| `pipelining = True` | Ansible sends modules over the SSH connection instead of copying temporary files. It is faster and avoids permission problems when becoming an unprivileged user (`svc-docker`). It requires that sudo does not demand a TTY, which is the Debian default. |

---

## 3. Inventory and variables

### inventory/hosts.ini

```ini
[prod_servers]
prod-srv-01 ansible_host=10.123.11.11 ansible_user=v
```

- `ansible_host`: the **management** IP. Three checks depend on it: `ssh_listen_address` must equal it, the network role requires it among the configured addresses, and nftables allows SSH only to it by default.
- `ansible_user`: must equal `admin_user`. Only that user can log in (`AllowUsers`) and use sudo.

### inventory/group_vars/prod_servers/main.yml

| Variable | Used by | Meaning |
| --- | --- | --- |
| `server_hostname` | base | Host name. Empty leaves it unchanged. |
| `system_timezone` | base | Timezone (`Europe/Rome`). |
| `ntp_servers` | base | NTP servers. OPNsense, because egress to the Internet is blocked. |
| `admin_user`, `admin_ssh_keys` | hardening | Admin user and its public keys. The list is **exclusive**: any key on the server that is not listed here gets removed. |
| `mgmt_address` | firewall_host | Address where SSH is accepted. Defaults to `ansible_host`. |
| `services_address` | firewall_host | Address where 80/443 are accepted. Empty means any address. |
| `ssh_listen_address` | hardening | Address sshd binds to. Empty means all addresses. |
| `network_parent_interface`, `network_links`, `network_dns_servers` | network | Physical NIC, one entry per VLAN, DNS resolvers. |
| `telegram_bot_token`, `telegram_chat_id` | notify | Read from `vault_telegram_*` in the vault. |
| `update_os_allow_reboot` | update_os | `false`: the disk is encrypted, so the update job reports a needed reboot instead of rebooting. |
| `traefik_domain`, `traefik_networks` | traefik | The domain of the wildcard certificate, and one internal network per service behind Traefik. |
| `cloudflare_dns_api_token`, `traefik_dashboard_users` | traefik | Read from the vault. |
| `immich_db_password` | immich | Read from the vault. |
| `traefik_network_aliases` | traefik | Host names Traefik answers to on a service's network: `cloud.<domain>` for OpenCloud. |
| `opencloud_admin_password` | opencloud | Read from the vault; used at the first start only. |
| `paperless_db_password`, `paperless_secret_key`, `paperless_admin_password` | paperless | Read from the vault. |
| `backup_usb_label`, `backup_s3_endpoint`, `backup_s3_bucket`, `backup_exclude` | backup | The USB disk's label, the S3 bucket, and the live database directories left out (their dumps are backed up). |
| `restic_password`, `backup_s3_access_key`, `backup_s3_secret_key` | backup | Read from the vault. |

### vault.yml

It holds the secrets, all with the `vault_` prefix: the Telegram token and chat ID, the restic password, the S3 key, the Cloudflare token, the Traefik dashboard users, the Immich database password, OpenCloud's initial admin password, and Paperless's database password, secret key and admin password (`vault.yml.example` lists them, with how to generate each). The pattern `telegram_bot_token: "{{ vault_telegram_bot_token }}"` is the usual Ansible convention: `main.yml` shows which secrets exist and where they are used, and the values stay encrypted.

---

## 4. Role: base

Purpose: the common foundation, meaning packages, time, logs and automatic updates.

**Set the hostname** / **Map the hostname to the loopback address**
Sets the host name through systemd and maps it to `127.0.1.1` in `/etc/hosts`, as the Debian installer does. Without that line, `sudo` prints "unable to resolve host" whenever the name changes. Both tasks are skipped if `server_hostname` is empty.

**Install base packages**
Installs `base_packages` (in `defaults/main.yml`). Three of them are not obvious:

- `acl`: lets Ansible hand a temporary file to another unprivileged user, which is needed by `become_user: svc-docker`.
- `python3-apt`: needed by the `apt` module.
- `needrestart`: after an upgrade, finds services still running old libraries and restarts them.

`cache_valid_time: 3600` skips `apt update` if it ran in the last hour.

**Set the timezone**
`community.general.timezone` calls `timedatectl set-timezone`.

**Create the systemd drop-in directories**
Creates `/etc/systemd/timesyncd.conf.d` and `/etc/systemd/journald.conf.d`, where the next two tasks write their drop-ins (see [Drop-in files](#drop-in-files) for how they work). Debian does not create these directories, and the `copy` module does not create missing parent directories, so without this task the next two would fail.

**Point systemd-timesyncd to the local NTP servers**
Writes `NTP=<OPNsense>` and empties `FallbackNTP=`, so the server never tries the Debian NTP pools, which egress filtering would block anyway. On change it restarts timesyncd. It is skipped if `ntp_servers` is empty.
Check: `timedatectl timesync-status`.

**Keep systemd-timesyncd running** / **Read the NTP synchronization setting** / **Turn on NTP synchronization**
`systemd-timesyncd` is in `base_packages`, enabled and started, and `timedatectl set-ntp true` runs whenever `timedatectl` reports `NTP=no`. An attacker who stops time synchronization makes the journal timestamps useless as evidence, and a drifting clock breaks TLS and Telegram. The `integrity` role checks the same things every 15 minutes, so a change made by hand between two runs is reported.
Check: `timedatectl show --property=NTP --property=NTPSynchronized`.

**Cap the size of the persistent journal**
Logs are kept across reboots (`Storage=persistent`) and limited to `journald_max_use` (500 MB), so they cannot fill the single disk.
Check: `journalctl --disk-usage`.

**Choose what unattended-upgrades installs**
Writes `/etc/apt/apt.conf.d/52unattended-upgrades-local`. APT reads the files in that directory in alphabetical order, so `52` comes after Debian's `50unattended-upgrades`.

- `#clear Unattended-Upgrade::Origins-Pattern;` empties the origin list defined in `50`, so that only the list in `52` (`base_unattended_origins`) applies. Without it the two lists would add up. This was a real bug found during testing.
- The allowed origins: Debian `trixie` (point releases), `trixie-updates` and `trixie-security`, and Docker's repository (`origin=Docker,label=Docker CE,archive=trixie`, from its `Release` file). Not backports or proposed updates. Until November 2026 only security updates were installed by themselves and the rest waited for `update-os`; with no scheduler for that job (Semaphore is not deployed), Debian's other updates and Docker's never arrived.
- **Docker's packages and the rootful daemon.** On an upgrade, `docker-ce` and `containerd.io` call `deb-systemd-invoke restart docker.service docker.socket` (and `containerd.service`). On Debian 13 (init-system-helpers 1.69) that skips a unit that is disabled and not running, and `deb-systemd-helper` only re-enables a unit that was enabled: the units the docker_rootless role disabled stay off. The report checks it after every Docker upgrade anyway.
- `Automatic-Reboot "false"`: the server never reboots by itself. The disk is encrypted and its passphrase is typed at the console, so reboots are always done by hand.

Check: `sudo unattended-upgrade --dry-run -d 2>&1 | grep -i 'allowed origins'`.

**Enable the daily unattended-upgrades run** / **Schedule the apt jobs**
Turns on the daily list update and the unattended upgrade (APT timers `apt-daily` and `apt-daily-upgrade`). Drop-ins in `/etc/systemd/system/apt-daily{,-upgrade}.timer.d/50-schedule.conf` replace Debian's schedule (06:00 and 06:00/18:00 with random delays) with fixed times at night: lists at 03:45 (`base_apt_update_on_calendar`), upgrade at 04:00 (`base_apt_upgrade_on_calendar`), after the backup and the Saturday SMART long test. A change reloads systemd and restarts the two timers (**Restart the apt timers**): a timer picks up a new schedule only then.

**Install the unattended-upgrades report** / **Create the drop-in directories of the apt jobs** / **Report after each apt job**
`/usr/local/sbin/unattended-upgrades-report`, called by systemd through `ExecStopPost=` drop-ins (`/etc/systemd/system/apt-daily{,-upgrade}.service.d/50-telegram.conf`). `ExecStopPost` runs when the job ends, whatever its result, with `SERVICE_RESULT` set; both units are `Type=oneshot`. A change reloads systemd (**Reload systemd**).

- After `apt-daily-upgrade.service` (`upgrade`): one Telegram message per unattended-upgrades run. It reads the last run of `/var/log/unattended-upgrades/unattended-upgrades.log` (from the last "Starting unattended upgrades script" line) and reports "N PACKAGE(S) UPGRADED" with the list, "NOTHING TO INSTALL", or "ERRORS" with the `ERROR` lines; kept-back and auto-removed packages are added. If the service itself failed, "JOB FAILED" with the last lines of its journal. Then whether a reboot is needed: `needrestart -b -k` (a newer kernel installed) or `/run/reboot-required` (some packages), with the reminder that the reboot is by hand. `apt.systemd.daily` runs unattended-upgrades at most once a day: if the log has no new run (`/var/lib/unattended-upgrades-report/last-run` keeps the last one reported), nothing is sent.
- **After a Docker upgrade** (`docker-ce`, `docker-ce-rootless-extras` or `containerd.io` in the list), before the message: the rootless daemon still runs the old binaries, so the script restarts it (`systemctl --user restart docker.service` as `svc-docker`), then checks every 10 seconds, for up to `base_docker_restart_wait` (300 s), that each container that was running before is running again and, when it has a health check, healthy. The message says "🐳 Docker upgraded … N containers running again after X s", or the title becomes "DOCKER NEEDS ATTENTION" with the containers not back. It also checks that the rootful daemon is still off. `apt-daily-upgrade.service` has `TimeoutStopSec=900`, so the wait fits in its `ExecStopPost`.
- After `apt-daily.service` (`update`): a message only if the package lists could not be downloaded. Without new lists, unattended-upgrades would report "nothing to install" while security updates exist.

The script was tested with sample logs in unattended-upgrades 2.12's format (Debian 13): packages upgraded with a newer kernel, nothing to install, errors with `/run/reboot-required`, the same run twice, the service failed, the list download failed and succeeded. The Docker restart was tested with stand-in `docker-svc`, `systemctl` and `runuser`: every container back, one container unhealthy past the wait, the rootful daemon running, no Docker package upgraded.

**Configure needrestart to restart services after upgrades**
`$nrconf{restart} = 'a'` makes needrestart restart affected services automatically. The Debian default is interactive mode, which does nothing in a non-interactive upgrade. It does not reboot for the kernel: that is handled by `update_os`.

Handlers: restart timesyncd and journald when their drop-ins change.

---

## 5. Role: hardening

Purpose: control who can log in and with what privileges.

**Check the prerequisites that keep access to the server**
An `assert` that stops the play **before** any change if:

- `admin_ssh_keys` is empty, since password authentication will be disabled;
- `ansible_user` differs from `admin_user`, since `AllowUsers` would lock Ansible out;
- `ssh_listen_address` is set but differs from `ansible_host`, since sshd would stop listening on the address Ansible uses;
- `ssh_log_level` is not `INFO` or `VERBOSE`, since lower levels drop the login records.

**Create the administrative user**
Creates the user (or leaves it as is), adds it to the `sudo` group with `append: true` (other groups are kept) and gives it bash as shell.

**Install the authorized SSH keys (exclusive)**
`exclusive: true` makes `~/.ssh/authorized_keys` contain **exactly** the listed keys. A key added by hand on the server is removed at the next run. This is intentional: the repository is the only source of truth for access.

**Allow the administrative user to use sudo without a password**
Writes `/etc/sudoers.d/90-admin` with `NOPASSWD: ALL` for `admin_user` only. It is passwordless because Ansible uses sudo non-interactively and the user has no password (keys only). `validate: visudo -cf %s` checks the syntax before installing the file: a broken sudoers file would make sudo unusable.

**Configure the OpenSSH hardening drop-in**
Template `templates/sshd_hardening.conf.j2` → `/etc/ssh/sshd_config.d/00-hardening.conf`. In sshd **the first occurrence of each directive wins**, and Debian 13 includes `sshd_config.d/*.conf` at the top of `sshd_config`, so this drop-in beats every later line. `validate: sshd -t -f %s` tests it before it is written.

| Directive | Why |
| --- | --- |
| `Port` | Configurable SSH port (22 by default). |
| `ListenAddress` | Only if `ssh_listen_address` is set: SSH on the management IP only. |
| `PermitRootLogin no` | Nobody logs in as root directly. |
| `LogLevel VERBOSE` | Every login is logged with the fingerprint of the key used, so you can tell which device logged in. Ebury-style intrusions lower the level to hide their logins: the `integrity` role alerts if the effective level drops below INFO. |
| `PubkeyAuthentication yes`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no` | Keys only. |
| `AllowUsers <admin_user>` | No other account can log in, `svc-docker` included. |
| `X11Forwarding no`, `AllowAgentForwarding no`, `AllowTcpForwarding no` | No graphical forwarding, no agent forwarding, no SSH tunnels. If you ever need a tunnel, change `AllowTcpForwarding` here. |
| `MaxAuthTries 3`, `MaxStartups 10:30:100`, `LoginGraceTime 30` | Limits against brute force and half-open connections. |
| `ClientAliveInterval 300`, `ClientAliveCountMax 2` | Closes sessions that stay unresponsive for 10 minutes. |

**Make sure sshd_config includes the drop-in directory**
On Debian 13 the `Include` line is already there, so this task normally changes nothing. It is insurance in case someone removes it.

**Apply kernel and network hardening settings**
Writes the settings from `hardening_sysctl` to `/etc/sysctl.d/60-hardening.conf` and applies them at once.

| Setting | Effect |
| --- | --- |
| `kernel.kptr_restrict: 2` | Hides kernel addresses from `/proc`; makes exploits harder to write. |
| `kernel.dmesg_restrict: 1` | Only root reads the kernel log. |
| `kernel.unprivileged_bpf_disabled: 1` | Unprivileged users cannot load BPF programs, a frequent source of exploits. Note: once set to 1 it cannot go back to 0 without a reboot. |
| `net.core.bpf_jit_harden: 2` | Hardens the BPF compiler. |
| `kernel.yama.ptrace_scope: 1` | A process can debug only its own children. |
| `fs.protected_fifos`, `fs.protected_regular: 2` | Blocks attacks based on files and FIFOs in shared directories such as `/tmp`. |
| `accept_redirects: 0`, `send_redirects: 0`, `accept_source_route: 0` | Ignores ICMP redirects and source routing: other hosts cannot change the server's routes. |
| `log_martians: 1` | Logs packets with impossible source addresses. |
| `tcp_syncookies: 1` | Resists SYN floods. |

User namespaces are **not** disabled: rootless Docker depends on them.

Handler: restarts `ssh` (Debian's name for the sshd service) when the configuration changes. The current Ansible session survives the restart.

---

## 6. Role: network

Purpose: move the server from a single address to an 802.1Q trunk with one address per VLAN, without risking a permanent lockout. It runs only with `--tags network`.

### What it builds

For each entry in `network_links`, `templates/interfaces.j2` writes an ifupdown stanza:

- `vlan: null` → the address goes on the physical NIC (untagged traffic);
- `vlan: 20` → interface `enp1s0.20`, created by ifupdown with `ip link add ... type vlan id 20` (native on Debian 13, no extra package).

The default gateway (`gateway`) is written only for the link with `default_route: true`.

### Why one routing table per address

With two addresses and a single default route, a reply leaves through the default VLAN even when the request came in on the other one. OPNsense sees the request on one interface and the reply on another, and drops it as asymmetric traffic. So each link gets:

1. its own table (`table: 100`, `200`, …) holding the connected subnet and a default route through that VLAN's gateway (the two `post-up ip route replace` lines);
2. a rule `ip rule add from <address> table <table>`: any packet whose source is that address uses that table.

The result: a packet from the services IP always leaves through the services VLAN, and one from the management IP through the management VLAN. The rule priority equals the table number. `pre-down` removes the rule when the interface goes down.

The first `post-up` line reads the connected subnet from the main table (`ip -4 route show dev $IFACE scope link proto kernel`) and copies it into the link's table. This avoids computing the network address in Ansible, which would need an extra collection.

### Tasks

**Check the network definition**
Stops before any change if:

- the parent interface does not exist (the message lists the ones that do);
- there is not exactly one link with `default_route: true`;
- there is more than one untagged link;
- two links share a routing table;
- `ansible_host` is not one of the configured addresses, because after the reboot Ansible would have nothing to reconnect to.

**Gather the service states** / **Check that the server uses ifupdown only**
The role writes `/etc/network/interfaces`. If systemd-networkd or NetworkManager is enabled, two managers would configure the same NIC. The play stops and asks you to disable them. A netinst install uses only ifupdown, so this normally passes.

**Install the rollback script** / **Install the rollback service**
Installs `/usr/local/sbin/network-rollback` and `network-rollback.service`. The service starts only if `/etc/network/interfaces.rollback` exists (`ConditionPathExists`). The script waits `network_rollback_minutes` (5); if the file is still there, it restores it as `/etc/network/interfaces`, disables itself and reboots.

**Render the new network configuration** / **Validate the new network configuration**
The new configuration is first written to `/etc/network/interfaces.new` and parsed with `ifquery --list`. A syntax error stops the play before anything is changed.

**Compare the new configuration with the current one**
`cmp` returns 0 if the files are identical, 1 if they differ. When nothing changed, the whole block below is skipped: no reboot.

**Write the DNS resolvers**
Writes `/etc/resolv.conf` with `network_dns_servers`. This takes effect at once, without a reboot.

**Apply the new configuration with a rollback safety net** (block, only if the configuration changed)

1. Copy the current file to `interfaces.rollback`.
2. Enable `network-rollback.service` for the next boot.
3. Install `interfaces.new` as `interfaces`.
4. Reboot (`ansible.builtin.reboot`, up to 240 s to reconnect).
5. **Check that the server booted with the new configuration**: compares `interfaces.new` with `interfaces` again. This step is needed because if the new configuration does not work, the server may roll back and come up again *within* Ansible's wait: Ansible would reconnect to the old configuration and, without this check, report success. This case actually happened during testing.
6. **Stop if the server rolled back**: fails with a message that explains what happened and where to look.
7. **Confirm the new configuration**: deletes `interfaces.rollback`, which cancels the restore, then stops and disables the service.

Possible outcomes:

| Situation | Result |
| --- | --- |
| New configuration works | Confirmed, rollback cancelled, play OK. |
| New configuration cuts access | Ansible cannot reconnect and fails; about 5 minutes after boot the server restores the old configuration and reboots. |
| Rollback finishes before Ansible gives up | Ansible reconnects, sees the old configuration and fails with an explicit message. |

Check: `ip -br address`, `ip rule`, `ip route show table 100` (see `verify.md`, section 4).

---

## 7. Role: firewall_host

Purpose: a second filter on the server itself, behind OPNsense.

**Install nftables** / **Write the nftables ruleset** / **Enable nftables at boot**
The template becomes `/etc/nftables.conf` (root only, 0600). `validate: nft -c -f %s` checks the syntax without applying it. The `nftables` service loads the file at every boot. The handler **Apply nftables ruleset** loads it immediately when it changes.

### The ruleset

`flush ruleset` empties everything before loading, so the file is the complete truth. A single `inet` table covers IPv4 and IPv6.

**`input` chain, `policy drop`**: anything not accepted explicitly is dropped. In order:

1. `ct state established,related accept`: replies to connections already open, including the Ansible SSH session in progress. That is why changing the rules mid-run does not cut the connection.
2. `ct state invalid drop`: malformed packets.
3. `iif "lo" accept`: local traffic.
4. ICMP and ICMPv6: needed for path MTU discovery and, on IPv6, for neighbour discovery.
5. SSH: `ip daddr <mgmt_address> tcp dport 22`. If `firewall_ssh_allowed_sources` is not empty, it also checks the source against the `ssh_sources` set.
6. Service ports (`firewall_service_ports`): TCP 80/443, on `services_address` if set, otherwise on any address.
7. If `firewall_log_drops` is on: logs what is about to be dropped (at most 10 per minute) with the prefix `nft-input-drop:`.

**`forward` chain, `policy drop`**: the server does not route between networks.

**`output` chain, `policy accept`**: outbound filtering is OPNsense's job, with FQDN aliases. Doing it on the host with nftables would need IPs that change constantly.

### Why Docker does not interfere

Rootful Docker writes its own iptables rules and bypasses a host firewall. Rootless Docker does not: the published ports are sockets opened by the `slirp4netns` process, an ordinary process on the host. Incoming traffic therefore goes through the `input` chain above like any other service.

---

## 8. Role: docker_rootless

Purpose: Docker without root. Even if a container escaped, it would get the rights of `svc-docker`, not root.

### Packages

**Create the APT keyring directory** / **Download the Docker repository key**
Downloads Docker's GPG key into `/etc/apt/keyrings/docker.asc`. The `checksum:` pins the exact key file: if the downloaded file differed (tampered with or rotated), the task would fail instead of trusting it. The key's fingerprint is in the comment in `defaults/main.yml`.

**Add the Docker repository**
Writes `/etc/apt/sources.list.d/docker.sources` in the deb822 format. `Signed-By` limits that key to this repository only, so it cannot validate packages from other repositories. Suite and architecture come from the facts (`trixie`, `amd64`).

**Install Docker and the rootless prerequisites**

| Package | Role |
| --- | --- |
| `docker-ce`, `docker-ce-cli`, `containerd.io` | Engine, CLI, runtime. |
| `docker-compose-plugin` | `docker compose`. |
| `docker-ce-rootless-extras` | `dockerd-rootless.sh` and rootlesskit. |
| `uidmap` | `newuidmap`/`newgidmap`: map the container's UIDs onto the user's sub-UIDs. |
| `slirp4netns` | Userspace network for the rootless daemon. |
| `dbus-user-session` | Per-user D-Bus, needed by `systemctl --user`. |

`update_cache` runs only if the repository was just added.

**Stop and disable the rootful Docker daemon** / **Remove the rootful Docker socket**
The package starts the system-wide daemon as root. It is stopped and disabled, and its socket is removed. Only the rootless daemon remains.

**Let unprivileged processes bind ports from 80**
`net.ipv4.ip_unprivileged_port_start=80`. By default only root can bind ports below 1024; this lets `svc-docker` publish 80 and 443 (Traefik). Side effect: any local user can bind those ports. That is acceptable here because only the admin and the service user exist.

### Service user

**Create the Docker service user**
`svc-docker` with shell `/usr/sbin/nologin` and a locked password (`!`): nobody logs in as this user, and `AllowUsers` would refuse it anyway. `register: docker_user_info` keeps its UID, used later for paths such as `/run/user/<uid>`.

**Check the subordinate UID and GID ranges of the service user**
Rootless Docker needs a range of sub-UIDs (`/etc/subuid`, `/etc/subgid`) to map container users. `useradd` creates them automatically on Debian; this task checks they exist.

**Keep the service user's systemd instance running without a login**
`loginctl enable-linger`: the user's systemd instance starts at boot and stays up without any open session. Without it, containers would stop when the session ended. `creates:` makes the task idempotent.

**Wait for the service user's session bus**
Waits for `/run/user/<uid>/bus`, a sign that the user's systemd instance is ready to take commands.

### Daemon

**Create the service user's configuration directories**
`~/.config/docker` and `~/.config/systemd/user`, mode 0700.

**Write the rootless daemon configuration**
`daemon.json` from `docker_daemon_config`: `json-file` logs capped at 3 files of 10 MB per container, so container logs cannot fill the disk.

**Write the rootless daemon user unit**
`docker.service.j2` → `~/.config/systemd/user/docker.service`. It is the same unit that `dockerd-rootless-setuptool.sh` would generate, written declaratively so that Ansible can keep it under control. Key lines:

- `DOCKERD_ROOTLESS_ROOTLESSKIT_NET=slirp4netns`: the daemon's network.
- `DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=slirp4netns`: how ports are published. The default `builtin` driver is faster but replaces the client's IP with an internal one; `slirp4netns` keeps it. Traefik needs the real IP for its access log and passes it on to the services (`X-Real-Ip`), so Vaultwarden logs failed logins with the client's address.
- `DOCKERD_ROOTLESS_ROOTLESSKIT_FLAGS=--cidr=...`: only if `docker_rootlesskit_cidr` is set. rootlesskit uses `10.0.2.0/24` internally: if a network the server talks to uses the same range, replies to those clients stay inside the namespace and never leave. This was found during testing (the test VM used that same range).
- `Delegate=yes`: lets the daemon manage its containers' cgroups.
- `Restart=always`: restarts the daemon if it crashes.

**Enable and start the rootless daemon**
`systemctl --user enable --now docker` run **as `svc-docker`** (`become_user`). `XDG_RUNTIME_DIR` tells `systemctl --user` where that user's instance lives.

**Install the docker-svc wrapper for the admin user**
`/usr/local/bin/docker-svc` runs `docker` as `svc-docker` with the right socket. The admin has no direct access to the socket; the wrapper goes through sudo, so every use is recorded in the journal.

**Create the container directories**
`/srv/docker`, `/srv/docker/system` (infrastructure: Traefik) and `/srv/docker/app` (applications: Vaultwarden, Immich, OpenCloud, Paperless), owned by root with group `svc-docker`, mode 0750: the service user can reach them, other users cannot. Each service role adds `<name>/` with its compose file, data and database dumps, so one directory holds everything a restore needs.

**Apply pending daemon changes before the check** (`meta: flush_handlers`)
Runs the **Restart rootless Docker** handler now if `daemon.json` or the unit changed, so the next check sees the new configuration.

**Check that the daemon runs rootless**
`docker info` as `svc-docker`, retried up to 10 times because the daemon takes a few seconds to come up. It fails if `rootless` does not appear among the security options.

---

## 9. Role: notify

Purpose: a single place that sends notifications and holds the token.

**Check the Telegram settings**
If notifications are enabled and the token or chat ID is empty (vault missing or incomplete), the play stops with an explicit message.

**Create the configuration directory** / **Write the notification credentials**
`/etc/homelab/` (0700) and `notify.env` (0600, root): the only file on the server containing the token. `no_log: true` keeps the token out of Ansible's output. Values go through `| quote`, so special characters cannot break the file when the shell sources it.

**Install the notification helper**
`/usr/local/sbin/notify-telegram` (0750, root). Accepts the message as an argument or on stdin.

- Exit codes: `0` sent (or notifications disabled), `1` Telegram refused or did not answer, `2` credentials missing.
- Plain text, no `parse_mode`: file names with `_` or backticks cannot make Telegram reject the message.
- The URL containing the token goes to curl **on stdin** (`-K -`) rather than as an argument: arguments are visible to every user in `ps`, stdin is not.
- `--max-time 20`: a slow network cannot block the calling script for long.
- The message is cut at 4000 characters (Telegram's limit is 4096).

**Check the push monitor settings** / **Write the push monitor tokens** / **Install the push helper**
The Uptime Kuma push monitors, one per scheduled job, say when a job did not run at all, which no message of the job itself can say. `notify_push_tokens` (from `vault_uptime_kuma_push_tokens`) maps a job name to the token of its monitor; the assert refuses a name not in `notify_push_units`. The tokens go to `/etc/homelab/push.env` (0600, root, `no_log`), with `PUSH_HOST` (`health.<domain>`) and `PUSH_ADDRESS` (the services address).

`/usr/local/sbin/notify-push <job>` (0750, root) reads `SERVICE_RESULT`, `EXIT_CODE` and `EXIT_STATUS`, which systemd sets for `ExecStopPost`, and calls `https://health.<domain>/api/push/<token>?status=up&msg=OK`, or `status=down` with the result (`exit-code (exited 1)`). Uptime Kuma 2.5.9's push endpoint (`server/routers/api-router.js`) reads exactly these two parameters and answers 404 for an unknown token.

- `--resolve` connects to the services address directly: the call goes to Traefik on the server itself (`iif lo` is accepted by the host firewall), with no DNS and no OPNsense in the way, and still checks the certificate for the real name.
- The URL with the token goes to curl on stdin (`-K -`), as for Telegram; `-G` adds the parameters to it.
- It always exits 0 and writes problems to the job's journal: a missing token or an Uptime Kuma that does not answer never makes the job fail.
- `SuccessExitStatus=1` of the ClamAV, YARA and integrity units makes a finding a successful run, so the monitor stays green and the finding comes from the job's own message. Red means the job broke, or did not run.

**Create the drop-in directories of the jobs** / **Call the push monitor at the end of each job** / **Remove the call from the jobs without a token**
`/etc/systemd/system/<unit>.d/90-push.conf` with `ExecStopPost=/usr/local/sbin/notify-push <job>`, only for the jobs with a token. `ExecStopPost` runs whatever the result, also after a crash or a timeout. `90-` sorts after the unattended-upgrades report (`50-telegram.conf`), so the call comes when the whole job, report included, has ended. A drop-in can exist before its unit (the notify role runs before the roles that install the units). The handler reloads systemd.

---

## 10. Role: clamav

Purpose: daily antivirus scan of user data, with quarantine and a report.

**Check that the quarantine is outside the scanned paths**
If the quarantine were inside a scanned path, quarantined files would be detected again at every scan. The check compares paths with a trailing `/`, so that `/srv` does not match `/srvx`.

**Install ClamAV**
`clamav` (scanner), `clamav-daemon` (clamd, keeps the signatures in memory: fast scans, about 1–1.5 GB of RAM), `clamav-freshclam` (signature updates).

**Create the quarantine directory (root only)**
`/root/clamav-quarantine`, mode 0700.

**Start the signature updater**
On its first start freshclam downloads the database (a few hundred MB from `database.clamav.net`).

**Wait for the signature database (main and daily)**
Waits, up to 10 minutes, until both `main` and `daily` (in `.cvd` or `.cld` format) exist. The Debian `clamav-daemon` unit has a start condition on both files: if one is missing, systemd **skips** the start without an error. A first version of this task waited only for `daily`, and the daemon did not start on the first run. Found and fixed during testing.

**Start the ClamAV daemon** / **Check that the ClamAV daemon is running**
Starts clamd, then checks that it is really `active`, so a skipped start can no longer pass unnoticed.

**Install the scan script** / **Install the scan service and timer** / **Enable the scheduled scan**
A systemd timer instead of cron: logs end up in the journal, `Persistent=true` runs a missed scan at boot (if the server was off at midnight), and `systemctl list-timers` shows the next run. In the service, `SuccessExitStatus=1` treats "threats found" as a success, because it has already been reported. `Nice=19` and `IOSchedulingClass=idle` keep the scan from slowing the services down.

### The scan script (`/usr/local/sbin/clamav-scan`)

1. Creates the log directory; if the action is `quarantine`, also the quarantine directory.
2. Deletes `scan_*.log` files older than `clamav_log_retention_days` (30).
3. Skips paths that do not exist, with a warning in the log.
4. Uses `clamdscan --multiscan --fdpass` if the daemon is active. `--fdpass` makes the script, running as root, open the files and pass the descriptors to clamd, which runs as the `clamav` user and could not read files owned by others. Otherwise it falls back to `clamscan --recursive`, which is slower.
5. Adds `--move=<quarantine>` or `--remove=yes` depending on `clamav_action_on_detect`.
6. Reads ClamAV's exit code: `1` = threats (sends a message with up to 20 files), `>1` = error, `0` = clean (sends a summary if `clamav_notify_clean` is on).
7. A failed notification is written to the log; it does not change the scan result.

Scanned paths: admin home, `/etc`, `/srv`, `/tmp`, `/var/tmp`. Image layers (`~svc-docker/.local/share/docker`) are left out on purpose: they are public software and re-scanning them every night with ClamAV is expensive; the nightly YARA scan covers them. Container data is bind-mounted under `/srv/docker`.

---

## 11. Role: monitoring

### SMART (skipped on virtual machines)

`smartd_enabled` is false when the facts say the server is a VM guest: there is no physical disk to read.

**Configure smartd**
One `DEVICESCAN` line monitors every disk:

| Option | Meaning |
| --- | --- |
| `-a` | Health, attributes, error logs. |
| `-o on`, `-S on` | Automatic offline tests and attribute autosave. |
| `-n standby,q` | Does not wake sleeping disks. |
| `-s (S/../.././02\|L/../../6/03)` | Short self-test every day at 02:00, long one on Saturdays at 03:00. |
| `-W 4,45,55` | Reports temperature changes of 4 °C, information at 45 °C, alarm at 55 °C. |
| `-m root -M exec /usr/share/smartmontools/smartd-runner` | On a problem, runs Debian's `smartd-runner`, which runs every script in `/etc/smartmontools/run.d/`. |

**Install the smartd Telegram hook**
`/etc/smartmontools/run.d/20telegram` sends `SMARTD_DEVICE`, `SMARTD_FAILTYPE` and `SMARTD_MESSAGE`, which smartd sets, through `notify-telegram`.

Test the path: temporarily add `-M test` to the line in `/etc/smartd.conf` and restart `smartmontools`: smartd sends a test message at startup.

### Disk space

**Install the disk space check** / **service and timer** / **Enable the disk space check**
Every 15 minutes (`*:0/15`) `/usr/local/sbin/disk-space-check` reads the usage of each path in `disk_space_mountpoints`.

To avoid a message every 15 minutes, it keeps a state per mount point in `/var/lib/disk-space-check/`:

- it notifies only on a **change** of state: ok → above the threshold, or back below it;
- it saves the new state **only if the notification went out**, so a failed send is retried at the next run.

---

## 12. Role: integrity

Purpose: notice the traces left by Ebury and similar OpenSSH backdoors, and the changes made to hide them. It follows the October 2026 compromise of Tor exit relays, where Ebury 1.8.3 survived reboots as a **setuid library file that no package installed**, next to the packaged `libkeyutils`, with the `libkeyutils.so.1` symlink pointed at it. `dpkg --verify` and `debsums` saw nothing, because no packaged file had changed.

**Install the integrity check** / **service and timer** / **Enable the integrity check**
`/usr/local/sbin/integrity-check` runs every 15 minutes (`integrity_check_on_calendar`). It takes under a second. The unit sets `H=1 I=1 LD_PRELOAD=: LD_DEBUG=:`, the same variables ESET's `detect_ebury.sh` uses to defuse Ebury's userland rootkit.

| Check | Finding when |
| --- | --- |
| NTP | `timedatectl` reports `NTP=no`, `systemd-timesyncd` is not running, or the clock is not synchronized `integrity_ntp_grace_minutes` (30) after boot. |
| sshd logging | The effective `LogLevel` (`sshd -T`) is below INFO; any `LogLevel` line in `sshd_config` or `sshd_config.d/` sets a lower level (a `Match` block can do it for one address only); `-q` or `LogLevel` appears in the unit's `ExecStart`/`Environment` or in `SSHD_OPTS` (`/etc/default/ssh`). The running listener rewrites its process title, so its options are read where they are set. `sshd -T` failing is also reported. |
| Libraries | In `integrity_lib_dirs` (`/usr/lib`, `/usr/lib64`, `/usr/libexec`, `/usr/local/lib`): any setuid/setgid shared object; any other setuid/setgid file that no package installed; any file whose owner or group does not exist; any shared object (`*.so`, `*.so.*`) whose real file, symlinks followed, no package installed. |
| Preload | `/etc/ld.so.preload` has entries, or `LD_PRELOAD` is set in `/etc/environment(.d)`. |
| `ssh.service` | A process inside the unit's cgroup is not `/usr/sbin/sshd`, `sshd-session` or `sshd-auth`. Logged-in sessions move to the user's slice, so anything else there is suspect: Ebury runs a fake `rsyslogd` (earlier `systemd-udevd` or `arpd`) in this cgroup. |
| Ebury sockets | One of the abstract UNIX sockets in `integrity_ebury_sockets` (from ESET's script, up to 1.8.3's `@event-0YsOG9WSOE`) accepts a connection or appears in `/proc/net/unix`. |

How the library check decides what "installed by a package" means:

- the reference list is every path in `/var/lib/dpkg/info/*.list`, plus the targets of `dpkg-divert`;
- for each of those paths the **directory** is resolved, because of merged `/usr` (`/lib` is a symlink to `/usr/lib`, and packages list either form). The file itself is never resolved: otherwise the packaged `libkeyutils.so.1` symlink, once pointed at the implant, would make the implant look packaged. This was a bug found while testing;
- on the server side every shared object name is resolved to its real file, and that file must be in the list;
- while dpkg holds its lock (an upgrade is unpacking files under temporary names) the library check is skipped for that run. The lock is read from `/proc/locks`, never taken, so the check cannot make apt fail.

Reporting: every finding goes to the journal at each run. Telegram gets a message when the set of findings changes, again every `integrity_renotify_hours` (24) while it stays the same, and a "✅ ALL CLEAR" when it empties. The state is in `/var/lib/integrity-check/state` and is saved only after a successful send, so a failed send is retried.

Check: `sudo integrity-check; echo $?` (0 = nothing found, 1 = findings) and `journalctl -u integrity-check.service`.

---

## 13. Role: yara

Purpose: look for known Linux malware by content, in files and in the memory of the OpenSSH processes. ClamAV covers uploads and common malware; YARA adds the rule sets that track Ebury, OpenSSH backdoors and the tooling usually found on compromised Docker hosts.

### The rules

They are vendored in `roles/yara/files/rules/` and copied to `/etc/yara/rules/`: the server cannot reach GitHub. `scripts/update-yara-rules.sh` fetches them at pinned commits and writes `SOURCES.md` with the commits and licenses.

| Directory | Source | Covers | License |
| --- | --- | --- | --- |
| `eset/` | [eset/malware-ioc](https://github.com/eset/malware-ioc) | Ebury (`libkeyutils` with a constructor, the v1.7/1.8 string decryption), the OpenSSH backdoors of "The Dark Side of the ForSSHe" | BSD 2-Clause |
| `elastic/` | [elastic/protections-artifacts](https://github.com/elastic/protections-artifacts) | Every `Linux_*` and `Multi_*` rule: Ebury, SSHDoor, sshd kits, rootkits (Diamorphine, Reptile, Perfctl, …), miners (XMRig and others), Docker botnets (Kinsing, Tsunami, Mirai), C2 implants (Sliver, Merlin, Mythic), tunnels (gsocket), webshells, ransomware, privilege-escalation exploits, EICAR | Elastic License 2.0 |

Only Elastic's attack-simulation rule is left out (it is not malware). Before adding them, the rules were run against a clean Debian 13 system and against unpacked images of Traefik, Vaultwarden, Immich, Paperless-ngx and OpenCloud: no matches in about 125,000 files.

**Install YARA** / **Create the rule and log directories** / **Copy the YARA rules**
The Debian `yara` package (4.5 on Debian 13), `/etc/yara/rules/` and `/var/log/yara/`.

**List the rules on the server** / **Remove rules no longer in the repository**
A rule dropped from the repository must stop running, so any `.yar` file on the server that is not in `files/rules/` is deleted.

**Install the scan script** / **Check that the rules compile**
After any change to the rules or the script, `yara-scan --compile-only` compiles them: a broken rule fails the play instead of every nightly scan.

**Install the scan service and timer** / **Enable the scheduled scan**
Daily at 01:00 (`yara_scan_on_calendar`), with the lowest CPU and I/O priority.

### The scan script (`/usr/local/sbin/yara-scan`)

1. Compiles the rules into a temporary directory under `/run` (under a second), one namespace per source. Two sets: all rules for files; for memory, all except `yara_memory_exclude_rules`. ESET's SSHDoor rules are written for files on disk: in the memory of a clean sshd they also see the loaded libraries and match, which was found while testing.
2. Builds the list of files with `find`: `yara_scan_paths`, without crossing into other filesystems, skipping `yara_exclude_paths` and files over `yara_max_file_size_mb` (64 MB). `/etc/yara` is always excluded, because the rules contain the very strings they look for; so is the ClamAV quarantine. `/home` includes `~svc-docker/.local/share/docker`, so image and container layers are scanned: a miner dropped in a container shows up there.
3. Scans the files (`yara --scan-list`). Unreadable or vanished files are counted in the log, not treated as errors.
4. Scans the memory of the processes named in `yara_process_names` (`sshd`, `sshd-session`, `sshd-auth`) and of any process running from `/tmp`, `/var/tmp`, `/dev/shm`, a memfd or a deleted file, which is how droppers and fileless miners look.
5. Writes `/var/log/yara/scan_<date>.log` (kept 30 days) and sends a Telegram message on matches or on an error. Nothing is moved or deleted: a match on a system library must be investigated, not quarantined.

Exit codes: 0 clean, 1 matches, 2 error. Like ClamAV, `SuccessExitStatus=1` keeps a match from showing as a failed unit.

Check: `sudo systemctl start yara-scan.service`, then the newest log in `/var/log/yara/`.

---

## 14. Role: backup

Purpose: the only way to get the data back. Ansible rebuilds the configuration; with a single disk in the server, only the backup brings back the data. Two copies, both encrypted by restic with the same password: an external USB disk next to the server and an S3 bucket off site.

**Check the backup settings**
Stops the play if no copy is enabled, if `restic_password` is shorter than 20 characters, or if S3 is enabled without endpoint, bucket or keys. The values come from the vault through `main.yml`, with an empty default, so a missing vault key gives this clear message instead of an undefined-variable error.

**Install restic** / **Create the backup directories**
The Debian package (0.18 on Debian 13). Root-only directories: `/etc/backup/pre.d` for the applications' dump scripts, `/var/cache/restic` for restic's cache, and the mount point of the USB disk.

**Write the backup credentials**
`/etc/homelab/backup.env` (root, 0600) with `RESTIC_PASSWORD` and the S3 keys, like `notify.env`. `no_log` keeps them out of the Ansible output.

**Install the backup script** / **Initialize the repositories that do not exist yet** / **Show the repository status**
`backup --init` creates a repository only when restic says it does not exist (exit code 10), and prints one line per copy. If the USB disk is not plugged in, it skips it without failing: run `sudo backup --init` once it is connected. The nightly run never creates a repository: if one disappears, the run fails and says so, instead of quietly starting an empty one.

**Install the backup service and timer** / **Enable the scheduled backup**
Daily at 02:30 (`backup_on_calendar`), after the ClamAV and YARA scans have started and before the long SMART test and the nightly unattended-upgrades run (04:00).

### The backup script (`/usr/local/sbin/backup`)

1. Runs the executable scripts in `/etc/backup/pre.d/` (`run-parts`). Each service role with a database adds one that dumps it under `/srv/docker/{system,app}/<name>/dump/` (today `vaultwarden`, `immich`, `paperless` and `uptime-kuma`); `opencloud` adds one that stops it. If one fails, the run goes on with the previous dump and the report shows a warning.
2. **USB copy**: mounts `/dev/disk/by-label/<backup_usb_label>` on `/mnt/backup-usb` (`noexec,nosuid,nodev`), backs up to `/mnt/backup-usb/restic`, unmounts. If the disk was already mounted by hand, it leaves it mounted. A missing disk is a failure of this copy only.
3. **S3 copy**: backs up to `s3:https://<endpoint>/<bucket>/<host name>`.
4. For each copy: `restic backup` of `backup_paths` (missing paths skipped, `--exclude-caches`, plus `backup_exclude`), then `restic forget` with the retention (7 daily, 4 weekly, 12 monthly). On `backup_maintenance_weekday` (Sunday) it also runs `prune` and `restic check --read-data-subset 5%` (`backup_check_read_data_subset`): besides the structure and index, restic reads back a random 5% of the stored data and verifies it, so damaged data shows up within about five months, before a restore needs it. Reading part of the data costs no egress on R2 and adds a few minutes on the USB disk; `""` turns it off. Exit code 3 from restic (some files unreadable, snapshot saved anyway) is a warning, any other error a failure.
5. After both copies, whatever their result, runs the executable scripts in `/etc/backup/post.d/`: `opencloud` starts again there. A failure here is a failure of the run (a service may still be down), reported as "❌ Post-backup scripts".
6. Sends **one Telegram message** per run: `✅ BACKUP OK`, `⚠️ BACKUP COMPLETED WITH WARNINGS` or `❌ BACKUP FAILED`, with one line per copy (snapshot ID, data added, files new and changed, duration). The full restic output is in the journal.

Exit code 1 when a copy failed, so the unit shows as failed in `systemctl --failed`.

The same script runs any restic command on one copy, with the credentials loaded and the disk mounted for the duration: `sudo backup usb snapshots`, `sudo backup s3 restore latest --target /srv/restore --include /srv/docker/app/<name>`. This is what the restore procedures in the maintenance guide use.

What protects the copies:

- **Encryption**: restic encrypts everything with the password; the USB disk and the bucket hold nothing readable without it.
- **USB**: mounted only during the backup, so for 23 hours a day nothing on the server can write to it. You can unplug it at any time outside 02:30 and take it elsewhere.
- **S3**: the server's key can delete objects. On prod-srv-01 the R2 bucket locks `data/`, `snapshots/`, `keys/` and `config` for 90 days (bucket lock rules, set in the Cloudflare dashboard, which the server's key cannot change): nothing written there can be deleted or overwritten for 90 days. `locks/` stays unlocked (restic deletes its lock file at every run), and so does `index/` (rebuilt from the data by `restic repair index` if it is lost).
- **Append-only S3 copy** (`backup_s3_append_only: true`): the script never deletes from it, since the deletions would fail on locked objects: no `forget` (every daily snapshot is kept) and no `prune`; the Sunday `check` still runs, and the report says "append-only". The bucket only grows, by what changes on the server; the USB copy keeps its retention. An occasional clean-up of the S3 copy is a manual step (maintenance guide).

---

## 15. Role: traefik

Purpose: the single entry point for every container service. It terminates TLS with a Let's Encrypt certificate and forwards each request to the right container.

It sits in `/srv/docker/system/traefik/`:

| Path | Content |
| --- | --- |
| `compose.yml` | The container |
| `traefik.yml` | Static configuration (entry points, certificate resolver), read at startup |
| `dynamic/` | Routes, middlewares, TLS options; watched, changes apply without a restart |
| `data/acme.json` | Certificates and the Let's Encrypt account key (created by Traefik) |
| `data/cloudflare-dns-api-token` | The token, mounted as a secret |
| `logs/traefik.log`, `logs/access.log` | Traefik's own log and one line per request |

`compose.yml`, `traefik.yml` and `dynamic/` belong to root with group `svc-docker` (0640/0750): the container reads them and cannot change them. `data/` (0700) and `logs/` (0750) belong to `svc-docker`.

**Check the Traefik settings** / **Check the service network names** / **Look up the Docker service user** / **Check that rootless Docker is configured**
Stops if the domain, the Cloudflare token or the dashboard users are missing, or if `svc-docker` does not exist yet (run `--tags docker` first).

**Create the Traefik directories** / **Rotate the Traefik logs** / **Write the Cloudflare token** / **Write the static configuration** / **Write the dashboard route, middlewares and TLS options** / **Write the compose file**
The files above. A change to the token or to the static configuration notifies **Restart Traefik**.

**List the Docker networks** / **Create one internal network per service**
For each name in `traefik_networks`, creates `proxy-<name>` with `--internal` if it does not exist. They are created here and not by compose, so they exist before Traefik and the service start, and survive either being recreated.

**Start Traefik**
`docker compose up --detach --remove-orphans --wait` as `svc-docker`. `--wait` waits for the health check (`traefik healthcheck --ping` on an internal entry point that is not published), so the task fails if Traefik does not come up. When the compose file is unchanged, nothing is recreated. With a new `traefik_image`, the container is recreated on the new version: that is all `--tags update-containers` does.

### Design choices

- **No Docker socket.** The Docker provider would read labels from the containers, but it needs the socket, and access to the socket means control of every container: a bug in Traefik would become a takeover of the server. Routes come from the file provider instead: each service role writes `dynamic/<name>.yml` with its router and service.
- **One network per service, not a shared one.** On a shared `proxy` network every service could talk to every other: one compromised application would reach all the others directly. Instead each service has its own `proxy-<name>` network that only Traefik and that service join, created `--internal` so it carries no traffic to the Internet. Traefik joins all of them, plus its own `default` network for Let's Encrypt and Cloudflare. Tested: Traefik reaches each service; two services cannot resolve or reach each other; a service has no Internet access through its network.
- **One wildcard certificate** for `<domain>` and `*.<domain>`, set on the `websecure` entry point, so every router gets it with no TLS settings of its own. It is one certificate to renew instead of one per service, and the internal names (`vault.`, `photo.`) never appear in the public Certificate Transparency logs.
- **DNS challenge** through Cloudflare: nothing needs to be reachable from the Internet. With egress filtered, Traefik cannot ask Cloudflare's authoritative name servers whether the record has propagated, so it asks only the internal resolvers (`network_dns_servers`, Unbound) (`disableANSChecks`).
- **Hardening**: read-only root filesystem (only `/data` and a tmpfs `/tmp` are writable), every capability dropped except binding ports, `no-new-privileges`. In rootless Docker, root inside the container is `svc-docker` on the host.
- **Ports 80 and 443 on `services_address` only.** Port 80 only redirects to HTTPS.
- **10-minute read timeout on `websecure`** (`respondingTimeouts.readTimeout` and `idleTimeout`, 600 s). Traefik's default, 60 s, cuts any request that takes longer to arrive: an Immich video uploaded over WireGuard would fail with error 499.
- **For every router on `websecure`**: HSTS for a year, including subdomains, and `nosniff`. TLS 1.2 or later; `sniStrict` refuses names Traefik has no certificate for.
- **Logs on disk**: `logs/traefik.log` and `logs/access.log` (one line per request, with the real client IP thanks to the slirp4netns port driver). The access log includes the dashboard (`addInternals`), so failed logins show up with the user name tried; it leaves out the health check (`observability.accessLogs: false` on the `ping` entry point) and the HTTP-to-HTTPS redirects. In the container log they would be lost whenever the container is recreated, at every update. `/etc/logrotate.d/traefik` rotates them daily with `copytruncate` and keeps `traefik_log_retention_days` (30) compressed files; being under `/srv`, they are also in the nightly backup. `docker-svc logs traefik` shows only what Traefik prints before it opens its log files.
- **Dashboard** on `proxy.<domain>`, behind basic authentication with bcrypt hashes from the vault. It shows the routes and their errors, and changes nothing.

### Adding a service (for the application roles)

The `vaultwarden` role is the model for a single container, `immich` for one with a database. A new role:

1. **Network**: add the name to `traefik_networks` in `main.yml` and run `--tags traefik`: it creates `proxy-<name>` and attaches Traefik to it. The role asserts the name is there. If the service must call its own public URL (OpenCloud's login checks), also add that host name to `traefik_network_aliases`.
2. **Image**: in `defaults/main.yml`, as `<name>_image: "<image>:<tag>@sha256:<digest>"` on one line. Renovate finds images only in this form.
3. **Compose file** (`compose.yml.j2`): the container Traefik talks to joins `proxy-<name>`; the others (the database) stay on an internal network of their own; no published ports. Read-only filesystem and no capabilities where the image allows it.
   ```yaml
   services:
     <name>:
       networks: [proxy-<name>, backend]
     database:
       networks: [backend]
   networks:
     proxy-<name>:
       external: true
     backend:
       internal: true
   ```
4. **Route**: the role writes `/srv/docker/system/traefik/dynamic/<name>.yml` (template `traefik-route.yml.j2`) after the container is up, with `Host(<name>.<domain>)` to `http://<compose service>:<port>`. Traefik picks it up without a restart.
5. **Database**: a dump script in `/etc/backup/pre.d/<name>` (no dot in the name), and the live database directory in `backup_exclude`. A service that must be stopped for a consistent copy stops in `pre.d` and starts again in `/etc/backup/post.d/<name>` (see `opencloud`).
6. **Tags** in `site.yml`: `[<name>, update-containers]`, after the other container services.
7. **DNS**: a host override `<name>.greyroom.net` → services address in Unbound.
8. **Docs**: a walkthrough section, the README tables, a restore procedure in the maintenance guide, checks in `verify.md`.

Check: the route in the dashboard (`https://proxy.greyroom.net`), `sudo tail /srv/docker/system/traefik/logs/traefik.log`, and the service from a client.

---

## 16. Role: vaultwarden

Purpose: the password manager, the most critical service on the server. It sits in `/srv/docker/app/vaultwarden/`:

| Path | Content |
| --- | --- |
| `compose.yml` | The container |
| `data/` | `db.sqlite3` (the vaults), `rsa_key.pem` (signs the login tokens), attachments, sends |
| `dump/db.sqlite3` | Consistent copy of the database, written before each backup |
| `logs/vaultwarden.log` | Logins, failed logins with the client IP, errors |

`data/` and `dump/` (0700) and `logs/` (0750) belong to `svc-docker`; `compose.yml` to root with group `svc-docker`. The route is in `/srv/docker/system/traefik/dynamic/vaultwarden.yml`.

**Check the Vaultwarden settings** / **Look up the Docker service user** / **Check that rootless Docker is configured** / **Check that Traefik is configured** / **Stop if Traefik is missing**
Stops if `traefik_domain` is empty, if `vaultwarden` is not in `traefik_networks` (so `proxy-vaultwarden` would not exist), or if Docker or Traefik are not set up yet.

**Install sqlite3**
On the host, for the dump script: the image has no `sqlite3`.

**Create the Vaultwarden directories** / **Rotate the Vaultwarden log**
The directories above, and `/etc/logrotate.d/vaultwarden`: daily, `copytruncate`, `vaultwarden_log_retention_days` (30) compressed files.

**Install the database dump script**
`/etc/backup/pre.d/vaultwarden`, run by the backup before each run. As `svc-docker` it runs SQLite's online backup (`.backup`) into `dump/db.sqlite3.new`, checks it with `PRAGMA integrity_check`, and only then replaces `dump/db.sqlite3`. The online backup is consistent while Vaultwarden is writing; a plain copy of `db.sqlite3` and its `-wal` file might not be. If the check fails, the old dump stays and the backup report shows a warning.

**Write the compose file** / **Start Vaultwarden**
`docker compose up --detach --remove-orphans --wait` as `svc-docker`. `--wait` waits for the image's health check (`/healthcheck.sh`, which calls `/alive`). With a new `vaultwarden_image`, the container is recreated: that is all `--tags update-containers` does. Settings are environment variables, so a change to one recreates the container too.

**Write the Traefik route**
`Host(vault.<domain>)` on `websecure` to `http://vaultwarden:8080`. Written after the container is up; Traefik picks it up without a restart.

### Design choices

- **SQLite, not Postgres.** One user or a family is far below what SQLite handles, and it is one container less to update and dump.
- **Only the internal network.** The container joins `proxy-vaultwarden` and nothing else: no published ports, no other service, and no route to the Internet. A compromised Vaultwarden cannot send the vaults anywhere. The cost: no favicon downloads (`DISABLE_ICON_DOWNLOAD`, the clients show generic icons), no e-mail, no Have I Been Pwned check from the server.
- **No admin page.** It is enabled only by `ADMIN_TOKEN`, which is not set: one secret less, and no page that can change every user. Sign-ups are a variable instead (`vaultwarden_signups_allowed`), turned on only to create an account.
- **No password hints** (`PASSWORD_HINTS_ALLOWED=false`): a hint is readable by whoever knows the e-mail address.
- **Hardening**: read-only root filesystem (only `/data`, `/logs` and a tmpfs `/tmp` are writable), every capability dropped, `no-new-privileges`. Vaultwarden listens on 8080 (`ROCKET_PORT`), because with no capabilities it cannot bind 80 inside the container.
- **Real client IP**: Traefik sets `X-Real-Ip`, the header Vaultwarden reads by default, so `logs/vaultwarden.log` shows who tried to log in.

Check:

```bash
docker-svc ps --filter name=vaultwarden --format '{{.Names}} {{.Status}}'        # healthy
docker-svc network inspect proxy-vaultwarden --format '{{range .Containers}}{{.Name}} {{end}}'   # traefik and vaultwarden
curl -s https://vault.greyroom.net/alive                                          # from a client: a date
sudo /etc/backup/pre.d/vaultwarden && sudo ls -l /srv/docker/app/vaultwarden/dump/
```

---

## 17. Role: immich

Purpose: the photo library. It sits in `/srv/docker/app/immich/`:

| Path | Content |
| --- | --- |
| `compose.yml` | Three containers: `immich_server`, `immich_postgres`, `immich_redis` (Valkey) |
| `library/` | Mounted as `/data`: `upload/` (originals), `library/` (storage template), `profile/`, `thumbs/`, `encoded-video/`, `backups/` (Immich's own database dumps) |
| `postgres/` | The live database (owned by Postgres's user, a subordinate UID on the host) |
| `dump/immich.sql.gz` | `pg_dumpall` output, written before each backup |
| `secrets/db-password` | The database password, mounted as a secret |

**Check the Immich settings** / **Look up the Docker service user** / **Check that rootless Docker is configured** / **Check that Traefik is configured** / **Stop if Traefik is missing**
Stops if `traefik_domain` is empty, if `immich` is not in `traefik_networks`, if the password is missing or contains anything but letters and digits (Immich's rule), or if Docker or Traefik are not set up yet.

**Create the Immich directories** / **Look for the database directory** / **Create the database directory**
The directories above. `postgres/` is created only when missing: the Postgres entrypoint gives it to its own user, and resetting the owner at every run would lock Postgres out.

**Write the database password**
`secrets/db-password` (0600, `svc-docker`), read by Postgres (`POSTGRES_PASSWORD_FILE`) and by the server (`DB_PASSWORD_FILE`). Postgres uses it only when it creates the database: a new password in the vault changes the file, not the database (see the maintenance guide).

**Install the database dump script**
`/etc/backup/pre.d/immich`, run by the backup before each run: `pg_dumpall --clean --if-exists` through `docker-svc exec`, compressed, then checked (`gzip -t` and the closing "dump complete" line) before it replaces the previous dump. `backup_exclude` leaves `postgres/` out of the backup: a copy taken while Postgres writes might not restore, and the dump has everything.

**Write the compose file** / **Start Immich**
`docker compose up --detach --remove-orphans --wait`. `--wait` waits for the health checks of the server (`immich-healthcheck`), Postgres and Valkey. With new images, the containers are recreated: that is all `--tags update-containers` does, so read the release notes first.

**Write the Traefik route**
`Host(photo.<domain>)` to `http://immich-server:2283`. Written after the containers are up.

### Design choices

- **No machine learning.** The `immich-machine-learning` container needs 1.5–3 GB of RAM and downloads its models from Hugging Face. Without it there is no face grouping and no smart search; search by file name, date, place and metadata still works. Machine learning must also be turned off in the admin settings, or every upload logs errors (README, "First setup"). It can be added later: a container on the backend network plus Hugging Face on the egress list.
- **Two networks, no Internet.** `proxy-immich` holds Traefik and the server; `backend` (`internal: true`) holds the server, Postgres and Valkey. Traefik cannot reach the database, and nothing reaches the Internet. The server would use it only for the version check (turned off in the settings) and the clients load the map tiles themselves.
- **Hardening**: the server runs with a read-only root filesystem (only `/data` and a tmpfs `/tmp` are writable), every capability dropped, `no-new-privileges`. Postgres and Valkey start as root to fix the owner of their data, then drop to their own user: they keep only `CHOWN`, `SETUID`, `SETGID` (and `DAC_OVERRIDE`, `FOWNER` for Postgres). Valkey holds only job queues, in a tmpfs.
- **Images**: Postgres is Immich's own build with the vector extensions, pinned as in the release's `docker-compose.yml`. Major Postgres upgrades need a dump and restore: Renovate leaves this image's tag alone, and it is changed by hand when the Immich release notes say so.
- **The whole library is backed up**, thumbnails and transcoded videos included: after a restore Immich has nothing to regenerate, at the cost of 10–20% more space on the USB disk and in S3.
- **Logs** go to the container log only (lost when the container is recreated). Requests, with the client IP, are in Traefik's access log.

Check:

```bash
docker-svc ps --filter name=immich --format '{{.Names}} {{.Status}}'    # three containers, healthy
curl -s https://photo.greyroom.net/api/server/ping                         # from a client: {"res":"pong"}
sudo /etc/backup/pre.d/immich && sudo ls -l /srv/docker/app/immich/dump/
```

---

## 18. Role: opencloud

Purpose: file sync and share, replacing Nextcloud. It sits in `/srv/docker/app/opencloud/`:

| Path | Content |
| --- | --- |
| `compose.yml` | The container |
| `config/opencloud.yaml` | The secrets and settings `opencloud init` generates at the first start |
| `data/storage/users/users/<user id>/` | Each user's personal space: the files and folders as the user sees them |
| `data/idm/`, `data/idp/` | The built-in user directory (LDAP) and login service (OpenID Connect) |
| `data/search/`, `data/thumbnails/`, `data/nats/` | Search index, thumbnails, internal message bus |
| `secrets/admin.env` | `IDM_ADMIN_PASSWORD`, read at the first start only |

`config/`, `data/` and `secrets/` (0700) belong to `svc-docker`. The route is in `/srv/docker/system/traefik/dynamic/opencloud.yml`, the backup hooks in `/etc/backup/pre.d/opencloud` and `/etc/backup/post.d/opencloud`.

**Check the OpenCloud settings** / **Look up the Docker service user** / **Check that rootless Docker is configured** / **Check that Traefik is configured** / **Stop if Traefik is missing**
Stops if `traefik_domain` is empty, if `opencloud` is not in `traefik_networks` or its alias is missing from `traefik_network_aliases`, if the admin password is shorter than 16 characters, or if Docker or Traefik are not set up yet.

**Create the OpenCloud directories** / **Write the initial admin password**
The directories above and `secrets/admin.env` (0600). OpenCloud reads the password only when it creates its user directory, at the first start: a new value in the vault later changes nothing (change it in the web interface).

**Install the backup hooks**
`pre.d/opencloud` stops the container (up to `opencloud_stop_timeout`, 60 s) and leaves a mark in `/run`; `post.d/opencloud` starts it again only if that mark is there, so a container stopped by hand stays stopped. OpenCloud's backup guide asks for this: its files and their metadata (extended attributes) are copied consistently only while it is stopped. OpenCloud is down for the duration of both copies, usually a few minutes at 02:30.

**Write the compose file** / **Start OpenCloud** / **Write the Traefik route**
As for the other services: `docker compose up --detach --remove-orphans --wait`, then `Host(cloud.<domain>)` to `http://opencloud:9200`.

### Design choices

- **The production release line** (`opencloudeu/opencloud`, 7.2.x), not rolling (`opencloud-rolling`, every three weeks): OpenCloud's own lifecycle page calls rolling "the wrong choice for production". Production releases come about every six months; patch releases in between arrive through Renovate.
- **PosixFS storage, the default**: files are stored as the user sees them, metadata in extended attributes (`user.oc.*`), no database. Backup and restore are plain file operations, and restic keeps the extended attributes. It also makes the Nextcloud migration a file copy (maintenance guide).
- **Reaching its own URL without the Internet.** OpenCloud checks every login against `OC_URL` (`https://cloud.<domain>`): it fetches the login service's configuration and keys from there. Its container is only on `proxy-opencloud`, which is internal. `traefik_network_aliases` gives Traefik the name `cloud.<domain>` on that network, so the name resolves to Traefik inside the network and the check goes through Traefik with the real certificate (`OC_INSECURE: false`). Tested locally: from inside OpenCloud, `https://cloud.test/.well-known/openid-configuration` answered through a Traefik alias on an internal network, and nothing else was reachable.
- **Hardening**: runs as root inside the container (`user: "0:0"`), which is `svc-docker` on the host and owns the data: PosixFS needs every file owned by the user OpenCloud runs as. Read-only root filesystem, a tmpfs `/tmp`, every capability dropped, `no-new-privileges`. The image's default user (1000) would map to a subordinate UID on the host and complicate both the migration and the restore.
- **`exec opencloud server`**: OpenCloud, not a shell, is process 1 and gets the stop signal: it stops in about a second instead of being killed after the timeout.
- **No Collabora** (no office editing in the browser): it parses untrusted documents on the server, needs more capabilities and its own host name. Documents open in the desktop and mobile apps.
- **No e-mail, no update check, no basic authentication**: there is no SMTP; Renovate reports new versions; clients log in with OpenID Connect. Public links must have a password.
- **Files added on disk** (the migration) are picked up at the next start ("assimilation") but are not virus-scanned by OpenCloud; the nightly ClamAV and YARA scans of `/srv` cover them.

Check:

```bash
docker-svc ps --filter name=opencloud --format '{{.Names}} {{.Status}}'      # healthy
curl -s https://cloud.greyroom.net/status.php                                  # from a client: "installed":true
```

---

## 19. Role: paperless

Purpose: the document archive, with OCR in Italian and English. It sits in `/srv/docker/app/paperless/`:

| Path | Content |
| --- | --- |
| `compose.yml` | Three containers: `paperless`, `paperless_db` (Postgres 18), `paperless_broker` (Valkey) |
| `media/documents/originals/` | The uploaded files, as `<year>/<correspondent>/<title>.pdf` |
| `media/documents/archive/` | The OCR'd PDF/A versions; `thumbnails/` |
| `data/` | Search index, the classifier's model, logs |
| `consume/` | Files dropped here are imported (not used: uploads go through the web and the app) |
| `postgres/` | The live database (left out of the backup) |
| `dump/paperless.sql.gz` | `pg_dumpall` output, written before each backup |
| `secrets/` | Database password, secret key, admin password |

**Check the Paperless settings** / **Look up the Docker service user** / **Check that rootless Docker is configured** / **Check that Traefik is configured** / **Stop if Traefik is missing**
Stops if `traefik_domain` is empty, if `paperless` is not in `traefik_networks`, if a secret is missing or too short (the database password: letters and digits only), or if Docker or Traefik are not set up yet.

**Read the service user's subordinate ID ranges** / **Compute the host IDs of the container's UID 1000** / **Check the subordinate ID ranges**
Paperless runs as its image's own user, UID/GID 1000 inside the container. Rootless Docker maps container UID 0 to `svc-docker` and UIDs 1 and up to its subordinate range in `/etc/subuid` (and `/etc/subgid`): UID 1000 is the range start plus 999 on the host. The role reads both ranges and gives Paperless's directories to that ID.

**Create the Paperless directories** / **Look for the database directory** / **Create the database directory** / **Write the secrets**
The directories above: `data/`, `media/`, `consume/`, `export/` to Paperless's host ID (0750); `secrets/` to Paperless's host ID with group `svc-docker` (Paperless enters it, Docker reaches the files to mount them); the secret files to Paperless's host ID, 0400. `postgres/` to the container's `postgres` user (host ID = subuid start + 998, 0700): Postgres 18 keeps its data in `18/docker` inside the mount, and its entrypoint, after switching from root to `postgres`, must enter the mount itself. Postgres reads the password file as root, which keeps `DAC_OVERRIDE`.

**Install the database dump script**
`/etc/backup/pre.d/paperless`: `pg_dumpall` through `docker-svc exec`, checked (gzip and the closing "dump complete" line) before it replaces the previous dump. `postgres/` is in `backup_exclude`.

**Write the compose file** / **Start Paperless** / **Write the Traefik route**
As for the other services; `Host(document.<domain>)` to `http://paperless:8000`. The health check is the image's own, with five minutes for the first start, which creates the database tables.

### Design choices

- **Rootless mode with the image's user** (`user: "1000:1000"`, Paperless's documented rootless setup): the container starts directly as that user, with no internal privilege change, so it needs **no capability**. Running it as root (UID 0 = `svc-docker`) was tested and does not work without capabilities: the entrypoint then changes owners and users, and the application's code in the image belongs to UID 1000, which root without `DAC_OVERRIDE` cannot write to.
- **Not read-only**: at start the image compiles its Python code inside itself. Every capability is still dropped, with `no-new-privileges`.
- **Two networks, no Internet**: `proxy-paperless` holds Traefik and Paperless; `backend` (internal) holds Paperless, Postgres and Valkey. The Italian and English OCR data ship with the image; other languages would be downloaded at start.
- **No e-mail import, no Tika/Gotenberg, no AI**: documents arrive through the web interface and the mobile app. E-mail import would need an IMAP mailbox and egress, and Tika/Gotenberg parse untrusted Office and HTML files on the server. The AI features need a local LLM that the i3-7100T and 8 GB cannot run usefully. Paperless's built-in classifier still learns tags, correspondents and document types from the documents you classify.
- **Readable files on disk** (`PAPERLESS_FILENAME_FORMAT`, `<year>/<correspondent>/<title>`): if Paperless is gone, the originals are still browsable. The value carries `!unsafe` in the defaults, so Ansible does not render Paperless's own template syntax.
- **One task worker, two threads**: one document at a time, two pages in parallel, on 2 cores and 4 threads.

Check:

```bash
docker-svc ps --filter name=paperless --format '{{.Names}} {{.Status}}'    # three containers, healthy
curl -s -o /dev/null -w '%{http_code}\n' https://document.greyroom.net/accounts/login/   # from a client: 200
sudo /etc/backup/pre.d/paperless && sudo ls -l /srv/docker/app/paperless/dump/
```

---

## 20. Role: uptime_kuma

Purpose: tell you on Telegram when a service stops answering, and when its certificate is close to expiry. It sits in `/srv/docker/app/uptime-kuma/`:

| Path | Content |
| --- | --- |
| `compose.yml` | One container, `uptime-kuma` |
| `data/` | The SQLite database: monitors, notifications, history, the admin account |
| `dump/kuma.db` | SQLite online backup, written before each backup |

**Check the Uptime Kuma settings** / **Look up the Docker service user** / **Check that rootless Docker is configured** / **Check that Traefik is configured** / **Stop if Traefik is missing**
Stops if `traefik_domain` is empty, if `uptime-kuma` is not in `traefik_networks`, or if Docker or Traefik are not set up yet.

**Read the service user's subordinate ID ranges** / **Check the subordinate ID ranges** / **Compute the host IDs of the container's UID 1000** / **Create the Uptime Kuma directories**
The `slim-rootless` image runs as its own user, `node` (UID 1000): on the host, the subordinate range start plus 999, as for Paperless. `data/` (0750) and `dump/` (0700) belong to that ID.

**Install the database dump script**
`/etc/backup/pre.d/uptime-kuma`: SQLite's online backup with the `sqlite3` inside the image (`docker-svc exec`), then `PRAGMA integrity_check` before it replaces the previous dump.

**Write the compose file** / **Start Uptime Kuma** / **Write the Traefik route**
As for the other services; `Host(health.<domain>)` to `http://uptime-kuma:3001`. The health check is the image's own `/app/extra/healthcheck`.

### Design choices

- **Checks through Traefik, under the public names**: on `proxy-uptime-kuma`, Traefik carries the aliases `vault.`, `photo.`, `cloud.` and `document.<domain>` (`traefik_network_aliases`, as for OpenCloud). A check follows the same path as a browser: Traefik, the certificate and the application. A stopped container shows as an error (Traefik answers 502 or 504).
- **No Docker socket**: Uptime Kuma could watch containers through it, but the socket is full control of every container. The HTTP checks cover the same failures.
- **Internet only for the alerts**: a second network, `egress`, gives the container a way out, filtered by OPNsense like the rest of the server; Telegram is already allowed there. The services' names resolve to Traefik on `proxy-uptime-kuma` first (Docker's DNS answers for aliases on the container's networks).
- **`slim-rootless` image**: no Chromium (no browser checks), no embedded MariaDB; it runs as `node`, read-only, with every capability dropped. About 110 MB of RAM.
- **SQLite** (`UPTIME_KUMA_DB_TYPE=sqlite`): no database page at the first start, one file to back up.
- **Set up in the web interface**: monitors and the Telegram notification are kept in the database, not in the repository; the dump puts them in the backup. Configuration as code would mean another tool (Gatus was the alternative considered).
- **The first visitor creates the admin account**: open `https://health.<domain>` right after the first run.

Check:

```bash
docker-svc ps --filter name=uptime-kuma --format '{{.Names}} {{.Status}}'    # healthy
sudo /etc/backup/pre.d/uptime-kuma && sudo ls -l /srv/docker/app/uptime-kuma/dump/
```

---

## 21. Renovate (image updates)

Purpose: propose an update whenever a new version of a pinned image is released, with the release notes, and change nothing on its own. Three files, no role: Renovate does not run on the server.

**`.github/workflows/renovate.yml`**
A GitHub Actions workflow, every Saturday at 05:00 UTC and on demand (*Run workflow*), with no third-party action. Two steps:

1. **Run Renovate**: reads the image from `.github/renovate-image` (at the commit the run started from; anything but `ghcr.io/renovatebot/renovate:*` stops the run) and starts it with `docker run`. The token goes in by name (`--env RENOVATE_TOKEN`), not on the command line. Renovate logs JSON (`LOG_FORMAT=json`): the output is saved for the next step and shown in the job log one line per message (time, level, message, branch, PR title, result). `RENOVATE_EXIT_CODE_FOR_ERRORS` (experimental) makes the container exit non-zero when the run does not end in `done`, so the job turns red and GitHub e-mails it.
2. **Notify Telegram**: reads Renovate's own verdict, the `result` of the "Repository finished" line. Anything but `done` sends "❌ RENOVATE DID NOT FINISH" with the result, up to five logged errors and the link to the run. A finished run sends "🔄 RENOVATE" with the new PRs, the updates to do by hand (the "Pending Approval" section of the Dependency Dashboard issue) and any errors logged; nothing is sent when there is none of these. The updates to do by hand are repeated every Saturday until they are done.

Before this, the workflow used `renovatebot/github-action`, which runs the same `docker run`. It hid Renovate's output from the next step, and Renovate exits 0 when it stops early: a run interrupted after one branch looked successful and sent nothing.

**`.github/renovate-image`**
One line, `ghcr.io/renovatebot/renovate:44`. The major tag, not a pinned version: Renovate publishes several releases a week, and each would be a PR to merge; with the major tag every run uses the newest 44.x. A new major (45) comes as a normal PR, because this is a plain file that the workflow token may edit, unlike the workflow itself.

- **Token**: the job's own `GITHUB_TOKEN`, with the permissions listed in the workflow (contents, pull requests, issues, statuses: write; statuses is for the `renovate/stability-days` check that `minimumReleaseAge` sets on each branch, and without it Renovate stops after creating the first branch). It is created for the run and expires with it; there is no personal token to store or renew. The repository must allow Actions to create pull requests (README, "Image updates").
- **Telegram**: `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` as repository secrets. Secrets are not given to workflows started from forks.
- **60 days without activity**: in a public repository GitHub disables scheduled workflows after 60 days with no commits, and says so by e-mail. Merging Renovate's PRs counts as activity; if it happens, re-enable the workflow under *Actions → Renovate*.
- **The runner image** (`runs-on: ubuntu-26.04`) is the only version left in the workflow file. A `GITHUB_TOKEN` cannot edit workflow files, so Renovate lists a new major under Pending Approval and the change is made by hand, about every two years.

**`renovate.json`**

| Setting | Why |
| --- | --- |
| `enabledManagers: ["custom.regex", "github-actions"]` | The container images, Renovate's own image, and the workflow's runner. The collections in `requirements.yml` use open ranges and need no PRs. |
| Custom regex manager on `roles/*/defaults/main.yml` | Finds every `<name>_image: "<image>:<tag>@<digest>"` line and updates tag and digest together. A new image added to a role in the same form is picked up with no change here. |
| Custom regex manager on `.github/renovate-image` | Renovate's own image, major tag only: a new major is a normal PR. |
| `minimumReleaseAge: 3 days` | A release must be 3 days old before Renovate proposes it: broken releases are usually replaced by then. |
| `minimumReleaseAgeBehaviour: timestamp-optional` | ghcr.io gives no release date. With the default, Immich updates would be held forever; with this, they are proposed without the wait. |
| Groups "Immich" and "Paperless" | One PR per service, by file (`roles/immich/**`, `roles/paperless/**`): an image both use (Valkey) gets one PR in each service's group, never a PR named after the other service. A Postgres major in a group is the group's "major" update (e.g. "Update Immich (major)"), still under Pending Approval. |
| Postgres majors: `dependencyDashboardApproval` | Any image with `postgres` in its name. A major is listed under Pending Approval and in the Telegram message, never opened as a PR: Immich's tag follows the Immich release's `docker-compose.yml`, and every major needs a dump and restore. Digest updates of the same tag are normal PRs. |
| Workflow file (`github-actions`): majors with `dependencyDashboardApproval`, the rest off | The runner image: listed only, because the `GITHUB_TOKEN` cannot edit workflow files. |
| `automerge: false` | Written out although it is the default: nothing is ever merged by Renovate. The `protect main` ruleset (README, "Image updates") makes GitHub refuse it anyway. |
| `config:recommended` | Separate PRs for major updates, the Dependency Dashboard issue, and the `renovate` label. |

Tested with Renovate 44 in dry-run on this repository: it finds the five images of the three roles, its own image and the workflow's runner, and computes three PRs (Immich v3.4.0, Traefik v3.7.17, a new digest for Traefik v3.7.16) plus two approval items (Postgres 16, runner `ubuntu-26.04`). The local dry run stops before the approval step: the first run on GitHub confirmed that the last two are listed, not opened. The Telegram step was tested with sample logs: finished with new PRs and pending items, interrupted (`repository-changed`), no log at all, finished with an error.

**Do not tick the boxes under Pending Approval.** Ticking asks Renovate to open the PR: for the runner it fails (no permission), for Postgres it would invite merging an upgrade that needs a dump and restore. Do them by hand (maintenance guide, "Image updates").

Applying an update is the maintenance guide's "Image updates".

---

## 22. Role: update_os

Purpose: a full upgrade, run by hand with `--tags update-os`. unattended-upgrades installs Debian's and Docker's updates every night (role `base`); this tag is for what it keeps back (a package that needs new dependencies, shown as "Kept back" in its report), with the same reboot check.

**Record the installed package versions** / **Keep the Docker version before the upgrade**
Notes the `docker-ce` version before the upgrade.

**Upgrade all packages**
`apt dist-upgrade` with `autoremove` and `autoclean`. `dist` instead of `safe` because a stable point release sometimes needs new dependencies; it stays within Debian 13 and never moves to a new release.

**Record the package versions after the upgrade**
Reads the versions again, to tell whether Docker changed.

**Check whether a newer kernel is waiting** / **Check whether a package requested a reboot**
Two independent signals:

- `needrestart -b -k` prints `NEEDRESTART-KSTA`: `1` = running the newest installed kernel, `2` or `3` = a newer one is installed and waiting for a reboot. On Debian this is the reliable check: `/run/reboot-required` is not created consistently for kernel upgrades, as it is on Ubuntu.
- `/run/reboot-required`, which some packages create.

**Decide whether to reboot** / **Report a pending reboot that is not allowed** / **Send the pending reboot to Telegram** / **Reboot the server**
Reboots if either signal says so and `update_os_allow_reboot` is true. Otherwise it prints a message in the job output, sends "🔁 UPDATE-OS: REBOOT REQUIRED" to Telegram, and changes nothing. On prod-srv-01 it is false (`main.yml`): the disk is encrypted and the passphrase is typed at the console at every boot.

**Look up the Docker service user** / **Restart the rootless Docker daemon after a Docker upgrade**
If `docker-ce` changed and there was no reboot, it restarts the rootless daemon: the new binary takes effect only on restart. Containers come back through their restart policy. It is skipped if the user does not exist (Docker not yet configured).

**Check that the rootless Docker daemon is running**
After an upgrade or a reboot, waits until the user `docker.service` is active again. If it fails, the playbook fails.

Container images are **not** updated here: they follow the `update-containers` tag, with the versions pinned in the repository and proposed by Renovate.

---

## 23. The pre-commit hook

`.githooks/pre-commit` runs before every commit, once enabled with `git config core.hooksPath .githooks` (one time per clone). For every staged file named `vault.yml` or `vault.yaml`, it reads the **staged** version (`git show :<file>`) and refuses the commit if its first line does not start with `$ANSIBLE_VAULT;`. It reads the staged version, not the working copy, because that is what would end up in the history.

---

## 24. Files the playbook creates on the server

| Path | Role | Content |
| --- | --- | --- |
| `/etc/systemd/timesyncd.conf.d/10-local.conf` | base | NTP servers |
| `/etc/systemd/journald.conf.d/10-size.conf` | base | Journal size |
| `/etc/apt/apt.conf.d/52unattended-upgrades-local` | base | Origins installed every night (Debian stable, updates, security; Docker) |
| `/etc/systemd/system/apt-daily{,-upgrade}.timer.d/50-schedule.conf` | base | Apt jobs at 03:45 and 04:00 |
| `/usr/local/sbin/unattended-upgrades-report`, `/etc/systemd/system/apt-daily{,-upgrade}.service.d/50-telegram.conf` | base | Telegram report after each apt job |
| `/var/lib/unattended-upgrades-report/last-run` | base | Last unattended-upgrades run reported |
| `/etc/apt/apt.conf.d/20auto-upgrades` | base | Daily automatic updates |
| `/etc/needrestart/conf.d/50-ansible.conf` | base | Automatic service restarts |
| `/etc/sudoers.d/90-admin` | hardening | sudo for the admin |
| `/etc/ssh/sshd_config.d/00-hardening.conf` | hardening | SSH hardening |
| `/etc/sysctl.d/60-hardening.conf` | hardening | Kernel hardening |
| `/etc/network/interfaces` (+ `.new`, `.rollback`) | network | VLAN configuration |
| `/etc/resolv.conf` | network | DNS |
| `/usr/local/sbin/network-rollback`, `/etc/systemd/system/network-rollback.service` | network | Safety net |
| `/etc/nftables.conf` | firewall_host | Host firewall |
| `/etc/apt/keyrings/docker.asc`, `/etc/apt/sources.list.d/docker.sources` | docker_rootless | Docker repository |
| `/etc/sysctl.d/60-rootless-docker.conf` | docker_rootless | Unprivileged ports from 80 |
| `~svc-docker/.config/docker/daemon.json` | docker_rootless | Container log limits |
| `~svc-docker/.config/systemd/user/docker.service` | docker_rootless | Rootless daemon |
| `/usr/local/bin/docker-svc` | docker_rootless | Wrapper for the admin |
| `/srv/docker/{system,app}/` | docker_rootless | Compose files and data of the containers |
| `/srv/docker/system/traefik/` | traefik | Compose file, configuration, certificates, Cloudflare token, logs |
| Docker networks `proxy-<name>` | traefik | One internal network per service in `traefik_networks` |
| `/etc/logrotate.d/traefik` | traefik | Daily rotation of the Traefik logs |
| `/srv/docker/app/vaultwarden/` | vaultwarden | Compose file, data, database dump, log |
| `/srv/docker/system/traefik/dynamic/vaultwarden.yml` | vaultwarden | Traefik route |
| `/etc/logrotate.d/vaultwarden`, `/etc/backup/pre.d/vaultwarden` | vaultwarden | Log rotation, database dump before the backup |
| `/srv/docker/app/immich/` | immich | Compose file, library, database, dump, password |
| `/srv/docker/system/traefik/dynamic/immich.yml` | immich | Traefik route |
| `/etc/backup/pre.d/immich` | immich | Database dump before the backup |
| `/srv/docker/app/opencloud/` | opencloud | Compose file, configuration, files, admin password |
| `/srv/docker/system/traefik/dynamic/opencloud.yml` | opencloud | Traefik route |
| `/etc/backup/pre.d/opencloud`, `/etc/backup/post.d/opencloud` | opencloud | Stop before the backup, start after it |
| `/etc/backup/post.d/` | backup | Applications' scripts run after the backup |
| `/srv/docker/app/paperless/` | paperless | Compose file, documents, database, dump, secrets |
| `/srv/docker/system/traefik/dynamic/paperless.yml` | paperless | Traefik route |
| `/etc/backup/pre.d/paperless` | paperless | Database dump before the backup |
| `/srv/docker/app/uptime-kuma/` | uptime_kuma | Compose file, database (monitors, notifications, history), dump |
| `/srv/docker/system/traefik/dynamic/uptime-kuma.yml` | uptime_kuma | Traefik route |
| `/etc/backup/pre.d/uptime-kuma` | uptime_kuma | Database dump before the backup |
| `/etc/homelab/notify.env` | notify | Telegram token (0600) |
| `/usr/local/sbin/notify-telegram` | notify | Notification helper |
| `/usr/local/sbin/clamav-scan`, `/etc/systemd/system/clamav-scan.{service,timer}` | clamav | Scheduled scan |
| `/root/clamav-quarantine/` | clamav | Quarantine |
| `/etc/smartd.conf`, `/etc/smartmontools/run.d/20telegram` | monitoring | SMART (physical hosts only) |
| `/usr/local/sbin/disk-space-check`, `/etc/systemd/system/disk-space-check.{service,timer}` | monitoring | Disk space |
| `/usr/local/sbin/integrity-check`, `/etc/systemd/system/integrity-check.{service,timer}` | integrity | Integrity check |
| `/var/lib/integrity-check/state` | integrity | Last findings sent to Telegram |
| `/etc/yara/rules/` | yara | YARA rules |
| `/usr/local/sbin/yara-scan`, `/etc/systemd/system/yara-scan.{service,timer}` | yara | Scheduled YARA scan |
| `/var/log/yara/scan_*.log` | yara | Scan logs |
| `/etc/homelab/backup.env` | backup | restic password and S3 keys (0600) |
| `/usr/local/sbin/backup`, `/etc/systemd/system/backup.{service,timer}` | backup | Daily backup |
| `/etc/backup/pre.d/` | backup | Applications' dump scripts |
| `/mnt/backup-usb`, `/var/cache/restic` | backup | USB mount point, restic cache |

Each file begins with a "Managed by Ansible" comment: changes made by hand are overwritten at the next run.

---

## 25. Known limits and points to review

- **IPv6 is not configured.** nftables accepts ICMPv6, but SSH and service rules are IPv4 (`ip daddr`). With IPv6 on the VLANs, SSH and services would be reachable only over IPv4. That is fine as long as IPv6 is off on OPNsense for those networks.
- **`AllowTcpForwarding no`** disables SSH tunnels. To reach a service from outside, use WireGuard.
- **`ip_unprivileged_port_start=80`** applies to every user, not just `svc-docker`.
- **`kernel.unprivileged_bpf_disabled=1`** cannot be undone without a reboot.
- **The admin's sudo is passwordless**: whoever has the admin's SSH key is root. Protect it accordingly: it lives on the laptop the playbook runs from.
- **The network role reboots** whenever the configuration changes. Run it in a maintenance window, **at the console**: the disk is encrypted, so the server waits for the passphrase after the reboot, and Ansible's 240 s wait to reconnect (and the 5-minute rollback, which starts only once the system is up) assume someone types it promptly. The same applies to the automatic rollback reboot.
- **Docker upgrades restart every container at night.** unattended-upgrades installs Docker's packages at 04:00 and the report restarts the rootless daemon: the services are down for a minute or two, and a Docker release that breaks something is installed without review (the report says which containers did not come back; maintenance guide, "Docker needs attention").
- **The encrypted disk means no unattended reboot.** After a power cut the server stays at the passphrase prompt until someone types it: services, backups and notifications stop meanwhile. `update_os_allow_reboot` is false for this reason. Remote unlock (dropbear in the initramfs, or Clevis/Tang) is possible but not set up.
- **`/etc/resolv.conf`** is written only by the network role. Before you run it, the server keeps the DNS servers set by the installer.
- **The Docker key checksum** is pinned. If Docker ever rotates its key, the task fails on purpose: check the new fingerprint on docs.docker.com, then update `docker_apt_key_checksum`.
- **The integrity check and YARA run on the server they watch.** An attacker with root can stop the timers or edit the scripts. What they add is early warning against tooling that does not expect them, and a trail: a sudden silence (no daily ClamAV message, or an integrity alert followed by nothing) is a signal too. Logs leave the server only once remote logging exists.
- **No full file integrity database (AIDE).** It would flag every security update that unattended-upgrades installs. The integrity role checks instead the specific things Ebury-style implants change, and the monthly `--check --diff` run catches drift in the managed files.
- **The YARA rules change only when you refresh them** with `scripts/update-yara-rules.sh`; the server does not download them.
- **The memory scan covers OpenSSH and suspicious processes only**, not every container process.
- **One certificate for every name.** If the wildcard expires (DNS challenge failing for weeks), every service fails at once. Uptime Kuma warns when the certificate is close to expiry.
- **The dashboard is protected by a password only**; it is reachable only through WireGuard, like everything else.
- **The backup is file-level.** Databases are consistent only through the dump scripts in `/etc/backup/pre.d/`; a database file copied while it is written may not restore. Every application role must add its dump script.
- **A container escape reaches the Vaultwarden data.** Disk encryption (LUKS) protects only a server that is off or a disk that is removed; while Debian runs, files are readable by whoever has the permissions. Ordinary users cannot read `data/` (0700 `svc-docker`, inside a 0750 root:`svc-docker` directory). An escape from any container, though, lands as `svc-docker`, which owns the files of every container: it reads `db.sqlite3`, the dump and `rsa_key.pem`. Root needs a second exploit, in the kernel. What the database gives away:
  - **The vault items are encrypted**: names, passwords, URLs and notes are encrypted on the client with a key derived from the master password, which the server never sees (it keeps a hash of it, hashed again with PBKDF2). Reading them takes guessing the master password offline, so its strength and the KDF decide: use a long passphrase and Argon2id (account settings → Security → Keys).
  - **In clear**: account e-mails, dates, the number of items, organization memberships, and the TOTP secret of the two-factor login (`twofactor.data`), so two-factor does not help here.
  - **Worse than the database**: as `svc-docker` the attacker controls the Docker daemon, so it can change Vaultwarden itself and serve a tampered web vault that captures the master password at the next browser login, or sign login tokens with `rsa_key.pem`. The desktop and mobile apps and the browser extension are not served by the server: use them, not the web vault, to unlock day to day.
  - A separate rootless user for Vaultwarden alone would keep an escape from the other services away from it, at the cost of a second Docker daemon. Not done for now (one person to maintain it).
- **Vaultwarden sends no e-mail.** Without SMTP (egress is blocked) there is no reset by mail and no new-device notice: the master password must be on the emergency secrets key, with an encrypted export of the vault refreshed every three months (maintenance guide).
- **Both backup copies use the same password.** Losing it loses both; keep it on the emergency secrets key.
- **The S3 key on the server can delete**, but the R2 bucket lock keeps everything written in the last 90 days: an intrusion must be noticed, and the history restored from S3, within 90 days. Older objects can be deleted by whoever holds the key.
- **The S3 copy only grows**: no `forget` or `prune` there. With data that mostly accumulates (photos, documents) the growth is small; clean up by hand when the cost matters.
- **ClamAV and YARA scan the Immich library every night**, as the project document asks (user data in the volumes). With a large library the scans get long; YARA skips files over `yara_max_file_size_mb` (most videos). If the nightly scans run into the day, leave out `library/thumbs` and `library/encoded-video`, which Immich generates itself.
- **Paperless opens untrusted files on the server**: OCR, Ghostscript and the PDF tools read every upload. Uploads come only from you, through WireGuard; e-mail import, which would let others send documents, is off.
- **Paperless's files belong to a subordinate UID** on the host (container UID 1000). A restore with `restic` keeps the numeric owners; files copied in by hand need `chown` to that ID (maintenance guide).
- **Uptime Kuma runs on the server it watches**: it reports a service that stops answering, not the whole server going down (power cut, a reboot waiting for the disk key). That shows as the missing 02:30 backup message on Telegram.
- **Uptime Kuma is the only application with Internet access**, for the Telegram alerts: its own network `egress`, filtered by OPNsense like the rest of the server. Its monitors and its Telegram token live in its database, set up in the web interface, not in the repository.
- **OpenCloud is stopped during the nightly backup**, for the duration of both copies (a few minutes; longer on the first run and on Sundays, with prune and check). Desktop clients retry by themselves.
- **Immich's database password is set once.** Changing `vault_immich_db_password` alone breaks the connection: change it in Postgres first (maintenance guide).
- **ClamAV uses 1–1.5 GB of RAM** for clamd. On an OptiPlex 3050 with 8 GB that is noticeable once Immich is running.

---

## 26. How it was tested

On a Debian 13 VM (the official cloud image, switched to ifupdown to match a netinst install):

| Test | Result |
| --- | --- |
| Full run from scratch | OK, 59 tasks |
| Second full run | `changed=0` (idempotent) |
| `--tags update-os` with a forced reboot | Reboot, then rootless Docker active again on its own |
| `--tags network` with a correct configuration | VLAN interface, rules and tables as expected, rollback cancelled |
| `--tags network` with a configuration that cuts access | Server back on the previous configuration by itself; Ansible fails with an explicit message |
| ClamAV with the EICAR file | Detected, quarantined, notification attempted |
| Rootless container on port 80 | The container sees the real client IP |

Bugs found and fixed during these tests: `ansible_managed` undefined in `copy` tasks on ansible-core 2.20; clamd start skipped on the first run; unattended-upgrades not limited to security updates; the rootlesskit network colliding with `10.0.2.0/24`; the network rollback reported as a success.

The `integrity` and `yara` roles and the NTP and `LogLevel` changes were tested on a Debian 13 container with systemd and SSH (the lab VM was off):

| Test | Result |
| --- | --- |
| `base`, `hardening`, `integrity`, `yara` from scratch, then again | OK; the second run changes only the two timesyncd tasks, because systemd does not run timesyncd in a container |
| Integrity check on a clean system | Only the container's NTP findings |
| Planted: setuid copy of libkeyutils with `libkeyutils.so.1` pointed at it, an unpackaged `.so`, an ownerless file, `/etc/ld.so.preload`, `LogLevel QUIET` in a `Match` block, `SSHD_OPTS="-q"`, a fake rsyslogd in the `ssh.service` cgroup, a listener on `@event-0YsOG9WSOE` | All reported; check time 0.6 s |
| YARA on clean Debian 13 and on six application images | No matches |
| YARA with an EICAR file in `/tmp` | Detected, notification attempted |
| A rule file removed from the repository | Deleted from the server at the next run |

Bugs found and fixed during these tests: the rules and the compiled rules matching themselves; ESET's SSHDoor rules matching a clean sshd in memory; packaged symlinks hiding the implant they point to; Ansible's `fileglob` not matching subdirectories, which emptied the rule directory.

The `backup` role was tested in the same container, with an S3 server (rclone `serve s3` with TLS) and a tmpfs in place of the USB disk:

| Test | Result |
| --- | --- |
| First run without the USB disk | S3 repository created, USB skipped with a message |
| Nightly run without the USB disk | `❌ BACKUP FAILED`: USB "not connected", S3 snapshot saved |
| Disk connected, `--init`, nightly run on the maintenance day | `✅ BACKUP OK` for both, prune and check OK |
| Second and third run of the role | `changed=0` |
| A failing pre-backup script, and the USB repository moved away | Warning for the script; USB "repository does not exist", not re-created; S3 OK |
| `backup usb restore` and `backup s3 restore` | Files identical to the originals |

Bug found and fixed: the USB disk was never unmounted, because the mount ran in a subshell.

The `traefik` templates were rendered by Ansible and run with Docker Compose (podman, rootless) on the laptop, with a fake Cloudflare token:

| Test | Result |
| --- | --- |
| Start with `--wait` | Healthy; the only error is the expected ACME failure (fake token) |
| HTTP | Permanent redirect to HTTPS (301 for GET, 308 for other methods) |
| Dashboard without password, with the right one, with a wrong one | 401, 200, 401 |
| Response headers | HSTS (1 year, subdomains) and `nosniff` |
| Unknown host name, TLS 1.1 | 404, refused |
| `sniStrict` with no valid certificate yet | TLS refused, as intended |
| Container settings | Read-only root filesystem, capabilities dropped |

The container roles were also run in rootless Podman on the laptop, with the same images and options:

| Test | Result |
| --- | --- |
| Vaultwarden 1.37.5 with the role's options (read-only, no capabilities, port 8080, internal network), in rootless Podman | Healthy; writes only to `data/` and `logs/`; no Internet access; `/admin` disabled; online SQLite backup of the live database passes `integrity_check` |
| Immich v3.3.6 with the role's options (server read-only with no capabilities; Postgres and Valkey with the reduced capabilities), in rootless Podman | Admin created, an image uploaded (original and thumbnails written); `pg_dumpall` dump restored into an empty Postgres with the asset present |
| OpenCloud 7.2.4 with the role's options (root in the container, read-only, no capabilities, `exec`), in rootless Podman | Starts healthy; stops in about a second; user `mattia` created; files copied into its space with OpenCloud stopped and `tar --no-overwrite-dir` appear after the start, names with spaces and accents, original dates and identical content; reachable through a Traefik alias on an internal network |
| restic 0.19 on `user.oc.*` extended attributes | Backed up and restored |
| Paperless 3.4.2 as UID 1000 with no capabilities, Postgres 18.6 and Valkey on an internal network, in rootless Podman | Healthy; as root without capabilities, or read-only, it does not start (see the design choices); a scanned Italian invoice OCR'd word for word (accents included) with its date found; `pg_dumpall` restored into an empty Postgres 18 with the document; about 0.7 GB of RAM at rest |

On prod-srv-01 (November 2026), after the first deployment:

| What | Result |
| --- | --- |
| Full run on a fresh Debian 13 with an encrypted disk, then the VLANs | OK, after the fixes below |
| Traefik with the real domain | Let's Encrypt wildcard certificate for `greyroom.net` and `*.greyroom.net` |
| Vaultwarden | Account created with sign-ups opened once, then closed |
| Immich | Library and database migrated from a v2.7.5 instance (moved to VectorChord there first, then restored through Immich's web restore; file paths moved from `/usr/src/app/upload` to `/data` by Immich itself) |
| Backup | Both copies OK with the Immich library (15 GB) |
| Renovate on GitHub Actions | 3 PRs, Postgres 16 and the runner listed under Pending Approval, Telegram summary; the Traefik PR merged and applied with `update-containers` |
| Static checks (November 2026) | ansible-lint 26.11 with the production profile: no findings; shellcheck on the 11 rendered scripts: no findings; every link and anchor in the documentation resolves |

Bugs found and fixed in production: `update-os` failing on a host where `base` never ran (needrestart missing); the Docker apt cache refreshed only when the repository file changed; the wildcard certificate refused because the apex and wildcard TXT records were checked before Cloudflare served both (`delayBeforeChecks`); service restarts lost when a run failed midway, which left timesyncd on Debian's NTP pool (`force_handlers`); Renovate's workflow missing `statuses: write` and pinned to a tag that does not exist. On OPNsense: aliases of the wrong type (URL instead of Host), the CloudFront resolve interval, and no rule for NTP to the firewall (README, "Outbound access needed").
