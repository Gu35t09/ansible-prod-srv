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
12. [Role: update_os](#12-role-update_os)
13. [The pre-commit hook](#13-the-pre-commit-hook)
14. [Files the playbook creates on the server](#14-files-the-playbook-creates-on-the-server)
15. [Known limits and points to review](#15-known-limits-and-points-to-review)
16. [How it was tested](#16-how-it-was-tested)

---

## 1. How a run works

### site.yml

There is a single playbook, `site.yml`, with a single play that targets the `prod_servers` group.

1. **Fact gathering** (`gather_facts: true`). Ansible collects information about the server (distribution, interfaces, architecture, virtualization) into `ansible_facts`. Several roles use these facts.
2. **Pre-task "Check that the target runs Debian 13"**. It stops the play on any other system. It carries the `always` tag, so it also runs when you select other tags.
3. **Roles**, in order: `base`, `hardening`, `network`, `firewall_host`, `docker_rootless`, `clamav`, `monitoring`, `update_os`. `notify` is not in the list: it runs as a dependency of `clamav` and `monitoring` (see their `meta/main.yml`).

The order matters:

- `hardening` runs before `firewall_host`, so SSH is already restricted when the firewall comes up.
- `network` sits before `firewall_host`, so when you run them together the firewall sees the final addresses.
- `docker_rootless` needs the `acl` package that `base` installs.

### Tags

| Tag | Roles |
| --- | --- |
| `base` | base |
| `hardening`, `security` | hardening |
| `firewall`, `security` | firewall_host |
| `docker` | docker_rootless |
| `clamav` | clamav (+ notify) |
| `monitoring` | monitoring (+ notify) |
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
| `become = True`, `become_method = sudo` | Every task runs as root through sudo, unless a task says otherwise. |
| `pipelining = True` | Ansible sends modules over the SSH connection instead of copying temporary files. It is faster and avoids permission problems when becoming an unprivileged user (`svc-docker`). It requires that sudo does not demand a TTY, which is the Debian default. |

---

## 3. Inventory and variables

### inventory/hosts.ini

```ini
[prod_servers]
prod-srv ansible_host=10.0.10.10 ansible_user=mattia
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
| `services_address` | firewall_host | Address where 53/80/443 are accepted. Empty means any address. |
| `ssh_listen_address` | hardening | Address sshd binds to. Empty means all addresses. |
| `network_parent_interface`, `network_links`, `network_dns_servers` | network | Physical NIC, one entry per VLAN, DNS resolvers. |
| `telegram_bot_token`, `telegram_chat_id` | notify | Read from `vault_telegram_*` in the vault. |

### vault.yml

It holds only `vault_telegram_bot_token` and `vault_telegram_chat_id`. The pattern `telegram_bot_token: "{{ vault_telegram_bot_token }}"` is the usual Ansible convention: `main.yml` shows which secrets exist and where they are used, and the values stay encrypted.

---

## 4. Role: base

Purpose: the common foundation, meaning packages, time, logs and automatic security updates.

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

**Cap the size of the persistent journal**
Logs are kept across reboots (`Storage=persistent`) and limited to `journald_max_use` (500 MB), so they cannot fill the single disk.
Check: `journalctl --disk-usage`.

**Restrict unattended-upgrades to Debian security updates**
Writes `/etc/apt/apt.conf.d/52unattended-upgrades-local`. APT reads the files in that directory in alphabetical order, so `52` comes after Debian's `50unattended-upgrades`.

- `#clear Unattended-Upgrade::Origins-Pattern;` empties the origin list defined in `50`. Without it, the list in `52` would be *added* to Debian's defaults and normal stable updates would be installed too. This was a real bug found during testing.
- The only allowed origin is `trixie-security`.
- `Automatic-Reboot "false"`: reboots happen only through the `update-os` job, when you decide.

Check: `sudo unattended-upgrade --dry-run -d 2>&1 | grep -i 'allowed origins'`.

**Enable the daily unattended-upgrades run**
Turns on the daily list update and the unattended upgrade (APT timers `apt-daily` and `apt-daily-upgrade`).

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
- `ssh_listen_address` is set but differs from `ansible_host`, since sshd would stop listening on the address Ansible uses.

**Create the administrative user**
Creates the user (or leaves it as is), adds it to the `sudo` group with `append: true` (other groups are kept) and gives it bash as shell.

**Install the authorized SSH keys (exclusive)**
`exclusive: true` makes `~/.ssh/authorized_keys` contain **exactly** the listed keys. A key added by hand on the server is removed at the next run. This is intentional: the repository is the only source of truth for access.

**Allow the administrative user to use sudo without a password**
Writes `/etc/sudoers.d/90-admin` with `NOPASSWD: ALL` for `admin_user` only. It is passwordless because Ansible and Semaphore use sudo non-interactively and the user has no password (keys only). `validate: visudo -cf %s` checks the syntax before installing the file: a broken sudoers file would make sudo unusable.

**Configure the OpenSSH hardening drop-in**
Template `templates/sshd_hardening.conf.j2` → `/etc/ssh/sshd_config.d/00-hardening.conf`. In sshd **the first occurrence of each directive wins**, and Debian 13 includes `sshd_config.d/*.conf` at the top of `sshd_config`, so this drop-in beats every later line. `validate: sshd -t -f %s` tests it before it is written.

| Directive | Why |
| --- | --- |
| `Port` | Configurable SSH port (22 by default). |
| `ListenAddress` | Only if `ssh_listen_address` is set: SSH on the management IP only. |
| `PermitRootLogin no` | Nobody logs in as root directly. |
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
6. Service ports (`firewall_service_ports`): TCP 53/80/443 and UDP 53, on `services_address` if set, otherwise on any address.
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

**Let unprivileged processes bind ports from 53**
`net.ipv4.ip_unprivileged_port_start=53`. By default only root can bind ports below 1024; this lets `svc-docker` publish 53, 80 and 443. Side effect: any local user can bind those ports. That is acceptable here because only the admin and the service user exist.

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
- `DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=slirp4netns`: how ports are published. The default `builtin` driver is faster but replaces the client's IP with an internal one; `slirp4netns` keeps it. Traefik (logs, rate limits) and Technitium (per-client rules) need the real IP.
- `DOCKERD_ROOTLESS_ROOTLESSKIT_FLAGS=--cidr=...`: only if `docker_rootlesskit_cidr` is set. rootlesskit uses `10.0.2.0/24` internally: if a network the server talks to uses the same range, replies to those clients stay inside the namespace and never leave. This was found during testing (the test VM used that same range).
- `Delegate=yes`: lets the daemon manage its containers' cgroups.
- `Restart=always`: restarts the daemon if it crashes.

**Enable and start the rootless daemon**
`systemctl --user enable --now docker` run **as `svc-docker`** (`become_user`). `XDG_RUNTIME_DIR` tells `systemctl --user` where that user's instance lives.

**Install the docker-svc wrapper for the admin user**
`/usr/local/bin/docker-svc` runs `docker` as `svc-docker` with the right socket. The admin has no direct access to the socket; the wrapper goes through sudo, so every use is recorded in the journal.

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
`/etc/homelab/` (0700) and `notify.env` (0600, root): the only file on the server containing the token. `no_log: true` keeps the token out of Ansible's output and out of Semaphore's logs. Values go through `| quote`, so special characters cannot break the file when the shell sources it.

**Install the notification helper**
`/usr/local/sbin/notify-telegram` (0750, root). Accepts the message as an argument or on stdin.

- Exit codes: `0` sent (or notifications disabled), `1` Telegram refused or did not answer, `2` credentials missing.
- Plain text, no `parse_mode`: file names with `_` or backticks cannot make Telegram reject the message.
- The URL containing the token goes to curl **on stdin** (`-K -`) rather than as an argument: arguments are visible to every user in `ps`, stdin is not.
- `--max-time 20`: a slow network cannot block the calling script for long.
- The message is cut at 4000 characters (Telegram's limit is 4096).

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
3. Skips paths that do not exist yet, with a warning in the log. `/srv` will be empty until the first application.
4. Uses `clamdscan --multiscan --fdpass` if the daemon is active. `--fdpass` makes the script, running as root, open the files and pass the descriptors to clamd, which runs as the `clamav` user and could not read files owned by others. Otherwise it falls back to `clamscan --recursive`, which is slower.
5. Adds `--move=<quarantine>` or `--remove=yes` depending on `clamav_action_on_detect`.
6. Reads ClamAV's exit code: `1` = threats (sends a message with up to 20 files), `>1` = error, `0` = clean (sends a summary if `clamav_notify_clean` is on).
7. A failed notification is written to the log; it does not change the scan result.

Scanned paths: admin home, `/etc`, `/srv`, `/tmp`, `/var/tmp`. Image layers (`~svc-docker/.local/share/docker`) are left out on purpose: they are public software, re-scanning them every night is expensive, and Trivy is the right tool for them. Application data will be bind-mounted under `/srv`.

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

## 12. Role: update_os

Purpose: the Semaphore job that keeps the system up to date. It runs only with `--tags update-os`.

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

**Decide whether to reboot** / **Report a pending reboot that is not allowed** / **Reboot the server**
Reboots if either signal says so and `update_os_allow_reboot` is true. Otherwise it prints a message and changes nothing.

**Look up the Docker service user** / **Restart the rootless Docker daemon after a Docker upgrade**
If `docker-ce` changed and there was no reboot, it restarts the rootless daemon: the new binary takes effect only on restart. Containers come back through their restart policy. It is skipped if the user does not exist (Docker not yet configured).

**Check that the rootless Docker daemon is running**
After an upgrade or a reboot, waits until the user `docker.service` is active again. If it fails, the Semaphore job fails and you can see it.

Container images are **not** updated here: they will follow the `update-containers` tag, with the versions pinned in the repository and Renovate.

---

## 13. The pre-commit hook

`.githooks/pre-commit` runs before every commit, once enabled with `git config core.hooksPath .githooks` (one time per clone). For every staged file named `vault.yml` or `vault.yaml`, it reads the **staged** version (`git show :<file>`) and refuses the commit if its first line does not start with `$ANSIBLE_VAULT;`. It reads the staged version, not the working copy, because that is what would end up in the history.

---

## 14. Files the playbook creates on the server

| Path | Role | Content |
| --- | --- | --- |
| `/etc/systemd/timesyncd.conf.d/10-local.conf` | base | NTP servers |
| `/etc/systemd/journald.conf.d/10-size.conf` | base | Journal size |
| `/etc/apt/apt.conf.d/52unattended-upgrades-local` | base | Security origins only |
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
| `/etc/sysctl.d/60-rootless-docker.conf` | docker_rootless | Unprivileged ports from 53 |
| `~svc-docker/.config/docker/daemon.json` | docker_rootless | Container log limits |
| `~svc-docker/.config/systemd/user/docker.service` | docker_rootless | Rootless daemon |
| `/usr/local/bin/docker-svc` | docker_rootless | Wrapper for the admin |
| `/etc/homelab/notify.env` | notify | Telegram token (0600) |
| `/usr/local/sbin/notify-telegram` | notify | Notification helper |
| `/usr/local/sbin/clamav-scan`, `/etc/systemd/system/clamav-scan.{service,timer}` | clamav | Scheduled scan |
| `/root/clamav-quarantine/` | clamav | Quarantine |
| `/etc/smartd.conf`, `/etc/smartmontools/run.d/20telegram` | monitoring | SMART (physical hosts only) |
| `/usr/local/sbin/disk-space-check`, `/etc/systemd/system/disk-space-check.{service,timer}` | monitoring | Disk space |

Each file begins with a "Managed by Ansible" comment: changes made by hand are overwritten at the next run.

---

## 15. Known limits and points to review

- **IPv6 is not configured.** nftables accepts ICMPv6, but SSH and service rules are IPv4 (`ip daddr`). With IPv6 on the VLANs, SSH and services would be reachable only over IPv4. That is fine as long as IPv6 is off on OPNsense for those networks.
- **`AllowTcpForwarding no`** disables SSH tunnels. To reach a service from outside, use WireGuard.
- **`ip_unprivileged_port_start=53`** applies to every user, not just `svc-docker`.
- **`kernel.unprivileged_bpf_disabled=1`** cannot be undone without a reboot.
- **The admin's sudo is passwordless**: whoever has the admin's SSH key, or Semaphore's, is root. Protect both keys accordingly (see the open point on Semaphore in the project document).
- **The network role reboots** whenever the configuration changes. Run it in a maintenance window.
- **`/etc/resolv.conf`** is written only by the network role. Before you run it, the server keeps the DNS servers set by the installer.
- **The Docker key checksum** is pinned. If Docker ever rotates its key, the task fails on purpose: check the new fingerprint on docs.docker.com, then update `docker_apt_key_checksum`.
- **ClamAV uses 1–1.5 GB of RAM** for clamd. On an OptiPlex 3050 with 8 GB that is noticeable once Immich is running.

---

## 16. How it was tested

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
| ansible-lint (production profile), yamllint, shellcheck | No findings |

Bugs found and fixed during these tests: `ansible_managed` undefined in `copy` tasks on ansible-core 2.20; clamd start skipped on the first run; unattended-upgrades not limited to security updates; the rootlesskit network colliding with `10.0.2.0/24`; the network rollback reported as a success.
