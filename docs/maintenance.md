# Maintenance guide

How to keep the production server healthy: what runs by itself, what to do by hand and when, how to react to each notification, and how to recover when something breaks.

For what each task does, see [walkthrough.md](walkthrough.md). For check commands, see [../verify.md](../verify.md).

All server-side commands run as the admin user over SSH (through WireGuard).

Contents:

1. [What runs by itself](#1-what-runs-by-itself)
2. [Maintenance calendar](#2-maintenance-calendar)
3. [Semaphore setup](#3-semaphore-setup)
4. [Responding to notifications](#4-responding-to-notifications)
5. [Routine procedures](#5-routine-procedures)
6. [Troubleshooting](#6-troubleshooting)
7. [Recovery](#7-recovery)
8. [Where to look](#8-where-to-look)

---

## 1. What runs by itself

| What | When | Where it reports |
| --- | --- | --- |
| Debian security updates (unattended-upgrades) | Daily | `/var/log/unattended-upgrades/` |
| Service restarts after an upgrade (needrestart) | After each upgrade | journal |
| ClamAV signature updates (freshclam) | Several times a day | `journalctl -u clamav-freshclam` |
| ClamAV scan | Daily at 00:00 | Telegram |
| SMART self-tests | Short daily at 02:00, long on Saturdays at 03:00 | Telegram on problems only |
| Disk space check | Every 15 minutes | Telegram when a threshold is crossed |
| Integrity check (NTP, sshd logging, libraries, Ebury) | Every 15 minutes | Telegram when the findings change, then daily while they last |
| YARA scan (files and sshd memory) | Daily at 01:00 | Telegram on matches or errors only |
| Backup to the USB disk and S3 (restic) | Daily at 02:30; prune and check on Sundays | Telegram at every run |

Nothing in this list reboots the server or updates container images. Those happen only through the `update-os` job and, later, `update-containers`.

## 2. Maintenance calendar

### Every day (one minute)

- Read the Telegram messages. Two arrive every day: "✅ CLAMAV: SCAN CLEAN" and "✅ BACKUP OK". They show that the server, the scans, the backup and the notifications all work: **if one does not arrive, something is wrong** even without an error message (server down, timer stopped, Telegram unreachable). See [No daily ClamAV message](#no-daily-clamav-message) and [Backup failed](#backup-failed).

### Every week

- The scheduled `update-os` job runs in Semaphore. Check that it ended green; if it failed, see [update-os failed](#update-os-failed).
- If Renovate opened PRs (once the application roles exist), read the changelogs and merge.

### Every month

- Run the full playbook from Semaphore or the laptop. On an unchanged server it must report `changed=0`. Anything else means someone changed the server by hand, or the playbook changed: read the diff before accepting it.
  ```bash
  ansible-playbook site.yml --check --diff --ask-vault-pass
  ```
- Check the disk and the logs:
  ```bash
  df -h /
  sudo smartctl -a /dev/nvme0n1 | grep -iE 'critical warning|percentage used|media and data integrity|unsafe shutdowns'   # NVMe
  sudo smartctl -a /dev/sda | grep -iE 'reallocated|pending|uncorrectable|wear'                                          # SATA
  journalctl -p err --since "-30 days" | tail -50
  ```
- Look at what the firewall drops, to spot unexpected traffic:
  ```bash
  journalctl -k -g nft-input-drop --since "-7 days" | awk '{for(i=1;i<=NF;i++) if($i~/^(SRC|DPT)=/) printf "%s ",$i; print ""}' | sort | uniq -c | sort -rn | head
  ```
- Clean up unused Docker images:
  ```bash
  docker-svc system df
  docker-svc image prune -a     # removes images not used by any container
  ```

### Every three months

- Check the ClamAV quarantine and empty it once each file has been examined (see [Malware detected](#malware-detected)).
- Test that notifications work end to end: `sudo notify-telegram "Quarterly test from $(hostname)"`.
- Run the EICAR test from `verify.md` section 8, and the YARA one from section 12.
- **Restore test**: restore one service directory (`/srv/docker/app/<name>`) from each copy and compare it with the original (see [Restore files](#restore-files)). A backup that was never restored is not a backup.
- Check that object lock or versioning is still on for the bucket, and look at its size and cost.
- Refresh the YARA rules on the laptop, see [Refresh the YARA rules](#refresh-the-yara-rules).
- Check that the copy of the emergency secrets is still readable and up to date (backup password, Ansible Vault password, the admin user's console password).

### Every year

- Disaster recovery drill: rebuild the server on a lab VM from the repository and the backup (see [Rebuild the server](#rebuild-the-server)). Write down how long it took.
- Check the Debian release calendar: Debian 13 gets security support until about mid-2028, then LTS. Plan the move to Debian 14 within a year of its release (see [Major Debian upgrade](#major-debian-upgrade)).
- Review the SSH keys in `admin_ssh_keys` and remove the ones from devices you no longer use.
- Rotate the Telegram token and the Cloudflare token.

## 3. Semaphore setup

| Template | Command | Schedule |
| --- | --- | --- |
| Configure server | `site.yml` | Manual, and monthly as a drift check |
| Drift check | `site.yml --check --diff` | Optional, weekly |
| Update OS | `site.yml --tags update-os` | Weekly, at night (e.g. Sunday 04:00, away from the 00:00 scan and the 02:00–03:00 SMART tests) |
| Network | `site.yml --tags network` | **Manual only**, never scheduled |

Store the vault password and Semaphore's SSH key in the Key Store. Semaphore's key gives root on the server: treat the Semaphore host as part of production.

Turn on Semaphore's notifications for failed tasks, or a failed `update-os` job can go unnoticed for a week.

## 4. Responding to notifications

### Malware detected

Message: `⚠️ CLAMAV: MALWARE DETECTED`.

With the default action (`quarantine`) the file has already been moved to `/root/clamav-quarantine`.

1. Read the full log named in the message:
   ```bash
   sudo cat /var/log/clamav/scan_<date>.log
   ```
2. Work out where the file came from. Under `/srv` it was uploaded to an application (OpenCloud, Paperless, Immich); under `/tmp` or the admin home, a process on the server wrote it.
3. Decide:
   - **False positive** (a known, legitimate file): put it back and report it at https://www.clamav.net/reports/fp.
     ```bash
     sudo mv /root/clamav-quarantine/<file> <original path>
     ```
     The quarantine keeps only the file name, so take the original path from the log.
   - **Real threat in an upload**: delete it from the quarantine and find out which device it came from.
   - **Real threat outside uploads** (`/etc`, `/tmp`, admin home): treat the server as compromised. See [Suspected compromise](#suspected-compromise).
4. Empty the quarantine once you are done: `sudo rm /root/clamav-quarantine/<file>`.

### ClamAV scan error

Message: `❌ CLAMAV: SCAN ERROR`.

1. Read the log named in the message.
2. Common causes:
   - clamd was not running: `systemctl status clamav-daemon`, then `sudo systemctl restart clamav-daemon`;
   - signature database corrupt or missing: `sudo systemctl restart clamav-freshclam` and check `journalctl -u clamav-freshclam`. If freshclam cannot download, check that `database.clamav.net` is allowed on OPNsense;
   - not enough RAM for clamd: `journalctl -k -g oom`.
3. Run a manual scan to confirm: `sudo systemctl start clamav-scan.service`.

### No daily ClamAV message

Check in this order:

1. Is the server up? From the laptop: `ssh <admin>@<management IP>`.
2. Did the scan run? `systemctl list-timers clamav-scan.timer` and `journalctl -u clamav-scan.service --since today`.
3. Does Telegram work? `sudo notify-telegram test; echo $?` (1 = Telegram refused or unreachable, 2 = credentials missing). Check that `api.telegram.org` is allowed on OPNsense and that the token is still valid.

### Integrity check alert

Message: `🚨 INTEGRITY CHECK: <n> FINDING(S)`. Each line says what was found. Most of these never happen on a healthy server, so **treat them as an intrusion until you have an explanation**, and do not type any password on the server while you look (Ebury records them; the admin login uses keys and sudo needs no password).

| Finding | Harmless explanation to rule out | If there is none |
| --- | --- | --- |
| NTP turned off, timesyncd not running | Someone ran `timedatectl set-ntp false` while testing | Run the playbook (`--tags base`), then look for who did it: `journalctl _COMM=sudo` and `journalctl -u ssh` |
| Clock not synchronized | OPNsense NTP down, or `ntp_servers` wrong (check it matches the gateway of the management network) | `timedatectl timesync-status` |
| sshd LogLevel below INFO, or `-q` in the start options | None: the playbook sets `VERBOSE` | [Suspected compromise](#suspected-compromise) |
| setuid/setgid shared library; shared object not installed by any package | A library installed by hand (then add it to `integrity_lib_allowlist`) | [Suspected compromise](#suspected-compromise). This is exactly how Ebury 1.8.3 hides |
| setuid/setgid file, or file with no owner, in a library directory | A package removed without purge left a file | `dpkg -S <path>`; if no package claims it and you did not put it there, [Suspected compromise](#suspected-compromise) |
| `/etc/ld.so.preload` or `LD_PRELOAD` set | None on this server | [Suspected compromise](#suspected-compromise) |
| Unexpected process in `ssh.service` | None | [Suspected compromise](#suspected-compromise) |
| Ebury socket found | None | [Suspected compromise](#suspected-compromise) |

Look at the details with a clean shell, which defuses Ebury's userland rootkit:

```bash
H=1 I=1 LD_PRELOAD=: LD_DEBUG=: bash
journalctl -u integrity-check.service --since -1h
```

When the cause is gone, the next run sends "✅ INTEGRITY CHECK: ALL CLEAR".

### YARA match

Message: `🚨 YARA: <n> MATCH(ES)`. Each line is a rule name and a file, or a rule name and a process (`PID <n> (<program>)`). Nothing was moved or deleted.

1. Read the log named in the message: `sudo cat /var/log/yara/scan_<date>.log`.
2. The rule name says what it is: `Linux_Trojan_Ebury_*`, `libkeyutils_with_ctor` or `Ebury_v1_7_crypto` mean Ebury; `Linux_Rootkit_*` a rootkit; `*_Cryptominer_*` a miner; `Multi_EICAR_*` the test file.
3. Decide:
   - **A match in memory, on a system binary or library, or in `/etc`**: [Suspected compromise](#suspected-compromise).
   - **A match inside `~svc-docker/.local/share/docker`**: find which container or image owns the layer (the directory name after `overlay2/`):
     ```bash
     docker-svc inspect --format '{{.Name}} {{.GraphDriver.Data.UpperDir}}' $(docker-svc ps -aq) | grep <layer id>
     docker-svc image inspect --format '{{.RepoTags}} {{.GraphDriver.Data.LowerDir}} {{.GraphDriver.Data.UpperDir}}' $(docker-svc images -q) | grep <layer id>
     ```
     A container layer means something wrote the file at run time: stop the container and treat the application as compromised. An image layer means the image shipped it: report it upstream and pin a clean version.
   - **A match in an upload under `/srv`**: like ClamAV, delete it and find out where it came from.
   - **A false positive** (a legitimate file you can identify): note the rule name; if it repeats, remove that rule file with the next refresh (`ELASTIC_EXCLUDE` in `scripts/update-yara-rules.sh`) rather than excluding the path.

### YARA scan error

Message: `❌ YARA: SCAN ERROR`. Usually the rules do not compile after a refresh: run `sudo yara-scan --compile-only` and read the error, then fix or drop the rule on the laptop and run the playbook with `--tags yara`.

### Backup failed

Message: `❌ BACKUP FAILED` or `⚠️ BACKUP COMPLETED WITH WARNINGS`. Each copy has its own line; the other copy may well have succeeded.

| Line | Cause | What to do |
| --- | --- | --- |
| `USB disk not connected` | Disk unplugged, cable, or a different label | Plug it in, `ls /dev/disk/by-label/`, then `sudo systemctl start backup.service` |
| `cannot mount` | Filesystem damaged | `sudo fsck.ext4 /dev/disk/by-label/backup-usb`; if it cannot be repaired, replace the disk ([Replace the USB disk](#replace-the-usb-disk)) |
| `the repository does not exist` | A new disk or bucket, or the repository was deleted | New: `sudo backup --init`. Not new: someone deleted it, see [Suspected compromise](#suspected-compromise); for S3, the old versions are still in the bucket if object lock or versioning is on |
| S3 errors (`Access Denied`, timeouts) | Key revoked or expired, bucket policy, endpoint not allowed on OPNsense | Check the key at the provider and the OPNsense log, then run the backup by hand |
| `repository is already locked` | A previous run was interrupted (reboot, power cut) | `sudo backup usb list locks` or `sudo backup s3 list locks`, then `sudo backup <copy> unlock` |
| `prune or check failed` | Damaged repository data (disk errors on USB, rare on S3) | `sudo backup <copy> check --read-data`; if it reports damaged data, start a new repository on that copy and keep the old one until the new one has a few weeks of history |
| `some files could not be read` | A file vanished or changed during the backup | Harmless once in a while; if it repeats, see which file in `journalctl -u backup.service` |
| `Pre-backup scripts: at least one failed` | An application's dump failed (container down, database error) | `journalctl -u backup.service`, fix the application; the previous dump was backed up |

Run the backup by hand: `sudo systemctl start backup.service`, then `journalctl -u backup.service -n 50`.

### SMART warning

Message: `💽 SMART WARNING`. It contains the failure type (`SMARTD_FAILTYPE`) and the details.

| Type | Meaning | What to do |
| --- | --- | --- |
| `Health` | The disk says it is failing | **Replace the disk now.** Check that the latest backup completed, then follow [Replace the disk](#replace-the-disk). |
| `CurrentPendingSector`, `OfflineUncorrectableSector` | Sectors that cannot be read | Check the backup, run a long test, plan the replacement within days. |
| `Usage` | An attribute crossed its threshold | `sudo smartctl -a <device>` and judge: for NVMe, `Percentage Used` close to 100% means the disk is wearing out. |
| `Temperature` | Over 45 °C (information) or 55 °C (alarm) | Check airflow and dust in the OptiPlex; a Micro in a closed cabinet runs hot. |
| `SelfTest`, `ErrorCount` | A self-test failed or new errors were logged | `sudo smartctl -l selftest <device>` and `-l error`; treat repeated errors like a pending sector. |

With a single disk the backup is the only copy: a SMART warning is the moment to check that the last backup worked.

### Disk space low

Message: `⚠️ DISK SPACE LOW`.

1. Find what grew:
   ```bash
   sudo du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -20
   docker-svc system df
   journalctl --disk-usage
   ```
2. Usual suspects and fixes:
   - **Docker images and build cache**: `docker-svc image prune -a`, `docker-svc builder prune`;
   - **container logs** are capped at 30 MB per container, but many containers add up: `docker-svc ps -s`;
   - **application data** (Immich, OpenCloud): this is real growth, not something to clean. Plan a bigger disk;
   - **the journal** is capped at 500 MB; ClamAV logs are deleted after 30 days.
3. Never delete files inside `~svc-docker/.local/share/docker` by hand: use the `docker-svc` commands.
4. When usage goes back below the threshold, a "✅ DISK SPACE BACK TO NORMAL" message arrives.

## 5. Routine procedures

Every procedure that changes the configuration follows the same pattern: change the repository, commit, run the playbook. Do not edit files on the server by hand: the next run overwrites them.

### Add or remove an SSH key

1. Edit `admin_ssh_keys` in `inventory/group_vars/prod_servers/main.yml`.
2. `ansible-playbook site.yml --tags hardening --ask-vault-pass`.

The list is exclusive: a key you remove is deleted from the server. **Never remove the key you are using in the same run.** Add the new key, run, test that it works, then remove the old one and run again.

### Rotate the Telegram token

1. In @BotFather: `/revoke`, choose the bot, copy the new token.
2. `ansible-vault edit inventory/group_vars/prod_servers/vault.yml` and replace `vault_telegram_bot_token`.
3. `ansible-playbook site.yml --tags monitoring --ask-vault-pass` (the `notify` role runs as a dependency).
4. `sudo notify-telegram "New token works"`.
5. Commit the encrypted vault.

### Change the vault password

```bash
ansible-vault rekey inventory/group_vars/prod_servers/vault.yml
```

Then update the password in Semaphore's Key Store and in the offline copy of the emergency secrets.

### Change the scan schedule, the paths or the disk threshold

Edit the corresponding variable in `group_vars` (see the defaults in `roles/clamav/defaults/main.yml` and `roles/monitoring/defaults/main.yml`), then run `--tags clamav` or `--tags monitoring`.

### Refresh the YARA rules

On the laptop, which can reach GitHub:

1. Find the latest commits of [eset/malware-ioc](https://github.com/eset/malware-ioc/commits/master) and [elastic/protections-artifacts](https://github.com/elastic/protections-artifacts/commits/main).
2. Update `ESET_COMMIT` and `ELASTIC_COMMIT` in `scripts/update-yara-rules.sh`, then run it.
3. Review `git diff --stat roles/yara/files/rules` (new and removed rules) and commit.
4. `ansible-playbook site.yml --tags yara --ask-vault-pass`. The play compiles the rules on the server and fails if one is broken.
5. Run a scan by hand (`sudo systemctl start yara-scan.service`) to see whether the new rules flag anything.

### Restore files

The `backup` script loads the credentials and mounts the disk:

```bash
sudo backup usb snapshots                       # or: sudo backup s3 snapshots
sudo backup usb restore latest --target /tmp/restore --include /srv/docker/app/<name>
sudo diff -r /tmp/restore/srv/docker/app/<name> /srv/docker/app/<name>    # restore test: compare
sudo rm -rf /tmp/restore
```

To put data back in place, stop the application first, restore into a temporary directory, then move the files (or restore with `--target /`, which overwrites the current files). A snapshot from a specific day: take its ID from `snapshots` instead of `latest`.

### Replace the USB disk

1. Format the new disk with the label (README, "First setup") and plug it in.
2. `sudo backup --init`, then `sudo systemctl start backup.service`.
3. Keep the old disk, unplugged, until the new one has a few weeks of history.

To keep a copy away from the house, you can rotate two labelled disks: each starts with `backup --init` and from then on gets backed up whenever it is plugged in.

### Change the backup password or the S3 key

- **S3 key**: create the new key at the provider, update the vault, run `--tags backup`, revoke the old key.
- **restic password**: `sudo backup usb key add` and `sudo backup s3 key add` (enter the new password), update the vault, run `--tags backup`, run a backup, then remove the old key from each copy (`sudo backup <copy> key list`, `sudo backup <copy> key remove <ID>`). Update the emergency sheet.

### Change the network (VLANs, addresses)

1. Plan a maintenance window: the server reboots.
2. Make sure you can reach the server's console (monitor and keyboard) in case it goes wrong.
3. Edit `network_links`. If the management address changes, also update `ansible_host` in `inventory/hosts.ini`, plus `ssh_listen_address` and `mgmt_address` if they are set.
4. Prepare the switch and OPNsense first: the new VLAN must already work on the trunk.
5. `ansible-playbook site.yml --tags network --ask-vault-pass`.
6. Then run `--tags security`, so the firewall and sshd pick up the new addresses.

If the change breaks access, the server returns to the previous configuration by itself within about 5 minutes after boot (see [The network change failed](#the-network-change-failed)).

### Reboot by hand

```bash
sudo systemctl reboot
```

Everything comes back on its own: nftables, ClamAV, timers and the rootless Docker daemon (linger), and with it the containers that have `restart: unless-stopped` or `always`. After the reboot, check with `docker-svc ps`.

### Major Debian upgrade

The playbook refuses anything other than Debian 13, and `update-os` never changes release. For Debian 14:

1. Wait at least for the first point release (14.1).
2. Rehearse on a lab VM: install Debian 13, run the playbook, upgrade it by hand to 14 following the official release notes, then fix the playbook (repository suite, package names, the version `assert` in `site.yml`) until a full run on 14 is clean and idempotent.
3. Check that the backup is recent and tested.
4. On the server: follow the release notes, then run the updated playbook.

Rebuilding on Debian 14 and restoring the data, as in [Rebuild the server](#rebuild-the-server), is a valid alternative to the in-place upgrade, and doubles as a disaster recovery test.

### The Docker repository key changed

If **Download the Docker repository key** fails on the checksum:

1. Do not just update the checksum. Check the fingerprint published at https://docs.docker.com/engine/install/debian/.
2. Download the key and compare:
   ```bash
   curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --show-keys
   curl -fsSL https://download.docker.com/linux/debian/gpg | sha256sum
   ```
3. If the fingerprint matches the official one, put the new SHA-256 into `docker_apt_key_checksum` and update the fingerprint in the comment.

## 6. Troubleshooting

### update-os failed

Read the Semaphore output, then:

| Failed task | Likely cause | What to do |
| --- | --- | --- |
| Upgrade all packages | Repository unreachable, or dpkg interrupted | Check egress on OPNsense (`deb.debian.org`, `security.debian.org`, `download.docker.com`). On the server: `sudo dpkg --configure -a`, then `sudo apt update`. |
| Reboot the server | The server did not come back within 10 minutes | Check the console. Usually a slow boot or a disk check; if it does not boot, see [Recovery](#7-recovery). |
| Check that the rootless Docker daemon is running | Daemon not starting after the upgrade | See [Rootless Docker does not start](#rootless-docker-does-not-start). |

### Rootless Docker does not start

```bash
UID_SVC=$(id -u svc-docker)
sudo -u svc-docker XDG_RUNTIME_DIR=/run/user/$UID_SVC systemctl --user status docker
sudo journalctl _SYSTEMD_USER_UNIT=docker.service _UID=$UID_SVC -n 50
loginctl show-user svc-docker | grep Linger        # must be Linger=yes
```

Common causes:

- **Linger lost**: `sudo loginctl enable-linger svc-docker`, or run the playbook with `--tags docker`.
- **Port already in use** (53, 80, 443): `sudo ss -ltnup | grep -E ':(53|80|443) '`.
- **Upgrade of rootless-extras or slirp4netns**: run `--tags docker`, which rewrites the unit and restarts the daemon.
- **Disk full**: see [DISK SPACE LOW](#disk-space-low).

To restart it by hand:

```bash
sudo -u svc-docker XDG_RUNTIME_DIR=/run/user/$(id -u svc-docker) systemctl --user restart docker
```

### A service is not reachable

From inside out:

1. Is the container running? `docker-svc ps`.
2. Does it answer on the server? `curl -I http://<services IP>`.
3. Does the host firewall drop it? `journalctl -k -g nft-input-drop --since -10min`.
4. Does OPNsense drop it? Look at its firewall log for the services VLAN.
5. Is the client coming in through WireGuard? Nothing is published to the Internet.

### SSH refuses the connection

- `Permission denied (publickey)`: the key is not in `admin_ssh_keys`, or you are using the wrong user.
- Connection timed out: you are not on the management VLAN or on WireGuard; or `firewall_ssh_allowed_sources` excludes your network.
- If nothing works, use the console (see [Lost SSH access](#lost-ssh-access)).

### The network change failed

The play fails with "The server restored its previous network configuration", or it fails at the reboot step.

1. Wait 5–10 minutes: the server restores the old configuration and reboots by itself.
2. Reconnect on the old address and read what happened:
   ```bash
   journalctl -t network-rollback
   cat /etc/network/interfaces.new        # the configuration that failed
   ```
3. Usual causes: the VLAN is not allowed on the switch trunk, the wrong VLAN ID, the gateway missing on OPNsense, or the management address changed without updating `ansible_host`.

## 7. Recovery

### Lost SSH access

Connect a monitor and a keyboard to the OptiPlex and log in on the console as the admin user, **with the password set during the Debian installation**. The playbook never changes it, and SSH rejects it, but the console accepts it. Keep that password with the emergency secrets.

Then:

- firewall: `sudo nft flush ruleset` opens everything until the next reboot or run;
- SSH: `sudo sshd -T` shows the effective configuration; `sudo journalctl -u ssh -n 50` shows why it refuses;
- fix the cause in the repository and run the playbook again.

### Replace the disk

With a single disk, replacing it means rebuilding the server:

1. Make sure the last backup completed and, if possible, copy anything still readable.
2. Fit the new disk and follow [Rebuild the server](#rebuild-the-server).

### Rebuild the server

This is also the yearly drill, on a lab VM.

1. Install Debian 13 from netinst: admin user with the same name, empty root password, static IP on the management network, SSH server.
2. `ssh-copy-id` your key.
3. Remove the old host key from your `known_hosts`, since the server has a new one: `ssh-keygen -R <management IP>`.
4. `ansible-playbook site.yml --ask-vault-pass`.
5. `ansible-playbook site.yml --tags network --ask-vault-pass` to move to the VLANs, then `--tags security`.
6. Restore the data: `sudo backup usb restore latest --target /` (or `s3`, if the USB disk is lost too), then deploy the applications (procedure to be completed with the application roles). The playbook run in step 4 already wrote the credentials, so the restore needs only the vault.
7. Check everything with `verify.md`.
8. Note how long it took and what was missing from this guide, then update it.

### Suspected compromise

1. Isolate the server: on OPNsense, block all traffic from and to its VLANs, except your management access.
2. Do not reboot and do not delete anything yet: logs and files are evidence. Do not type passwords on the server (Ebury records them); work in a clean shell: `H=1 I=1 LD_PRELOAD=: LD_DEBUG=: bash`.
3. Copy what you need for the analysis to another machine: the journal (`journalctl -o export`), the ClamAV and YARA logs, the quarantine, the list of processes and connections (`ps auxf`, `ss -tupan`), and any file named in an integrity or YARA alert. A clean check from the running system proves little: if you can, examine the disk from a rescue system or an image.
4. Rotate every secret the server held: the Telegram token, the Cloudflare token and the application passwords. Rotate the SSH keys as well if the admin account was involved.
5. Rebuild from scratch ([Rebuild the server](#rebuild-the-server)) and restore data from a backup **older** than the compromise.

## 8. Where to look

| What | Command or path |
| --- | --- |
| Timers and next runs | `systemctl list-timers` |
| ClamAV scans | `/var/log/clamav/scan_*.log`, `journalctl -u clamav-scan.service` |
| ClamAV quarantine | `/root/clamav-quarantine/` |
| Signature updates | `journalctl -u clamav-freshclam` |
| Automatic updates | `/var/log/unattended-upgrades/unattended-upgrades.log` |
| apt history | `/var/log/apt/history.log` |
| Firewall drops | `journalctl -k -g nft-input-drop` |
| SSH | `journalctl -u ssh` |
| Rootless Docker | `sudo journalctl _SYSTEMD_USER_UNIT=docker.service _UID=$(id -u svc-docker)` |
| Network rollback | `journalctl -t network-rollback` |
| SMART | `journalctl -u smartmontools`, `sudo smartctl -a <device>` |
| Disk space alert state | `/var/lib/disk-space-check/` |
| Integrity check | `journalctl -u integrity-check.service`, state in `/var/lib/integrity-check/state` |
| YARA scans | `/var/log/yara/scan_*.log`, `journalctl -u yara-scan.service` |
| Time synchronization | `timedatectl timesync-status` |
| Backup | `journalctl -u backup.service`, `sudo backup usb snapshots`, `sudo backup s3 snapshots` |
| Errors in the last 24 hours | `journalctl -p err --since -24h` |
