# ansible-prod-srv

Ansible configuration for the production homelab server: Debian 13 with rootless Docker, behind an OPNsense firewall. The design decisions behind it are in [homelab-prod](https://github.com/Gu35t09/homelab-prod).

It covers the server foundations, detection (ClamAV, integrity check, YARA) and the backup (restic to a USB disk and S3). The applications (Traefik, Vaultwarden, Immich, OpenCloud, Paperless, Technitium) and Renovate come next, each as its own role.

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
│   ├── traefik/                      # reverse proxy, Let's Encrypt wildcard (tags: traefik, update-containers)
│   ├── notify/                       # Telegram helper shared by the other roles
│   ├── clamav/                       # daemon, scheduled scan, quarantine
│   ├── monitoring/                   # SMART and disk space alerts
│   ├── integrity/                    # NTP, sshd logging, unpackaged libraries, Ebury
│   ├── yara/                         # YARA rules and nightly scan
│   ├── backup/                       # restic to a USB disk and an S3 bucket
│   └── update_os/                    # package upgrades and reboot (tag: update-os)
├── scripts/update-yara-rules.sh      # refreshes the vendored YARA rules
└── .githooks/pre-commit              # refuses an unencrypted vault.yml
```

## Roles

| Role | What it does |
| --- | --- |
| `base` | Hostname, timezone, NTP from OPNsense (timesyncd always on), persistent journal capped at 500 MB, base packages. Unattended-upgrades installs **Debian security updates only** and never reboots; needrestart restarts the affected services. |
| `hardening` | Admin user in `sudo` with a passwordless rule, SSH keys managed exclusively (unlisted keys are removed), OpenSSH drop-in validated with `sshd -t` (`LogLevel VERBOSE`, so every login and its key are logged), kernel and network sysctl hardening. |
| `network` | Writes `/etc/network/interfaces` (ifupdown): one NIC on an 802.1Q trunk, one address per VLAN, one routing table and `ip rule` per address so replies leave from the VLAN they came in on. Applies the change with a reboot and an automatic rollback. |
| `firewall_host` | nftables: inbound denied by default; SSH only to the management address, ports 53/80/443 only to the services address; forwarding off; outbound left to OPNsense. |
| `docker_rootless` | Docker from the official repository, rootful daemon disabled, rootless daemon as a user unit of `svc-docker` (no login, no sudo). Port driver `slirp4netns`, so containers see the real client IP. |
| `traefik` | Traefik in `/srv/docker/system/traefik`, image pinned by tag and digest. Ports 80/443 on the services address only, HTTP redirected to HTTPS, one Let's Encrypt wildcard certificate for the domain (Cloudflare DNS challenge), dashboard on `proxy.<domain>` behind a password. Routes come only from files in `dynamic/`, one per service: Traefik has no access to the Docker socket. Read-only container, no capabilities except binding ports. |
| `notify` | `/usr/local/sbin/notify-telegram`. The token lives only in `/etc/homelab/notify.env` (root, 0600), never in the scripts or in the process list. |
| `clamav` | `clamav-daemon` and `clamav-freshclam`, a systemd timer for the scan (daily at 00:00), quarantine outside the scanned paths, Telegram report. Image layers are not scanned. |
| `monitoring` | smartd with self-tests and temperature alerts (skipped on VMs), disk space check every 15 minutes with one alert per threshold crossing. |
| `integrity` | Every 15 minutes: NTP on and synchronized, sshd logging at INFO or above, no setuid/setgid or ownerless files and no shared object outside the packages in the library directories (how Ebury 1.8.3 hides), no `/etc/ld.so.preload`, nothing but sshd in `ssh.service`, no Ebury socket. Telegram alert when the findings change, repeated daily while they last. |
| `backup` | restic, daily at 02:30, to two encrypted repositories: an external USB disk (found by its label, mounted only during the backup) and an S3 bucket. Backs up `/srv` and `/etc` after the applications' dump scripts in `/etc/backup/pre.d/`. Keeps 7 daily, 4 weekly, 12 monthly snapshots; prune and `restic check` on Sundays. One Telegram message per run with the result of each copy. |
| `yara` | YARA with rules vendored in the repository (ESET for Ebury and the OpenSSH backdoors, Elastic for Linux rootkits, miners, botnets, C2 implants, webshells). Nightly scan at 01:00 of binaries, libraries, configuration, temporary directories, application data and container layers, plus the memory of the sshd processes. Reports only; nothing is moved. |
| `update_os` | `apt dist-upgrade`, reboot only when a newer kernel is waiting or a package asks for it, restart of the rootless daemon after a Docker upgrade. |

## Tags and Semaphore jobs

| Command | Use |
| --- | --- |
| `ansible-playbook site.yml` | Full configuration. Safe to run again: it changes nothing when the server already matches. |
| `--tags base,hardening,firewall,docker,traefik,clamav,monitoring,integrity,yara,backup` | One or more areas only. `security` = hardening + firewall. |
| `--tags update-containers` | Every container service, at the versions pinned in the repository: after merging an image update. |
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

For Traefik you need, before the first run:

- **A Cloudflare API token** limited to the zone, with *Zone → Zone → Read* and *Zone → DNS → Edit*, in the vault as `vault_cloudflare_dns_api_token`.
- **The dashboard password**, as a bcrypt htpasswd line in `vault_traefik_dashboard_users`:
  ```bash
  podman run --rm docker.io/library/httpd:2.4 htpasswd -nbB admin '<password>'
  ```
- **Internal DNS names** pointing to the services address (`proxy.greyroom.net` for the dashboard, then one per service), as host overrides in Unbound on OPNsense until Technitium is in place.
- `api.cloudflare.com` and `acme-v02.api.letsencrypt.org` allowed on OPNsense.

For the backup you need, before the first run:

- **The restic password** in the vault (`vault_restic_password`, e.g. `openssl rand -base64 33`). Write it on the emergency sheet as well: without it no backup can be read.
- **An S3 bucket** and a key limited to it (`vault_backup_s3_access_key`, `vault_backup_s3_secret_key`), with `backup_s3_endpoint` and `backup_s3_bucket` in `main.yml`. Turn on **object lock or versioning** on the bucket (for example 30 days): the server holds a key that can delete, so this is what keeps a compromised server from erasing the history. Allow the endpoint on OPNsense.
- **The USB disk**, formatted once with the label the server looks for. This erases the disk:
  ```bash
  lsblk                                   # find the disk, e.g. /dev/sdb
  sudo wipefs -a /dev/sdX
  sudo mkfs.ext4 -L backup-usb /dev/sdX
  ```
  Leave it plugged in: the backup mounts it at `/mnt/backup-usb` only while it runs. If the disk is missing at the first run, connect it later and run `sudo backup --init`.

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
| `clamav_scan_paths` | admin home, `/etc`, `/srv`, `/tmp`, `/var/tmp` | Container data lives under `/srv/docker`. Missing paths are skipped. |
| `clamav_action_on_detect` | `quarantine` | Or `notify_only`, `remove`. |
| `disk_space_warn_percent` | `85` | |
| `update_os_allow_reboot` | `true` | With `false`, the job only reports that a reboot is needed. |
| `ssh_log_level` | `VERBOSE` | `INFO` or `VERBOSE`; the playbook refuses anything lower. |
| `integrity_lib_allowlist` | empty | Shell patterns of shared objects allowed outside the packages. Keep it empty unless you install a library by hand. |
| `traefik_domain` | — | Wildcard certificate for `<domain>` and `*.<domain>`; the dashboard is `proxy.<domain>`. |
| `traefik_networks` | empty | One name per service behind Traefik: the role creates the internal network `proxy-<name>` and attaches Traefik to it. |
| `traefik_acme_ca_server` | Let's Encrypt production | For tests, the staging CA avoids the rate limits (`https://acme-staging-v02.api.letsencrypt.org/directory`); browsers will not trust its certificate. |
| `backup_s3_endpoint`, `backup_s3_bucket` | empty | Endpoint without `https://` (e.g. `s3.eu-central-003.backblazeb2.com`). The repository is `<bucket>/<host name>`. |
| `backup_usb_label` | `backup-usb` | Filesystem label of the USB disk. |
| `backup_paths`, `backup_exclude` | `/srv`, `/etc`; none | Containers keep compose file, data and dumps under `/srv/docker/{system,app}/<name>/`. |
| `yara_scan_paths`, `yara_exclude_paths` | see `roles/yara/defaults/main.yml` | `/etc/yara` (the rules) and the ClamAV quarantine are always left out. |

## Working with Docker

Every container service has its own directory, with its compose file, its data and, if it has a database, its dumps:

```text
/srv/docker/
├── system/        # infrastructure: traefik, technitium, renovate
│   └── <name>/
└── app/           # applications: vaultwarden, immich, opencloud, paperless
    └── <name>/
```

The admin user has no access to the Docker socket. The `docker-svc` wrapper runs the CLI as `svc-docker`:

```bash
docker-svc ps
docker-svc compose -f /srv/docker/app/<name>/compose.yml restart
```

Each service behind Traefik has its own internal network, `proxy-<name>`, shared only with Traefik: services cannot reach each other. The full guide, with what to do by hand and what to change through Ansible, is [docs/containers.md](docs/containers.md).

## Outbound access needed

The server reaches only the destinations allowed on OPNsense. For the roles in this repository:

| Destination | Used by |
| --- | --- |
| `deb.debian.org`, `security.debian.org` | apt, unattended-upgrades |
| `download.docker.com` | Docker packages |
| `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`, `ghcr.io`, `pkg-containers.githubusercontent.com` | image pulls |
| `database.clamav.net` | freshclam |
| `api.telegram.org` | notifications |
| `api.cloudflare.com`, `acme-v02.api.letsencrypt.org` | Traefik certificates (DNS challenge) |
| the S3 endpoint (`backup_s3_endpoint`) | backup |

The YARA rules need no outbound access: they are copied from the repository. Refresh them on the laptop with `scripts/update-yara-rules.sh` (see the maintenance guide).

## Documentation

[docs/walkthrough.md](docs/walkthrough.md) explains every role task by task: what it does, why, and how to check it.

[docs/containers.md](docs/containers.md) explains how to operate the containers with `docker-svc`.

[docs/maintenance.md](docs/maintenance.md) is the maintenance guide: calendar, what to do for each notification, routine procedures, troubleshooting and recovery.

## Checks

[verify.md](verify.md) lists the commands to check each part on the server, including a ClamAV test with the EICAR file.
