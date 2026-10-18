# ansible-prod-srv

Ansible configuration for the production homelab server: Debian 13 with rootless Docker, behind an OPNsense firewall. The design decisions behind it are in [homelab-prod](https://github.com/Gu35t09/homelab-prod).

This first version covers the server foundations. The applications (Traefik, Vaultwarden, Immich, OpenCloud, Paperless, Technitium), Renovate and the backup come next, each as its own role.

## Layout

```text
.
├── ansible.cfg
├── requirements.yml                  # ansible.posix, community.general
├── site.yml                          # the only playbook; areas are selected by tag
├── inventory/
│   ├── hosts.ini
│   └── group_vars/prod_servers/
│       ├── main.yml                  # site settings: admin user, keys, addresses, VLANs
│       ├── vault.yml                 # secrets, always encrypted (create it from the example)
│       └── vault.yml.example
├── roles/
│   ├── base/                         # packages, time, journal, unattended-upgrades, needrestart
│   ├── hardening/                    # admin user, sudo, SSH drop-in, sysctl
│   ├── network/                      # VLAN trunk, source routing, rollback (tag: network)
│   ├── firewall_host/                # nftables, inbound deny by default
│   ├── docker_rootless/              # Docker for a dedicated service user
│   ├── notify/                       # Telegram helper shared by the other roles
│   ├── clamav/                       # daemon, scheduled scan, quarantine
│   ├── monitoring/                   # SMART and disk space alerts
│   └── update_os/                    # package upgrades and reboot (tag: update-os)
└── .githooks/pre-commit              # refuses an unencrypted vault.yml
```

## Roles

| Role | What it does |
| --- | --- |
| `base` | Hostname, timezone, NTP from OPNsense, persistent journal capped at 500 MB, base packages. Unattended-upgrades installs **Debian security updates only** and never reboots; needrestart restarts the affected services. |
| `hardening` | Admin user in `sudo` with a passwordless rule, SSH keys managed exclusively (unlisted keys are removed), OpenSSH drop-in validated with `sshd -t`, kernel and network sysctl hardening. |
| `network` | Writes `/etc/network/interfaces` (ifupdown): one NIC on an 802.1Q trunk, one address per VLAN, one routing table and `ip rule` per address so replies leave from the VLAN they came in on. Applies the change with a reboot and an automatic rollback. |
| `firewall_host` | nftables: inbound denied by default; SSH only to the management address, ports 53/80/443 only to the services address; forwarding off; outbound left to OPNsense. |
| `docker_rootless` | Docker from the official repository, rootful daemon disabled, rootless daemon as a user unit of `svc-docker` (no login, no sudo). Port driver `slirp4netns`, so containers see the real client IP. |
| `notify` | `/usr/local/sbin/notify-telegram`. The token lives only in `/etc/homelab/notify.env` (root, 0600), never in the scripts or in the process list. |
| `clamav` | `clamav-daemon` and `clamav-freshclam`, a systemd timer for the scan (daily at 00:00), quarantine outside the scanned paths, Telegram report. Image layers are not scanned. |
| `monitoring` | smartd with self-tests and temperature alerts (skipped on VMs), disk space check every 15 minutes with one alert per threshold crossing. |
| `update_os` | `apt dist-upgrade`, reboot only when a newer kernel is waiting or a package asks for it, restart of the rootless daemon after a Docker upgrade. |

## Tags and Semaphore jobs

| Command | Use |
| --- | --- |
| `ansible-playbook site.yml` | Full configuration. Safe to run again: it changes nothing when the server already matches. |
| `--tags base,hardening,firewall,docker,clamav,monitoring` | One or more areas only. `security` = hardening + firewall. |
| `--tags update-os` | Scheduled Semaphore job: upgrades and reboot when needed. Never part of a full run. |
| `--tags network` | Network changes only, run by hand. Never part of a full run. |

Both `update-os` and `network` carry the `never` tag, so they run only when asked for by name.

In Semaphore, store the vault password in the Key Store and attach it to the templates. A suggested setup: one template for `site.yml` (manual) and one for `--tags update-os` (scheduled, for example weekly at night).

## First setup

### 1. Install Debian 13

Install from the netinst image with SSH server and no desktop. During the installation:

- create the admin user (the name in `admin_user`) and leave the root password empty, so the user gets sudo;
- configure a static address on the management network: this is what `ansible_host` points to.

Then copy your key once so Ansible can log in: `ssh-copy-id <admin_user>@<management IP>`.

### 2. Prepare the repository

```bash
ansible-galaxy collection install -r requirements.yml
git config core.hooksPath .githooks          # once per clone
cp inventory/group_vars/prod_servers/vault.yml.example inventory/group_vars/prod_servers/vault.yml
ansible-vault encrypt inventory/group_vars/prod_servers/vault.yml
ansible-vault edit inventory/group_vars/prod_servers/vault.yml
```

Then edit `inventory/hosts.ini` (management IP and user) and `inventory/group_vars/prod_servers/main.yml`.

### 3. Run it

```bash
ansible-playbook site.yml --ask-vault-pass
```

The first run takes a few minutes: ClamAV downloads its signature database (a few hundred MB) before the daemon can start.

### 4. Move to VLANs

When the switch trunk is ready, fill in `network_links` and run:

```bash
ansible-playbook site.yml --tags network --ask-vault-pass
```

The role keeps the current configuration aside, installs the new one and reboots. If Ansible reconnects and the new configuration is in place, it confirms it. If not, after `network_rollback_minutes` (5 by default) the server restores the previous configuration and reboots by itself, and the play fails with a message saying so.

Once the services VLAN is up, set `services_address`, and `ssh_listen_address` to the management IP, then run `--tags security`.

## Variables to know

Site-specific values are in `inventory/group_vars/prod_servers/main.yml`; every other default is in `roles/<role>/defaults/main.yml`.

| Variable | Default | Notes |
| --- | --- | --- |
| `admin_user`, `admin_ssh_keys` | — | The playbook stops if the key list is empty or `ansible_user` differs from `admin_user`. |
| `mgmt_address`, `services_address` | `ansible_host`, empty | Used by nftables. Empty means "any address". |
| `ssh_listen_address` | empty | Must equal `ansible_host` when set. |
| `network_links` | — | One entry per network; exactly one with `default_route: true`; `vlan: null` means untagged. |
| `docker_user` | `svc-docker` | Owner of the rootless daemon and of the application data. |
| `docker_rootlesskit_cidr` | empty (`10.0.2.0/24`) | Change it if any network the server talks to uses `10.0.2.0/24`, or replies to those clients get lost. |
| `clamav_scan_paths` | admin home, `/etc`, `/srv`, `/tmp`, `/var/tmp` | Application data will live under `/srv`. Missing paths are skipped. |
| `clamav_action_on_detect` | `quarantine` | Or `notify_only`, `remove`. |
| `disk_space_warn_percent` | `85` | |
| `update_os_allow_reboot` | `true` | With `false`, the job only reports that a reboot is needed. |

## Working with Docker

The admin user has no access to the Docker socket. The `docker-svc` wrapper runs the CLI as `svc-docker`:

```bash
docker-svc ps
docker-svc compose -f /srv/apps/<app>/compose.yml up -d
```

## Outbound access needed

The server reaches only the destinations allowed on OPNsense. For the roles in this repository:

| Destination | Used by |
| --- | --- |
| `deb.debian.org`, `security.debian.org` | apt, unattended-upgrades |
| `download.docker.com` | Docker packages |
| `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`, `ghcr.io`, `pkg-containers.githubusercontent.com` | image pulls |
| `database.clamav.net` | freshclam |
| `api.telegram.org` | notifications |

## Documentation

[docs/walkthrough.md](docs/walkthrough.md) explains every role task by task: what it does, why, and how to check it.

## Checks

[verify.md](verify.md) lists the commands to check each part on the server, including a ClamAV test with the EICAR file.
