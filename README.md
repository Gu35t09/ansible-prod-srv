# ansible-prod-srv

Ansible configuration for the production homelab server: Debian 13 with rootless Docker, behind an OPNsense firewall. The design decisions behind it are in [homelab-prod](https://github.com/Gu35t09/homelab-prod).

It covers the server foundations, detection (ClamAV, integrity check, YARA) and the backup (restic to a USB disk and S3). Traefik, Vaultwarden, Immich and OpenCloud are in place, with Renovate proposing image updates; Paperless comes next, each as its own role. DNS stays on Unbound (OPNsense).

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
├── roles/                            # in the order site.yml runs them
│   ├── base/                         # packages, time, journal, unattended-upgrades and its Telegram report
│   ├── hardening/                    # admin user, sudo, SSH drop-in, sysctl
│   ├── network/                      # VLAN trunk, source routing, rollback (tag: network)
│   ├── firewall_host/                # nftables, inbound deny by default
│   ├── docker_rootless/              # Docker for a dedicated service user
│   ├── clamav/                       # daemon, scheduled scan, quarantine
│   ├── monitoring/                   # SMART and disk space alerts
│   ├── integrity/                    # NTP, sshd logging, unpackaged libraries, Ebury
│   ├── yara/                         # YARA rules and nightly scan
│   ├── backup/                       # restic to a USB disk and an S3 bucket
│   ├── traefik/                      # reverse proxy, Let's Encrypt wildcard (tags: traefik, update-containers)
│   ├── vaultwarden/                  # password manager, SQLite (tags: vaultwarden, update-containers)
│   ├── immich/                       # photos, without machine learning (tags: immich, update-containers)
│   ├── opencloud/                    # file sync and share, replaces Nextcloud (tags: opencloud, update-containers)
│   ├── update_os/                    # package upgrades, reboot or report (tag: update-os)
│   └── notify/                       # Telegram helper, a dependency of the roles that send messages
├── renovate.json                     # which image versions Renovate watches
├── .github/workflows/renovate.yml    # runs Renovate every Saturday, Telegram summary
├── .github/renovate-image            # the Renovate image the workflow runs
├── scripts/update-yara-rules.sh      # refreshes the vendored YARA rules
└── .githooks/pre-commit              # refuses an unencrypted vault.yml
```

## Roles

| Role | What it does |
| --- | --- |
| `base` | Hostname, timezone, NTP from OPNsense (timesyncd always on), persistent journal capped at 500 MB, base packages. Unattended-upgrades installs **Debian security updates only** and never reboots; needrestart restarts the affected services. A Telegram message after every unattended-upgrades run (upgraded, nothing to install, errors, reboot needed), and when the package lists fail to download. |
| `hardening` | Admin user in `sudo` with a passwordless rule, SSH keys managed exclusively (unlisted keys are removed), OpenSSH drop-in validated with `sshd -t` (`LogLevel VERBOSE`, so every login and its key are logged), kernel and network sysctl hardening. |
| `network` | Writes `/etc/network/interfaces` (ifupdown): one NIC on an 802.1Q trunk, one address per VLAN, one routing table and `ip rule` per address so replies leave from the VLAN they came in on. Applies the change with a reboot and an automatic rollback. |
| `firewall_host` | nftables: inbound denied by default; SSH only to the management address, ports 80/443 only to the services address; forwarding off; outbound left to OPNsense. |
| `docker_rootless` | Docker from the official repository, rootful daemon disabled, rootless daemon as a user unit of `svc-docker` (no login, no sudo). Port driver `slirp4netns`, so containers see the real client IP. |
| `clamav` | `clamav-daemon` and `clamav-freshclam`, a systemd timer for the scan (daily at 00:00), quarantine outside the scanned paths, Telegram report. Image layers are not scanned. |
| `monitoring` | smartd with self-tests and temperature alerts (skipped on VMs), disk space check every 15 minutes with one alert per threshold crossing. |
| `integrity` | Every 15 minutes: NTP on and synchronized, sshd logging at INFO or above, no setuid/setgid or ownerless files and no shared object outside the packages in the library directories (how Ebury 1.8.3 hides), no `/etc/ld.so.preload`, nothing but sshd in `ssh.service`, no Ebury socket. Telegram alert when the findings change, repeated daily while they last. |
| `yara` | YARA with rules vendored in the repository (ESET for Ebury and the OpenSSH backdoors, Elastic for Linux rootkits, miners, botnets, C2 implants, webshells). Nightly scan at 01:00 of binaries, libraries, configuration, temporary directories, application data and container layers, plus the memory of the sshd processes. Reports only; nothing is moved. |
| `backup` | restic, daily at 02:30, to two encrypted repositories: an external USB disk (found by its label, mounted only during the backup) and an S3 bucket. Backs up `/srv` and `/etc` after the applications' dump scripts in `/etc/backup/pre.d/`. Keeps 7 daily, 4 weekly, 12 monthly snapshots; prune and `restic check` on Sundays. One Telegram message per run with the result of each copy. |
| `traefik` | Traefik in `/srv/docker/system/traefik`, image pinned by tag and digest. Ports 80/443 on the services address only, HTTP redirected to HTTPS, one Let's Encrypt wildcard certificate for the domain (Cloudflare DNS challenge), dashboard on `proxy.<domain>` behind a password. Routes come only from files in `dynamic/`, one per service: Traefik has no access to the Docker socket. Read-only container, no capabilities except binding ports. |
| `vaultwarden` | Vaultwarden in `/srv/docker/app/vaultwarden` with SQLite, image pinned by tag and digest, on `vault.<domain>`. Only on its internal network with Traefik: no published ports, no Internet access (so no favicon downloads). Sign-ups off, admin page disabled, password hints off. Read-only container with no capabilities. A dump script for the backup copies the database with SQLite's online backup and checks it. |
| `immich` | Immich in `/srv/docker/app/immich` on `photo.<domain>`: server, Postgres and Valkey, images pinned by tag and digest; **no machine learning** container. Only the server is on Traefik's network; the database and Valkey share an internal network with it. No container has Internet access. Read-only server with no capabilities; Postgres and Valkey keep only what their entrypoints need. A dump script for the backup runs `pg_dumpall` and checks the result; the live database directory is left out of the backup. |
| `opencloud` | OpenCloud (production release line) in `/srv/docker/app/opencloud` on `cloud.<domain>`, image pinned by tag and digest, built-in user directory, PosixFS storage (files on disk as the user sees them, no database). Only on its internal network with Traefik, where Traefik also answers to `cloud.<domain>` so the login checks need no Internet access. Read-only container with no capabilities. Stopped during the nightly backup for a consistent copy, started again after it. No Collabora. |
| `update_os` | `apt dist-upgrade`; when a newer kernel is waiting or a package asks for a reboot, reboot (if allowed) or report it on Telegram; restart of the rootless daemon after a Docker upgrade. |
| `notify` | `/usr/local/sbin/notify-telegram`. The token lives only in `/etc/homelab/notify.env` (root, 0600), never in the scripts or in the process list. |

## Tags and Semaphore jobs

| Command | Use |
| --- | --- |
| `ansible-playbook site.yml` | Full configuration. Safe to run again: it changes nothing when the server already matches. |
| `--tags base,hardening,firewall,docker,traefik,vaultwarden,immich,opencloud,clamav,monitoring,integrity,yara,backup` | One or more areas only. `security` = hardening + firewall. |
| `--tags update-containers` | Every container service, at the versions pinned in the repository: after merging an image update. |
| `--tags update-os` | Scheduled Semaphore job: upgrades; reports on Telegram when a reboot is needed (no automatic reboot on prod-srv-01). Never part of a full run. |
| `--tags network` | Network changes only, run by hand. Never part of a full run. |

Both `update-os` and `network` carry the `never` tag, so they run only when asked for by name.

In Semaphore, store the vault password in the Key Store and attach it to the templates. A suggested setup: one template for `site.yml` (manual) and one for `--tags update-os` (scheduled, for example weekly at night).

## First setup

### 1. Install Debian 13

Install from the netinst image with SSH server and no desktop. During the installation:

- create the admin user (the name in `admin_user`) and leave the root password empty, so the user gets sudo;
- configure a static address on the management network: this is what `ansible_host` points to;
- prod-srv-01 uses guided partitioning with **encrypted LVM** (LUKS). The passphrase is then typed at the console at every boot: nothing reboots the server by itself (`update_os_allow_reboot: false`), and the network change below needs someone at the machine.

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
- **Internal DNS names** pointing to the services address (`proxy.greyroom.net` for the dashboard, then one per service), as host overrides in Unbound on OPNsense.
- `api.cloudflare.com` and `acme-v02.api.letsencrypt.org` allowed on OPNsense.

For Vaultwarden you need `vaultwarden` in `traefik_networks` (run `--tags traefik` once after adding it) and a host override `vault.greyroom.net` → services address in Unbound. No secret: the admin page stays disabled. To create the first account:

1. Set `vaultwarden_signups_allowed: true` in `main.yml` and run `--tags vaultwarden`.
2. Register at `https://vault.greyroom.net` (through WireGuard or from the LAN).
3. Set it back to `false` and run `--tags vaultwarden` again. Family members can then be invited from an organization in the web vault: invited addresses can register even with sign-ups off.

Vaultwarden sends no e-mail (no SMTP, egress is blocked): there is no password reset by mail, so the master password must be on the emergency sheet.

For Immich you need `immich` in `traefik_networks` (run `--tags traefik` once after adding it), a host override `photo.greyroom.net` → services address in Unbound, and `vault_immich_db_password` in the vault (letters and digits only: `openssl rand -hex 24`). After the first run:

1. Open `https://photo.greyroom.net` and create the admin account (the first account becomes admin).
2. *Administration → Settings → Machine Learning Settings*: turn off **Enable machine learning**. There is no machine learning container, so otherwise every upload logs errors.
3. *Administration → Settings → Version Check*: turn it off (the server has no Internet access; Renovate reports new versions).

For OpenCloud you need `opencloud` in `traefik_networks` and in `traefik_network_aliases` (`opencloud: ["cloud.{{ traefik_domain }}"]`, already in `main.yml`; run `--tags traefik` once after adding them), a host override `cloud.greyroom.net` → services address in Unbound, and `vault_opencloud_admin_password` in the vault (`openssl rand -base64 24`). After the first run, log in at `https://cloud.greyroom.net` as `admin`, create the users under *Admin settings → Users*, and log in once as each user so that OpenCloud creates their personal space. Clients: the OpenCloud desktop and mobile apps. Moving from Nextcloud: maintenance guide, "Migrate the files from Nextcloud".

For the backup you need, before the first run:

- **The restic password** in the vault (`vault_restic_password`, e.g. `openssl rand -base64 33`). Write it on the emergency sheet as well: without it no backup can be read.
- **An S3 bucket** and a key limited to it (`vault_backup_s3_access_key`, `vault_backup_s3_secret_key`), with `backup_s3_endpoint` and `backup_s3_bucket` in `main.yml`. The server holds a key that can delete, so **lock the bucket against deletion** at the provider: that is what keeps a compromised server from erasing the history. With `backup_s3_append_only: true` restic never deletes from the bucket (no `forget`, no `prune`; the weekly `check` still runs). On Cloudflare R2, *bucket → Settings → Bucket lock rules → Add rule*, four rules with the retention **Age, 90 days**, prefixes:
  - `prod-srv-01/data/` (the data), `prod-srv-01/snapshots/` (one file per backup), `prod-srv-01/keys/` (the encrypted master key: without it nothing can be read), `prod-srv-01/config`;
  - not `prod-srv-01/locks/` (restic writes and deletes a lock file at every run) nor `prod-srv-01/index/` (restic can rebuild it from the data with `repair index`).

  Turn `backup_s3_append_only` on and run `--tags backup` **before** adding the rules, or the nightly `forget` fails on locked snapshots. Allow the endpoint on OPNsense.
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

The role keeps the current configuration aside, installs the new one and reboots: with the encrypted disk, be at the console to type the passphrase. If Ansible reconnects and the new configuration is in place, it confirms it. If not, after `network_rollback_minutes` (5 by default) the server restores the previous configuration and reboots by itself (the passphrase again), and the play fails with a message saying so.

Once the services VLAN is up, set `services_address`, and `ssh_listen_address` to the management IP, then run `--tags security`.

## Variables to know

Site-specific values are in `inventory/group_vars/prod_servers/main.yml`; every other default is in `roles/<role>/defaults/main.yml`.

| Variable | Default | Notes |
| --- | --- | --- |
| `admin_user`, `admin_ssh_keys` | — | The playbook stops if the key list is empty or `ansible_user` differs from `admin_user`. |
| `ntp_servers`, `network_dns_servers` | — | OPNsense: egress to the Internet is blocked, so time and DNS come from the firewall. |
| `mgmt_address`, `services_address` | `ansible_host`, empty | Used by nftables. Empty means "any address". |
| `ssh_listen_address` | empty | Must equal `ansible_host` when set. |
| `ssh_log_level` | `VERBOSE` | `INFO` or `VERBOSE`; the playbook refuses anything lower. |
| `network_links` | — | One entry per network; exactly one with `default_route: true`; `vlan: null` means untagged. |
| `docker_user` | `svc-docker` | Owner of the rootless daemon and of the application data. |
| `docker_rootlesskit_cidr` | empty (`10.0.2.0/24`) | Change it if any network the server talks to uses `10.0.2.0/24`, or replies to those clients get lost. |
| `clamav_scan_paths` | admin home, `/etc`, `/srv`, `/tmp`, `/var/tmp` | Container data lives under `/srv/docker`. Missing paths are skipped. |
| `clamav_action_on_detect` | `quarantine` | Or `notify_only`, `remove`. |
| `disk_space_warn_percent` | `85` | |
| `integrity_lib_allowlist` | empty | Shell patterns of shared objects allowed outside the packages. Keep it empty unless you install a library by hand. |
| `yara_scan_paths`, `yara_exclude_paths` | see `roles/yara/defaults/main.yml` | `/etc/yara` (the rules) and the ClamAV quarantine are always left out. |
| `backup_paths` | `/srv`, `/etc` | Containers keep compose file, data and dumps under `/srv/docker/{system,app}/<name>/`. |
| `backup_exclude` | none; in `main.yml`: `/srv/docker/app/immich/postgres` | Live database directories: their dump scripts save them instead. |
| `backup_s3_endpoint`, `backup_s3_bucket` | empty | Endpoint without `https://` (e.g. `s3.eu-central-003.backblazeb2.com`). The repository is `<bucket>/<host name>`. |
| `backup_s3_append_only` | `false`; in `main.yml`: `true` | Never delete from the S3 copy (no `forget`, no `prune`): for a bucket locked against deletion. |
| `backup_usb_label` | `backup-usb` | Filesystem label of the USB disk. |
| `traefik_domain` | — | Wildcard certificate for `<domain>` and `*.<domain>`; the dashboard is `proxy.<domain>`. |
| `traefik_networks` | empty | One name per service behind Traefik: the role creates the internal network `proxy-<name>` and attaches Traefik to it. |
| `traefik_acme_ca_server` | Let's Encrypt production | For tests, the staging CA avoids the rate limits (`https://acme-staging-v02.api.letsencrypt.org/directory`); browsers will not trust its certificate. |
| `vaultwarden_signups_allowed` | `false` | Turn on only to create an account (see "First setup"). |
| `traefik_network_aliases` | empty; in `main.yml`: `opencloud: [cloud.<domain>]` | Host names Traefik answers to on a service's own network, for a service that calls its own public URL. |
| `opencloud_admin_password` | — | From the vault (`vault_opencloud_admin_password`). Used only at the first start. |
| `immich_db_password` | — | From the vault (`vault_immich_db_password`). Used only when the database is created: changing it later does not change the database password. |
| `update_os_allow_reboot` | `true`; in `main.yml`: `false` | With `false`, the job only reports that a reboot is needed, in its output and on Telegram. False on prod-srv-01: the disk is encrypted and its passphrase is typed at the console. |

## Working with Docker

Every container service has its own directory, with its compose file, its data and, if it has a database, its dumps:

```text
/srv/docker/
├── system/        # infrastructure: traefik
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

## Image updates (Renovate)

Renovate runs every Saturday morning on a GitHub runner (`.github/workflows/renovate.yml`), not on the server, with no third-party action: the workflow starts the Renovate container itself. It reads the images pinned in `roles/*/defaults/main.yml` and opens one PR per update, with the release notes; a Telegram message lists the new PRs and the updates to do by hand, or reports a run that did not finish. Nothing is merged automatically. After merging a PR, apply it:

```bash
ansible-playbook site.yml --tags update-containers --ask-vault-pass
```

Setup, once, in the GitHub repository settings:

1. *Settings → Actions → General → Actions permissions*: **Allow Gu35t09 actions and reusable workflows** (the workflow uses no external action).
1. *Settings → Actions → General → Workflow permissions*: **Read repository contents and packages permissions** as the default, and tick **Allow GitHub Actions to create and approve pull requests**. Renovate uses the job's own `GITHUB_TOKEN`, so no personal token is needed.
1. *Settings → Rules → Rulesets → New branch ruleset*, so that only you can change `main` (merges included): name `protect main`, enforcement **Active**, bypass list **Repository admin**, target **default branch**, rules **Restrict updates**, **Restrict deletions**, **Block force pushes**. The workflow token can push branches (`contents: write`), which would technically be enough to merge; with this ruleset GitHub refuses it. When you merge, tick "Merge without waiting for requirements to be met (bypass rules)".
1. *Settings → Secrets and variables → Actions*: add `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` (the same values as in the vault). Without them the run works but sends nothing.
1. *Actions → Renovate → Run workflow* to try it without waiting for Saturday.

## Outbound access needed

The server reaches only the destinations allowed on OPNsense. For the roles in this repository:

| Destination | Used by |
| --- | --- |
| `deb.debian.org`, `security.debian.org` | apt, unattended-upgrades |
| `download.docker.com` | Docker packages |
| `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`, `production.cloudfront.docker.com`, `ghcr.io`, `pkg-containers.githubusercontent.com` | image pulls |
| `database.clamav.net` | freshclam |
| `api.telegram.org` | notifications |
| `api.cloudflare.com`, `acme-v02.api.letsencrypt.org` | Traefik certificates (DNS challenge) |
| the S3 endpoint (`backup_s3_endpoint`) | backup |

On OPNsense, the server's VLANs also need **DNS (53) and NTP (123) to the firewall itself**: the server resolves names through Unbound and takes the time from OPNsense. Without the NTP rule the integrity check reports an unsynchronized clock.

Use aliases of type **Host(s)**, one host name per line (not "URL (IPs)", which downloads IP lists from web pages). CDNs such as CloudFront change addresses every minute: set *Firewall → Settings → Advanced → Aliases Resolve Interval* to 30 seconds, or pulls fail now and then when the server gets an address the alias does not have yet.

The YARA rules need no outbound access: they are copied from the repository. Refresh them on the laptop with `scripts/update-yara-rules.sh` (see the maintenance guide).

## Documentation

[docs/walkthrough.md](docs/walkthrough.md) explains every role task by task: what it does, why, and how to check it.

[docs/containers.md](docs/containers.md) explains how to operate the containers with `docker-svc`.

[docs/maintenance.md](docs/maintenance.md) is the maintenance guide: calendar, what to do for each notification, routine procedures, troubleshooting and recovery.

## Checks

[verify.md](verify.md) lists the commands to check each part on the server, including a ClamAV test with the EICAR file.
