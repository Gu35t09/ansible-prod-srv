# Maintenance guide

How to keep the production server healthy: what runs by itself, what to do by hand and when, how to react to each notification, and how to recover when something breaks.

For what each task does, see [walkthrough.md](walkthrough.md). For check commands, see [../verify.md](../verify.md). For operating the containers, see [containers.md](containers.md).

All server-side commands run as the admin user over SSH (through WireGuard).

Contents:

1. [What runs by itself](#1-what-runs-by-itself)
2. [Maintenance calendar](#2-maintenance-calendar)
3. [Running the playbook](#3-running-the-playbook)
4. [Responding to notifications](#4-responding-to-notifications)
5. [Routine procedures](#5-routine-procedures)
6. [Troubleshooting](#6-troubleshooting)
7. [Recovery](#7-recovery)
8. [Where to look](#8-where-to-look)

---

## 1. What runs by itself

| What | When | Where it reports |
| --- | --- | --- |
| Package updates (unattended-upgrades): Debian stable, updates and security, and Docker | Daily at 04:00 (`apt-daily-upgrade.timer`) | Telegram at every run: packages upgraded, nothing to install, or errors, and whether a reboot is needed |
| Rootless Docker restart after a Docker upgrade, then a wait for every container | In the same run | The same Telegram message: "🐳 Docker upgraded" or "❌ … DOCKER NEEDS ATTENTION" |
| Package list download (`apt-daily`) | Daily at 03:45 | Telegram only if it fails |
| Service restarts after an upgrade (needrestart) | After each upgrade | journal |
| ClamAV signature updates (freshclam) | Several times a day | `journalctl -u clamav-freshclam` |
| ClamAV scan | Daily at 00:00 | Telegram |
| SMART self-tests | Short daily at 02:00, long on Saturdays at 03:00 | Telegram on problems only |
| Disk space check | Every 15 minutes | Telegram when a threshold is crossed |
| Integrity check (NTP, sshd logging, libraries, Ebury) | Every 15 minutes | Telegram when the findings change, then daily while they last |
| YARA scan (files and sshd memory) | Daily at 01:00 | Telegram on matches or errors only |
| Backup to the USB disk and S3 (restic) | Daily at 02:30; prune and check on Sundays (5% of the data read back each time); OpenCloud is stopped while it runs | Telegram at every run |
| Renovate (on GitHub, not on the server) | Saturday morning | Telegram when there are new PRs, updates to do by hand, or a run that did not finish |

Nothing in this list reboots the server or updates container images (a Docker upgrade restarts the containers, with the same images). Container images change only through `update-containers`; the server is rebooted only by you, by hand: the disk is encrypted and its passphrase is typed at the console at every boot (`update_os_allow_reboot: false`).

## 2. Maintenance calendar

### Every day (one minute)

- Read the Telegram messages. Three arrive every day: "✅ UNATTENDED-UPGRADES" (packages upgraded or nothing to install), "✅ CLAMAV: SCAN CLEAN" and "✅ BACKUP OK". A message with "🔁 REBOOT REQUIRED" means a newer kernel (or a package) waits for a reboot: plan one (see [Reboot by hand](#reboot-by-hand)). They show that the server, the scans, the backup and the notifications all work: **if one does not arrive, something is wrong** even without an error message (server down, timer stopped, Telegram unreachable). See [No daily ClamAV message](#no-daily-clamav-message) and [Backup failed](#backup-failed). Uptime Kuma also reports a job that did not run, as a "Down" of its push monitor (see [A job's push monitor is down](#a-jobs-push-monitor-is-down)), as long as the server and Telegram work.

### Every week

- Saturday morning: if the Telegram message "🔄 RENOVATE" arrived, review the PRs (see [Image updates](#image-updates)). A "❌ RENOVATE DID NOT FINISH" message gives Renovate's result and links to the run log; run it again with *Actions → Renovate → Run workflow* once the cause is fixed (a temporary error such as `repository-changed` usually needs nothing).

### Every month

- Run the full playbook from the laptop. On an unchanged server it must report `changed=0`. Anything else means someone changed the server by hand, or the playbook changed: read the diff before accepting it.
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
- Check that the four bucket lock rules (90 days) are still on in the R2 dashboard, and look at the bucket's size and cost.
- Refresh the YARA rules on the laptop, see [Refresh the YARA rules](#refresh-the-yara-rules).
- Check the emergency secrets key and refresh the Vaultwarden export on it (see [Emergency secrets key](#emergency-secrets-key)).

### Every year

- Disaster recovery drill: rebuild the server on a lab VM from the repository and the emergency key (see [Drill on a VM](#drill-on-a-vm)). Write down how long it took.
- Check the Debian release calendar: Debian 13 gets security support until about mid-2028, then LTS. Plan the move to Debian 14 within a year of its release (see [Major Debian upgrade](#major-debian-upgrade)).
- Review the SSH keys in `admin_ssh_keys` and remove the ones from devices you no longer use.
- Rotate the Telegram token (see [Rotate the Telegram token](#rotate-the-telegram-token): it is also a GitHub secret) and the Cloudflare token.

## 3. Running the playbook

The playbook runs from the laptop, by hand; nothing outside the server is scheduled. The updates run on the server itself (section 1).

| What | Command | When |
| --- | --- | --- |
| Configure the server | `site.yml` | After a change to the repository |
| Drift check | `site.yml --check --diff` | Monthly: `changed=0` on an unchanged server |
| Container images | `site.yml --tags update-containers` | After merging a Renovate PR |
| Full upgrade | `site.yml --tags update-os` | Rarely: when the morning report lists packages under "Kept back" |
| Network | `site.yml --tags network` | **By hand only** |

The laptop holds the SSH key that becomes root on the server and types the vault password: treat it as part of production (encrypted disk, a passphrase on the key, screen lock).

Semaphore is not deployed: it would need a host of its own, outside the server it manages and outside OPNsense. If it is added later, give it the vault password and its own SSH key in its Key Store, and turn on its notifications for failed tasks.

## 4. Responding to notifications

### A job's push monitor is down

Message from Uptime Kuma: `[Backup] [🔴 Down] …` (or ClamAV scan, YARA scan, Unattended upgrades, Integrity check, Disk space check).

- **`No heartbeat in the time window`**: the job did not run, or did not finish. `systemctl list-timers` (is the timer there, when did it last run?), `systemctl status <unit>` and `journalctl -u <unit> -n 50`. A timer left disabled (as in the [drill](#drill-on-a-vm)) is turned on again by running the role's tag.
- **`exit-code (exited 1)`** or another result: the job ran and failed; its own Telegram message says why (see the sections below).
- **`notify-push: … Uptime Kuma did not accept the call`** in the job's journal, with the monitor still down: the token in the vault does not match the monitor (a monitor recreated in Uptime Kuma gets a new token). Copy it again into `vault_uptime_kuma_push_tokens` and run `--tags base`.

After a long stop of the server (more than 30 minutes, e.g. waiting for the disk passphrase) the two 15-minute monitors turn down when Uptime Kuma starts and up again at the next run: nothing to do.

### Docker needs attention

Message: `❌ UNATTENDED-UPGRADES: DOCKER NEEDS ATTENTION`, after Docker's packages were upgraded at night.

- **"the rootless daemon did not restart"**: see [Rootless Docker does not start](#rootless-docker-does-not-start).
- **"these containers are not back"**: the daemon runs, but the named containers are not running or not healthy five minutes later. `docker-svc ps -a`, then `docker-svc logs <name>`. A container that depends on its database (Immich, Paperless) can need a second start: `docker-svc restart <name>`. If the new Docker version breaks something, run the service's tag again (`--tags <service>`) and report it; going back to the previous Docker version: `sudo apt install docker-ce=<version> docker-ce-cli=<version>` (`apt-cache madison docker-ce`), then `docker-svc` restart as in the message.
- **"The rootful Docker daemon is running"**: it must stay off, only the rootless one runs. `sudo systemctl disable --now docker.socket docker.service containerd.service`, then run `--tags docker` and find out what started it.

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
| `prune or check failed` | Damaged repository data (disk errors on USB, rare on S3): the weekly read of 5% of the data finds it before a restore does | `sudo backup <copy> check --read-data`; if it reports damaged data, start a new repository on that copy and keep the old one until the new one has a few weeks of history |
| `some files could not be read` | A file vanished or changed during the backup | Harmless once in a while; if it repeats, see which file in `journalctl -u backup.service` |
| `Pre-backup scripts: at least one failed` | An application's dump failed (container down, database error), or OpenCloud did not stop | `journalctl -u backup.service`, fix the application; the previous dump was backed up |
| `Post-backup scripts: at least one failed` | OpenCloud did not start again after the backup | `docker-svc ps -a`, then `docker-svc start opencloud` and `docker-svc logs --tail 50 opencloud` |

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

### SSH with the YubiKey

The admin key can live on a FIDO2 security key (YubiKey 5, firmware 5.2.3 or later): the private key never leaves it, and every connection needs its PIN and a touch. The file left on the laptop is only a reference, useless without the YubiKey. The server needs no change (OpenSSH accepts `sk-ssh-ed25519` keys by default).

Create the key (it asks for the FIDO2 PIN, `ykman fido access change-pin` sets one, and a touch; the file passphrase can stay empty):

```bash
ssh-keygen -t ed25519-sk -O resident -O verify-required -O application=ssh:prod-srv-01 -C "<name> Yubikey <n>" -f ~/.ssh/id_ed25519_sk
```

- `resident`: the key is stored on the YubiKey too, so a new computer gets the file back with `ssh-keygen -K` (PIN and touch), with nothing to copy.
- `verify-required`: PIN and touch, not touch alone; a found YubiKey is useless without the PIN. Eight wrong PINs lock FIDO2, and resetting it erases every FIDO2 registration on it (passkeys and security keys on the websites as well).
- `~/.ssh/id_ed25519_sk` is one of the names `ssh` tries by itself, so Ansible uses it with no setting. A playbook run asks for the PIN and a touch once: Ansible keeps one SSH connection open for the run (`ControlPersist`).

Add the `.pub` line to `admin_ssh_keys` as in [Add or remove an SSH key](#add-or-remove-an-ssh-key), and check it alone: `ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_sk <admin user>@<management IP>`. Once it works, the laptop's file key (`~/.ssh/id_ed25519`) can go: it stays in `admin_ssh_keys` and on the [emergency secrets key](#emergency-secrets-key) as the way in without the YubiKey. A second YubiKey kept at home, with its own key in the list, avoids depending on that file.

On a new computer: plug the YubiKey, `cd ~/.ssh && ssh-keygen -K`, which writes `id_ed25519_sk_rk_prod-srv-01`; rename it to `id_ed25519_sk` (and its `.pub`).

### Rotate the Telegram token

1. In @BotFather: `/revoke`, choose the bot, copy the new token.
2. `ansible-vault edit inventory/group_vars/prod_servers/vault.yml` and replace `vault_telegram_bot_token`.
3. `ansible-playbook site.yml --tags monitoring --ask-vault-pass` (the `notify` role runs as a dependency).
4. `sudo notify-telegram "New token works"`.
5. Update the `TELEGRAM_BOT_TOKEN` secret on GitHub (*Settings → Secrets and variables → Actions*), or Renovate's messages stop. Check with *Actions → Renovate → Run workflow*.
6. Copy `vault.yml` to the [emergency secrets key](#emergency-secrets-key).

### Change the vault password

```bash
ansible-vault rekey inventory/group_vars/prod_servers/vault.yml
```

Then update the password on the [emergency secrets key](#emergency-secrets-key) and copy the rekeyed `vault.yml` there.

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

The `backup` script loads the credentials and mounts the disk. Restore into `/srv/restore`, never `/tmp/restore`: on Debian 13 `/tmp` is in RAM (tmpfs, about 4 GB here), too small for Immich or OpenCloud. `/srv` has the room, on the same disk as the data.

```bash
sudo backup usb snapshots                       # or: sudo backup s3 snapshots
sudo backup usb restore latest --target /srv/restore --include /srv/docker/app/<name>
sudo diff -r /srv/restore/srv/docker/app/<name> /srv/docker/app/<name>    # restore test: compare
sudo rm -rf /srv/restore
```

To put data back in place, stop the application first, restore into a temporary directory, then move the files (or restore with `--target /`, which overwrites the current files). A snapshot from a specific day: take its ID from `snapshots` instead of `latest`.

### Restore Vaultwarden

The database to restore is the dump, `dump/db.sqlite3`, not `data/db.sqlite3` (a live file, possibly inconsistent in the snapshot). `data/rsa_key.pem` must come from the same snapshot: without it every client has to log in again, but no data is lost.

```bash
docker-svc compose -f /srv/docker/app/vaultwarden/compose.yml stop
sudo backup usb restore latest --target /srv/restore --include /srv/docker/app/vaultwarden
R=/srv/restore/srv/docker/app/vaultwarden; D=/srv/docker/app/vaultwarden
sudo cp -a $R/data/. $D/data/                                     # key, attachments, sends
sudo rm -f $D/data/db.sqlite3-wal $D/data/db.sqlite3-shm
sudo install -o svc-docker -g svc-docker -m 0600 $R/dump/db.sqlite3 $D/data/db.sqlite3   # then the dump over the live copy
docker-svc compose -f /srv/docker/app/vaultwarden/compose.yml start
sudo rm -rf /srv/restore
```

Then log in from a client and check a few entries. For a single lost entry, restoring the server is overkill: use the client's history or an export.

Failed logins are in `sudo grep -i 'username or password is incorrect' /srv/docker/app/vaultwarden/logs/vaultwarden.log`, with the client IP.

### Restore Immich

The library (`library/`) is restored as files. The database comes from the dump, `dump/immich.sql.gz`, into an empty Postgres: the live directory `postgres/` is not in the backup.

```bash
C="docker-svc compose -f /srv/docker/app/immich/compose.yml"; D=/srv/docker/app/immich
$C down
sudo backup usb restore latest --target /srv/restore --include $D/library --include $D/dump
sudo cp -a /srv/restore$D/library/. $D/library/
sudo rm -rf $D/postgres && sudo install -d -o svc-docker -g svc-docker -m 0700 $D/postgres
$C create && docker-svc start immich_postgres && sleep 15
sudo zcat /srv/restore$D/dump/immich.sql.gz \
  | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
  | docker-svc exec -i immich_postgres psql --dbname=postgres --username=postgres
$C up -d
sudo rm -rf /srv/restore
```

The two errors "current user cannot be dropped" and "role "postgres" already exists" are expected. The `sed` is the one in Immich's restore guide. Then log in and open a few photos. The dump also restores the `postgres` user's password as it was when the dump was taken: if `vault_immich_db_password` changed since, the server cannot connect; set it again in Postgres (next section).

### Change the Immich database password

The password file is read by Postgres only when it creates the database, so change the database first, then the vault:

```bash
docker-svc exec -it immich_postgres psql -U postgres -c "ALTER USER postgres PASSWORD '<new password>';"
```

Then put the same value in `vault_immich_db_password` and run `--tags immich`: the server restarts with the new password.

### Restore OpenCloud

Everything is plain files: the configuration (`config/`) and the data (`data/`, users' files with their metadata in extended attributes). Restore both from the same snapshot, with OpenCloud stopped. Copy only with tools that keep extended attributes: `restic restore` and `cp -a` do; `cp` without `-a`, or `rsync` without `-X`, would lose OpenCloud's metadata.

```bash
C="docker-svc compose -f /srv/docker/app/opencloud/compose.yml"; D=/srv/docker/app/opencloud
$C stop
sudo backup usb restore latest --target /srv/restore --include $D/config --include $D/data
sudo rm -rf $D/config $D/data
sudo cp -a /srv/restore$D/config /srv/restore$D/data $D/
$C start
sudo rm -rf /srv/restore
```

Then log in and open a few files. For a single lost file, use the trash or the file versions in the web interface first.

### Restore Paperless

The documents (`media/`) and `data/` are restored as files; the database from its dump into an empty Postgres, as for Immich. restic restores the numeric owners, so the files keep Paperless's subordinate UID.

```bash
C="docker-svc compose -f /srv/docker/app/paperless/compose.yml"; D=/srv/docker/app/paperless
$C down
sudo backup usb restore latest --target /srv/restore --include $D/media --include $D/data --include $D/dump
sudo cp -a /srv/restore$D/media/. $D/media/
sudo cp -a /srv/restore$D/data/. $D/data/
U=$(( $(awk -F: '$1=="svc-docker"{print $2}' /etc/subuid) + 998 )); G=$(( $(awk -F: '$1=="svc-docker"{print $2}' /etc/subgid) + 998 ))
sudo rm -rf $D/postgres && sudo install -d -o $U -g $G -m 0700 $D/postgres   # the container's postgres user, as the role creates it
$C create && docker-svc start paperless_db && sleep 15
sudo zcat /srv/restore$D/dump/paperless.sql.gz | docker-svc exec -i paperless_db psql --username=paperless --dbname=postgres
$C up -d
sudo rm -rf /srv/restore
```

"current user cannot be dropped" and "role "paperless" already exists" are expected. Then log in and open a few documents; if the search finds nothing, rebuild the index: `docker-svc exec paperless document_index reindex`.

### Restore Uptime Kuma

Only its database matters: the monitors, the notification and the history. restic restores the numeric owners, so the file keeps the container user's subordinate UID.

```bash
docker-svc stop uptime-kuma
sudo backup usb restore latest --target /srv/restore --include /srv/docker/app/uptime-kuma/dump
D=/srv/docker/app/uptime-kuma
sudo rm -f $D/data/kuma.db-wal $D/data/kuma.db-shm
sudo cp -p /srv/restore$D/dump/kuma.db $D/data/kuma.db
docker-svc start uptime-kuma
sudo rm -rf /srv/restore
```

The push monitors' tokens are in this database. If it is lost, create the monitors again (README, "Uptime Kuma"): they get new tokens, which go into the vault.

### Migrate the files from Nextcloud

One time, for user `mattia` (the same steps for any other user). Nextcloud and the production server are on networks the laptop cannot reach at the same time, so the files go through the laptop as a tar file. Shares, versions, trash, calendars and contacts are not migrated.

1. **Nextcloud: stop changes and find the files.** On the Nextcloud host:
   ```bash
   docker exec -u www-data <nextcloud container> php occ maintenance:mode --on
   docker exec -u www-data <nextcloud container> php occ config:system:get datadirectory   # inside the container
   docker inspect <nextcloud container> --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'
   ```
   The user's files are in `<data directory>/mattia/files/` (on the host: the mount source of the data directory). Only `files/` is copied: `files_versions/`, `files_trashbin/` and the cache stay behind.
2. **Copy to the laptop** (on the Nextcloud network):
   ```bash
   read -rsp "sudo password on the Nextcloud host: " PW; echo
   printf '%s\n' "$PW" | ssh <user>@<nextcloud host> 'sudo -S -p "" tar -C <host path>/mattia/files -cf - .' > ~/nextcloud-mattia.tar
   unset PW
   tar -tf ~/nextcloud-mattia.tar | grep -v '/$' | wc -l                                    # number of files
   ssh <user>@<nextcloud host> 'sudo find <host path>/mattia/files -type f | wc -l'          # must match
   ```
3. **OpenCloud: create the user and its space.** Log in as `admin`, create `mattia` (*Admin settings → Users*), then log in once as `mattia` in a private window, so that OpenCloud creates the personal space.
4. **Find the space on disk** (on the server):
   ```bash
   sudo python3 -c 'import os; b="/srv/docker/app/opencloud/data/storage/users/users"; [print(d, os.getxattr(f"{b}/{d}", "user.oc.space.alias").decode()) for d in os.listdir(b)]'
   ```
   It prints one directory per personal space: take the one with `personal/mattia`.
5. **Stop OpenCloud** (on the server): `docker-svc compose -f /srv/docker/app/opencloud/compose.yml stop`.
6. **Copy from the laptop** (on the production network). `--no-overwrite-dir` leaves the space's own directory, and the extended attributes OpenCloud keeps on it, untouched:
   ```bash
   SPACE=/srv/docker/app/opencloud/data/storage/users/users/<directory from step 4>
   ssh v@10.123.11.11 "sudo tar -C $SPACE -xf - --no-same-owner --no-overwrite-dir && sudo chown -R svc-docker:svc-docker $SPACE" < ~/nextcloud-mattia.tar
   ```
7. **Start OpenCloud**: `docker-svc compose -f /srv/docker/app/opencloud/compose.yml start`. At start it scans the space and takes in the new files ("assimilation"); with many files it takes a few minutes. Then check in the web interface: the folders, a few files, their dates.
8. **Clients**: install the OpenCloud desktop app on each computer, log in at `https://cloud.greyroom.net` and choose the folders to sync, in a new local folder (not the old Nextcloud one). Remove the Nextcloud client only when everything is in sync.
9. Run a backup (`sudo systemctl start backup.service`). Keep Nextcloud in maintenance mode, untouched, for a few weeks; then delete `~/nextcloud-mattia.tar` from the laptop (it holds every file, unencrypted) and retire Nextcloud.

Tested with rootless Podman: files copied this way appear in OpenCloud with spaces and accents in their names, their original dates and identical content.

### Image updates

Renovate opens the PRs every Saturday; nothing changes on the server until you merge and run the playbook.

1. Open the PR and read the release notes in its description, and the project's own notes for breaking changes. **Immich**: always read them (breaking changes are frequent), and wait a few days after a release: ghcr.io gives no release date, so Renovate cannot hold back fresh Immich releases as it does for Docker Hub images (3 days).
2. Merge.
3. `git pull`, then `ansible-playbook site.yml --tags update-containers --ask-vault-pass`.
4. Check: `docker-svc ps` (all healthy) and the service's checks in `verify.md`.
5. Remove the old images: `docker-svc image prune -a` (only images no container uses; `docker-svc system df` shows the space before). A rollback downloads the old image again, by the same digest.

To roll back, revert the merge commit and run `--tags update-containers` again. Databases are the exception: an application that migrated its database on start may not run on the old version any more; restore the dump from before the update instead (see the restore procedures above).

**Updates to do by hand** (the "🛠️" part of the Telegram message, "Pending Approval" in the Dependency Dashboard). Do not tick their boxes:

- **A Postgres major** (e.g. Immich's `16-vectorchord…`): only when the Immich release notes, or its `docker-compose.yml`, move to it. Then: dump, change `immich_postgres_image`, start with an empty `postgres/`, restore the dump (as in "Restore Immich"). Otherwise ignore it: it stays listed.
- **The `runs-on` runner** (e.g. `ubuntu-26.04`): change it in `.github/workflows/renovate.yml` with a normal PR, then *Run workflow* once to check it.

A new major of Renovate itself (`.github/renovate-image`) is a normal PR: read its release notes for breaking configuration changes, merge, then *Run workflow* to check it.

The Dependency Dashboard issue in the repository lists every pending update, including the ones not opened as PRs.

### Replace the USB disk

1. Format the new disk with the label (README, "First setup") and plug it in.
2. `sudo backup --init`, then `sudo systemctl start backup.service`.
3. Keep the old disk, unplugged, until the new one has a few weeks of history.

To keep a copy away from the house, you can rotate two labelled disks: each starts with `backup --init` and from then on gets backed up whenever it is plugged in.

### Change the Traefik dashboard password or the Cloudflare token

Update `vault_traefik_dashboard_users` (new htpasswd line, see the README) or `vault_cloudflare_dns_api_token`, then `ansible-playbook site.yml --tags traefik --ask-vault-pass`. A new token restarts Traefik; a new password applies without a restart. Revoke the old token at Cloudflare.

### Change the backup password or the S3 key

- **S3 key**: create the new key at the provider, update the vault, run `--tags backup`, revoke the old key.
- **restic password**: `sudo backup usb key add` and `sudo backup s3 key add` (enter the new password), update the vault, run `--tags backup`, run a backup, then remove the old key from the USB copy (`sudo backup usb key list`, `sudo backup usb key remove <ID>`). On S3 the old key file is locked for 90 days after it was written: remove it there once it is older than that, or leave it (it still opens the repository with the old password, so keep that password safe until then). Update the [emergency secrets key](#emergency-secrets-key).

### Clean up the S3 copy (optional)

The S3 copy is append-only and keeps every daily snapshot. If its size starts to cost, clean it up by hand, deleting only what is older than the 90-day lock:

```bash
sudo backup s3 forget --keep-within 100d --keep-monthly 24
sudo backup s3 prune
```

`--keep-within 100d` keeps every snapshot of the last 100 days, so `forget` never touches a locked file. `prune` rewrites the index (not locked) and deletes data no snapshot uses; an error on a recent data file means the lock refused it, and the next clean-up removes it.


### Change the network (VLANs, addresses)

1. Plan a maintenance window: the server reboots, and with the encrypted disk you type the passphrase at the console after each reboot. Be at the machine.
2. Keep the console (monitor and keyboard) connected: it is also how you recover if the change goes wrong.
3. Edit `network_links`. If the management address changes, also update `ansible_host` in `inventory/hosts.ini`, plus `ssh_listen_address` and `mgmt_address` if they are set.
4. Prepare the switch and OPNsense first: the new VLAN must already work on the trunk.
5. `ansible-playbook site.yml --tags network --ask-vault-pass`.
6. Then run `--tags security`, so the firewall and sshd pick up the new addresses.

If the change breaks access, the server returns to the previous configuration by itself within about 5 minutes after boot, and reboots once more (type the passphrase again; see [The network change failed](#the-network-change-failed)).

### Reboot by hand

The disk is encrypted: after the reboot the server waits at the console for the passphrase, and nothing (SSH included) is reachable until it is typed. Reboot when you can be at the machine.

```bash
sudo systemctl reboot
```

Type the passphrase at the console. Then everything comes back on its own: nftables, ClamAV, timers and the rootless Docker daemon (linger), and with it the containers that have `restart: unless-stopped` or `always`. After the reboot, check with `docker-svc ps`.

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

Read the playbook output, then:

| Failed task | Likely cause | What to do |
| --- | --- | --- |
| Upgrade all packages | Repository unreachable, or dpkg interrupted | Check egress on OPNsense (`deb.debian.org`, `security.debian.org`, `download.docker.com`). On the server: `sudo dpkg --configure -a`, then `sudo apt update`. |
| Reboot the server (only with `update_os_allow_reboot: true`) | The server did not come back within 10 minutes | Check the console: with the encrypted disk it waits for the passphrase. Otherwise a slow boot or a disk check; if it does not boot, see [Recovery](#7-recovery). |
| Check that the rootless Docker daemon is running | Daemon not starting after the upgrade | See [Rootless Docker does not start](#rootless-docker-does-not-start). |

### No certificate, or the certificate does not renew

Symptoms: the browser shows Traefik's default certificate, or `TLS` errors on every service. Traefik renews 30 days before expiry, so a failing renewal leaves weeks to react.

1. `sudo grep -i acme /srv/docker/system/traefik/logs/traefik.log | tail`
2. Common causes:
   - `api.cloudflare.com` or `acme-v02.api.letsencrypt.org` not allowed on OPNsense;
   - the token expired or lacks *Zone → Zone → Read* or *Zone → DNS → Edit* on the zone;
   - propagation check timing out: the internal resolver cached the missing record. Wait for the negative TTL, or flush the Unbound cache;
   - Let's Encrypt rate limits after many attempts: use the staging CA (`traefik_acme_ca_server`) while testing.
3. After fixing, `docker-svc compose -f /srv/docker/system/traefik/compose.yml restart`.

### Rootless Docker does not start

```bash
UID_SVC=$(id -u svc-docker)
sudo -u svc-docker XDG_RUNTIME_DIR=/run/user/$UID_SVC systemctl --user status docker
sudo journalctl _SYSTEMD_USER_UNIT=docker.service _UID=$UID_SVC -n 50
loginctl show-user svc-docker | grep Linger        # must be Linger=yes
```

Common causes:

- **Linger lost**: `sudo loginctl enable-linger svc-docker`, or run the playbook with `--tags docker`.
- **Port already in use** (80, 443): `sudo ss -ltnp | grep -E ':(80|443) '`.
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

1. Wait 5–10 minutes: the server restores the old configuration and reboots by itself. Type the passphrase at the console when it asks.
2. Reconnect on the old address and read what happened:
   ```bash
   journalctl -t network-rollback
   cat /etc/network/interfaces.new        # the configuration that failed
   ```
3. Usual causes: the VLAN is not allowed on the switch trunk, the wrong VLAN ID, the gateway missing on OPNsense, or the management address changed without updating `ansible_host`.

## 7. Recovery

### Emergency secrets key

The secrets needed to rebuild the server and read the backups, when the server and the laptop are both gone, are on a USB key with hardware encryption and a PIN keypad (AES-256, FIPS 140-2/140-3 level 3, IP68). It is unlocked on the key itself and then readable on any computer, with no software. It lives on the keyring, so during the day it is away from home; at night it is in the same house as the server and the laptop (accepted risk).

What is on it, in one text file `RECOVERY.txt` (plus the files named):

| Secret | Why |
| --- | --- |
| restic password, R2 endpoint, bucket and prefix, USB disk label | Read the backups. Without the password no copy can be read |
| A copy of `inventory/group_vars/prod_servers/vault.yml` (encrypted) and the Ansible Vault password | The playbook's secrets (database passwords, Paperless secret key, tokens). The file is never committed, so this copy and the laptop are the only ones |
| LUKS passphrase of the server's disk | Boot the server |
| The admin user's console password | Log in at the console when SSH does not work ([Lost SSH access](#lost-ssh-access)) |
| Vaultwarden master password, and `vaultwarden-export.json` (Vaultwarden's password-protected export) with its password | Every other account, including the 2FA recovery codes kept in Vaultwarden |
| The file SSH key (`id_ed25519`, with its passphrase) | Log in and run the playbook from another computer, also without the YubiKey |
| The OPNsense configuration (*System → Configuration → Backups*) | Rebuild the firewall |
| The steps: "clone the repositories, see [Rebuild the server](#rebuild-the-server)" | Where to start |

Not on it: tokens that can be regenerated at the provider (Telegram bot, Cloudflare, R2 access keys).

**Prepare it**: set a PIN you remember without writing it down (never next to the key), format it exFAT, copy the files, lock it, unlock it again and open `RECOVERY.txt`.

**Check it every three months**:

1. Unlock it: the PIN still works and the battery holds a charge.
2. On the laptop, `cmp <key>/vault.yml inventory/group_vars/prod_servers/vault.yml` prints nothing (the copy is current; if not, copy it again), then `ansible-vault view <key>/vault.yml` with the vault password from the key: it opens, and `vault_restic_password` matches the one on the key.
3. Replace `vaultwarden-export.json` with a fresh export (web vault: *Tools → Export vault*, format *.json (Encrypted)*, password-protected).

**Update it** whenever one of these secrets changes (any edit of `vault.yml`, a vault rekey, a new restic password, a new LUKS passphrase).

**If it is lost**: the data cannot be read without the PIN, and the key erases itself after too many wrong attempts. Prepare a new one from the laptop and the server; there is nothing to rotate, unless the PIN may have been seen.

### Lost SSH access

Connect a monitor and a keyboard to the OptiPlex and log in on the console as the admin user, **with the password set during the Debian installation**. The playbook never changes it, and SSH rejects it, but the console accepts it. Keep that password on the [emergency secrets key](#emergency-secrets-key).

Then:

- firewall: `sudo nft flush ruleset` opens everything until the next reboot or run;
- SSH: `sudo sshd -T` shows the effective configuration; `sudo journalctl -u ssh -n 50` shows why it refuses;
- fix the cause in the repository and run the playbook again.

### Lost or stolen laptop

The laptop holds root access to the server: its SSH key is in `admin_ssh_keys` and the admin user has passwordless sudo. It also holds `vault.yml`, logged-in sessions (GitHub, Vaultwarden, OpenCloud) and its WireGuard key, which reaches the management network. What protects them:

- the disk is encrypted with LUKS: safe if the laptop was **off**, not if it was on, suspended or unlocked;
- the SSH key has a passphrase; with the [YubiKey](#ssh-with-the-yubikey) and no file key left on the laptop, the laptop alone cannot log in at all, and steps 3–6 below are not needed (steps 2 and 7 still are);
- the vault password is never stored: it is typed at every run (`--ask-vault-pass`).

Always, from another computer with the [emergency secrets key](#emergency-secrets-key):

1. On OPNsense (*VPN → WireGuard*), disable the laptop's peer: from now on it cannot reach the server from outside. Create a peer for the new computer.
2. Install Ansible, clone the repository, `git config core.hooksPath .githooks`, and copy `vault.yml` from the key into `inventory/group_vars/prod_servers/`.
3. Copy the old key from the key with strict permissions (exFAT has none, and `ssh` refuses a readable key): `install -m 600 <key>/id_ed25519 ~/.ssh/old_laptop`.
4. Create a new key with a passphrase: `ssh-keygen -t ed25519`. Add its `.pub` line to `admin_ssh_keys`, keeping the old one for now, and run `ansible-playbook site.yml --tags hardening --ask-vault-pass --private-key ~/.ssh/old_laptop`.
5. Check that the new key logs in (`ssh <admin user>@<management IP>`). Remove the old line from `admin_ssh_keys`, run `--tags hardening` again (now with the new key), `rm ~/.ssh/old_laptop`, and open a PR with the inventory change.
6. Replace `id_ed25519` and `id_ed25519.pub` on the emergency key with the new ones, and the passphrase in `RECOVERY.txt`.
7. Close the laptop's sessions: GitHub (*Settings → Sessions*, *SSH and GPG keys*, *Applications* for the `gh` token), Vaultwarden (*Deauthorize sessions* in the account settings), OpenCloud (the desktop client's session) and any other account used on it.

If the laptop was on or unlocked, or the vault password may have been seen:

8. Treat the server as possibly compromised for the time the laptop was out of your hands: read the SSH log (`journalctl -u ssh`) for logins you did not make, and if there are any follow [Suspected compromise](#suspected-compromise).
9. Rotate the secrets in `vault.yml` (the list in [Suspected compromise](#suspected-compromise), step 4), then [change the vault password](#change-the-vault-password). A rekey alone is not enough: the old copy of `vault.yml` still opens with the old password.

### Lost YubiKey

Without the PIN the YubiKey cannot be used, and eight wrong attempts lock it, so there is time, but remove it anyway:

1. From the laptop with the emergency file key (`ssh-add` or `--private-key`, see [Lost or stolen laptop](#lost-or-stolen-laptop), step 3), or with the second YubiKey: remove its line from `admin_ssh_keys` and run `--tags hardening`.
2. On every website where it was a second factor or a passkey: log in with the second YubiKey or the recovery codes (in Vaultwarden) and remove it.
3. Register a new YubiKey (see [SSH with the YubiKey](#ssh-with-the-yubikey)) and on the websites.

### Replace the disk

With a single disk, replacing it means rebuilding the server:

1. Make sure the last backup completed and, if possible, copy anything still readable.
2. Fit the new disk and follow [Rebuild the server](#rebuild-the-server).

### Rebuild the server

Everything needed is in the repository on GitHub and on the [emergency secrets key](#emergency-secrets-key).

1. Install Debian 13 from netinst: admin user with the same name, empty root password, static IP on the management network, SSH server, encrypted LVM (a new passphrase is fine) with `/srv` as its own volume taking most of the disk (prod-srv-01: `/` 93 GB, `/var` 37 GB, the rest `/srv`).
2. On the computer you run Ansible from: clone the repository, `ansible-galaxy collection install -r requirements.yml`, `git config core.hooksPath .githooks`, and copy `vault.yml` from the emergency key into `inventory/group_vars/prod_servers/`. If the laptop is gone, copy the SSH key from the emergency key with `install -m 600` (see [Lost or stolen laptop](#lost-or-stolen-laptop)).
3. `ssh-copy-id <admin user>@<management IP>`, and remove the old host key, since the server has a new one: `ssh-keygen -R <management IP>`.
4. `ansible-playbook site.yml --ask-vault-pass -K`. `-K` asks for the admin user's password: on a new install sudo still asks for it; the playbook then makes it passwordless, and later runs need no `-K`.
5. `ansible-playbook site.yml --tags network --ask-vault-pass` to move to the VLANs (at the console: it reboots), then `--tags security`.
6. Restore the applications' data from the USB disk, or with `s3` in place of `usb` if it is lost too. **Only `/srv`**: never restore `/etc` over the new system: `/etc/crypttab` and `/etc/fstab` name the old disk, and the server would not boot; the playbook has already rebuilt `/etc`. If you need an old file from `/etc`, restore it into `/srv/restore` and copy it by hand.
   - [Vaultwarden](#restore-vaultwarden), [Immich](#restore-immich), [OpenCloud](#restore-opencloud), [Paperless](#restore-paperless), [Uptime Kuma](#restore-uptime-kuma): follow their procedures. The databases come from their dumps, not from the files.
   - Traefik: nothing to restore; it requests a new certificate at the first run.
   The playbook run in step 4 already wrote the credentials, so the restore needs only the vault.
7. Check everything with `verify.md`.
8. Note how long it took and what was missing from this guide, then update it.

Time: a restore from R2 ran at about 7.5 MiB/s (14.6 GiB of Immich in 33 minutes, drill of 14 November 2026), so the 47 GB of `/srv` take about 1 h 45 min from R2. The USB disk is faster.

#### Drill on a VM

Once a year (see the calendar), from a fresh clone and the emergency key only, as if the laptop were gone too. The VM must not touch production:

- In the drill's clone only (never commit), point `inventory/hosts.ini` at the VM, `dr-lab ansible_host=<VM IP> ansible_user=<admin user>`, and write `inventory/host_vars/dr-lab.yml`:
  ```yaml
  server_hostname: "dr-lab"            # the Telegram messages say dr-lab
  ssh_listen_address: "<VM IP>"
  services_address: "<VM IP>"
  backup_s3_prefix: "prod-srv-01"      # read the production repository
  backup_usb_enabled: false
  ```
  Outside VLAN 11 add `ntp_servers: ["<the VM's gateway>"]`.
- Right after every playbook run: `sudo systemctl disable --now backup.timer`, or the VM writes its own backups into the production repository at night.
- Skip step 5 (network). Give the VM 2 vCPU, 8 GB of RAM and 150 GB of disk.
- Uptime Kuma on the VM sends real alerts without its host name: check `health.greyroom.net` before worrying about a "Down". Turn the VM off at the end of the day.
- At the end, delete the VM and its disk (it holds the decrypted secrets), the drill's clone and the copied SSH key.

### Suspected compromise

1. Isolate the server: on OPNsense, block all traffic from and to its VLANs, except your management access.
2. Do not reboot and do not delete anything yet: logs and files are evidence. Do not type passwords on the server (Ebury records them); work in a clean shell: `H=1 I=1 LD_PRELOAD=: LD_DEBUG=: bash`.
3. Copy what you need for the analysis to another machine: the journal (`journalctl -o export`), the ClamAV and YARA logs, the quarantine, the list of processes and connections (`ps auxf`, `ss -tupan`), and any file named in an integrity or YARA alert. A clean check from the running system proves little: if you can, examine the disk from a rescue system or an image.
4. Rotate every secret the server held: the Telegram token (and its GitHub secret), the Cloudflare token, the S3 key, the Immich database password and the application passwords. Rotate the SSH keys as well if the admin account was involved.
5. Rebuild from scratch ([Rebuild the server](#rebuild-the-server)) and restore data from a backup **older** than the compromise.

## 8. Where to look

| What | Command or path |
| --- | --- |
| Timers and next runs | `systemctl list-timers` |
| ClamAV scans | `/var/log/clamav/scan_*.log`, `journalctl -u clamav-scan.service` |
| ClamAV quarantine | `/root/clamav-quarantine/` |
| Signature updates | `journalctl -u clamav-freshclam` |
| Automatic updates | `/var/log/unattended-upgrades/unattended-upgrades.log`, `journalctl -u apt-daily-upgrade.service -u apt-daily.service` (the Telegram report is logged there too) |
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
| Traefik | `/srv/docker/system/traefik/logs/traefik.log` (errors, certificates), `access.log` (requests), the dashboard on `https://proxy.greyroom.net` |
| Vaultwarden | `/srv/docker/app/vaultwarden/logs/vaultwarden.log` (logins, failed logins with the client IP) |
| Immich | `docker-svc logs immich_server` (lost when the container is recreated) |
| OpenCloud | `docker-svc logs opencloud` (JSON, lost when the container is recreated) |
| Paperless | `sudo ls /srv/docker/app/paperless/data/log/` (`paperless.log`, `celery.log`), and *Logs* in its web interface |
| Uptime Kuma | `docker-svc logs uptime-kuma`; each monitor's history in its web interface |
| Container status | `docker-svc ps` |
| Renovate | *Actions → Renovate* on GitHub (one log per run), the Dependency Dashboard issue |
| Backup | `journalctl -u backup.service`, `sudo backup usb snapshots`, `sudo backup s3 snapshots` |
| Errors in the last 24 hours | `journalctl -p err --since -24h` |
