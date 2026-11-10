# Verification

Commands to check each part of the configuration. Run the server-side ones as the admin user over SSH.

## 1. Playbook

```bash
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml --check --diff --ask-vault-pass    # dry run
ansible-playbook site.yml --ask-vault-pass                   # a second run must report changed=0
```

## 2. SSH and sudo

```bash
sudo whoami                       # root, without a password
sudo sshd -T | grep -E '^(port|listenaddress|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowusers|allowtcpforwarding|maxauthtries|loglevel) '
```

Expected: `permitrootlogin no`, `passwordauthentication no`, `allowusers <admin_user>`, `loglevel VERBOSE` and, once `ssh_listen_address` is set, `listenaddress <management IP>:22`.

## 3. Automatic updates

```bash
sudo unattended-upgrade --dry-run -d 2>&1 | grep -i 'allowed origins'
```

Expected: only `codename=trixie-security,label=Debian-Security`.

Telegram report:

```bash
systemctl cat apt-daily-upgrade.service | grep ExecStopPost     # /usr/local/sbin/unattended-upgrades-report upgrade
systemctl cat apt-daily.service | grep ExecStopPost             # ... update
sudo rm -f /var/lib/unattended-upgrades-report/last-run
sudo SERVICE_RESULT=success /usr/local/sbin/unattended-upgrades-report upgrade   # re-sends the last run
sudo SERVICE_RESULT=exit-code EXIT_STATUS=100 /usr/local/sbin/unattended-upgrades-report update   # the failure message
```

Expected: a "✅ UNATTENDED-UPGRADES" message (or "❌ … ERRORS" if the last run had errors), then "❌ APT: PACKAGE LISTS NOT UPDATED". After the next scheduled run (`systemctl list-timers apt-daily-upgrade.timer`), the message arrives by itself.

## 4. Network (after `--tags network`)

```bash
ip -br address
ip rule | grep -E '^(100|200):'
ip route show table 100
ip route show table 200
systemctl is-enabled network-rollback.service    # disabled once the change is confirmed
```

Each address has a `from <address> lookup <table>` rule, and each table holds its subnet and its default route.

## 5. Firewall

```bash
sudo nft list ruleset
journalctl -k -g nft-input-drop --since -1h      # dropped inbound packets
```

## 6. Rootless Docker

```bash
systemctl is-enabled docker.service docker.socket containerd.service   # all disabled
docker-svc info --format '{{.SecurityOptions}}'                         # contains name=rootless
```

Real client IP: Traefik's access log must show the address of the client, not `10.0.2.x` (the rootlesskit network). From a machine on another network, open any service, then on the server:

```bash
sudo tail -n 3 /srv/docker/system/traefik/logs/access.log     # the first field is the client's IP
```

## 7. Notifications

```bash
sudo notify-telegram "Test from $(hostname)"; echo "exit code $?"
```

Exit code 0 and a message on Telegram. Code 1 means Telegram refused the request (check token and chat ID), 2 that the credentials are missing.

## 8. ClamAV

```bash
systemctl is-active clamav-daemon clamav-freshclam
systemctl list-timers clamav-scan.timer
```

Test with the EICAR file, harmless and detected by every antivirus:

```bash
echo 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > ~/eicar.com
sudo systemctl start clamav-scan.service
sudo cat "$(sudo ls -t /var/log/clamav/scan_*.log | head -n 1)"
```

Expected: `eicar.com: Eicar-Signature FOUND`, the file moved to `/root/clamav-quarantine` and a "MALWARE DETECTED" message on Telegram. Clean up:

```bash
sudo rm -f /root/clamav-quarantine/eicar.com
```

## 9. SMART and disk space

On a virtual machine smartmontools is not installed (there is no physical disk to read): skip `smartctl` and test only the disk space check.

```bash
sudo smartctl -H /dev/nvme0n1                    # or /dev/sda
sudo systemctl start disk-space-check.service
systemctl list-timers disk-space-check.timer
```

To test the alert path, lower `disk_space_warn_percent` below the current usage, run `--tags monitoring`, start the check, then restore the value.

## 10. Update job

```bash
ansible-playbook site.yml --tags update-os --ask-vault-pass
```

With `update_os_allow_reboot: false` (prod-srv-01) the job never reboots. To test the report: `sudo touch /run/reboot-required` on the server, run the job, and expect "🔁 UPDATE-OS: REBOOT REQUIRED" on Telegram and no reboot; then `sudo rm /run/reboot-required`.

## 11. Time and integrity check

```bash
timedatectl show --property=NTP --property=NTPSynchronized   # NTP=yes, NTPSynchronized=yes
systemctl list-timers integrity-check.timer
sudo integrity-check; echo "exit code $?"                    # 0 and "nothing found"
```

To test the alert path, plant a fake unpackaged library, run the check, then remove it:

```bash
sudo cp /usr/lib/x86_64-linux-gnu/libkeyutils.so.1.10 /usr/lib/x86_64-linux-gnu/libtest-integrity.so.1
sudo integrity-check     # exit code 1, "shared object not installed by any package", Telegram message
sudo rm /usr/lib/x86_64-linux-gnu/libtest-integrity.so.1
sudo integrity-check     # "nothing found" and "✅ INTEGRITY CHECK: ALL CLEAR" on Telegram
```

## 12. YARA

```bash
sudo yara-scan --compile-only && echo "rules OK"
systemctl list-timers yara-scan.timer
```

Test with the EICAR file (the Elastic rules include it):

```bash
echo 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > /tmp/eicar.com
sudo systemctl start yara-scan.service
sudo sh -c 'cat "$(ls -t /var/log/yara/scan_*.log | head -n 1)"' | grep -v '^error scanning'
rm -f /tmp/eicar.com
```

Expected: `Multi_EICAR_ac8f42d6 /tmp/eicar.com` and a "YARA: 1 MATCH(ES)" message on Telegram. Run it before 00:00, or ClamAV moves the file to the quarantine first, and the quarantine is never scanned by YARA.

## 13. Backup

```bash
systemctl list-timers backup.timer
sudo backup --init                              # "USB: repository exists", "S3: repository exists"
sudo systemctl start backup.service
journalctl -u backup.service -n 15 -o cat       # ✅ BACKUP OK, one line per copy
findmnt /mnt/backup-usb                         # nothing: the disk is unmounted again
```

Restore test, from each copy:

```bash
sudo backup usb restore latest --target /tmp/restore --include /etc/hostname && sudo cat /tmp/restore/etc/hostname
sudo backup s3 restore latest --target /tmp/restore-s3 --include /etc/hostname && sudo cat /tmp/restore-s3/etc/hostname
sudo rm -rf /tmp/restore /tmp/restore-s3
```

To test the failure message, unplug the USB disk and start the backup: `❌ BACKUP FAILED` with "USB disk not connected", and the S3 copy still saved.

## 14. Traefik

On the server:

```bash
docker-svc ps --filter name=traefik --format '{{.Names}} {{.Status}}'    # Up ... (healthy)
sudo grep -iE 'error|acme' /srv/docker/system/traefik/logs/traefik.log | tail   # no errors once the certificate is issued
sudo tail -n 3 /srv/docker/system/traefik/logs/access.log                    # one line per HTTPS request (dashboard included), real client IP
sudo ss -tlnp | grep -E ':(80|443) '                                         # on the services address once it is set
docker-svc network ls --filter label=managed-by=ansible                      # one proxy-<name> per entry in traefik_networks
```

From a client that resolves `proxy.greyroom.net` to the services address:

```bash
curl -sI http://proxy.greyroom.net | head -1                       # 308 to https (a GET gets 301: both are permanent)
curl -sI https://proxy.greyroom.net/dashboard/ | head -1           # 401
curl -s -o /dev/null -w '%{http_code}\n' -u admin https://proxy.greyroom.net/dashboard/   # 200 (GET: with -I the dashboard answers 405)
curl -sI https://proxy.greyroom.net/dashboard/ | grep -i strict-transport                 # HSTS
echo | openssl s_client -connect proxy.greyroom.net:443 -servername proxy.greyroom.net 2>/dev/null | openssl x509 -noout -issuer -ext subjectAltName
```

Expected: issuer Let's Encrypt and `DNS:greyroom.net, DNS:*.greyroom.net`. A second `--tags traefik` run reports `changed=0`.

## 15. Vaultwarden

On the server:

```bash
docker-svc ps --filter name=vaultwarden --format '{{.Names}} {{.Status}}'      # Up ... (healthy)
docker-svc inspect vaultwarden --format '{{range $n, $_ := .NetworkSettings.Networks}}{{$n}} {{end}}'   # proxy-vaultwarden only
docker-svc network inspect proxy-vaultwarden --format '{{range .Containers}}{{.Name}} {{end}}'          # traefik and vaultwarden, nothing else
docker-svc port vaultwarden                                                     # nothing: no published ports
docker-svc inspect vaultwarden --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}}'      # true [ALL]
docker-svc inspect vaultwarden --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E '^(DOMAIN|ROCKET_PORT|SIGNUPS_ALLOWED|PASSWORD_HINTS_ALLOWED|DISABLE_ICON_DOWNLOAD|ADMIN_TOKEN)='
docker-svc exec vaultwarden curl -s -m 5 -o /dev/null https://github.com; echo "exit code $?"           # not 0: no Internet access
sudo tail -n 5 /srv/docker/app/vaultwarden/logs/vaultwarden.log                # "Rocket has launched from http://0.0.0.0:8080", no errors
sudo cat /srv/docker/system/traefik/dynamic/vaultwarden.yml                    # the route to http://vaultwarden:8080
```

Expected environment: `DOMAIN=https://vault.greyroom.net`, `ROCKET_PORT=8080`, `SIGNUPS_ALLOWED=false` (except while creating an account), `PASSWORD_HINTS_ALLOWED=false`, `DISABLE_ICON_DOWNLOAD=true`, and no `ADMIN_TOKEN` line.

Dump and backup:

```bash
sudo /etc/backup/pre.d/vaultwarden                     # "database dumped to .../dump/db.sqlite3": only after integrity_check returned ok
sudo ls -l /srv/docker/app/vaultwarden/dump/           # db.sqlite3, owned by svc-docker
sudo systemctl start backup.service
journalctl -u backup.service -n 15 -o cat              # "✅ Pre-backup scripts: OK" and ✅ BACKUP OK
sudo backup usb ls latest /srv/docker/app/vaultwarden/dump    # the dump is in the snapshot
```

From a client that resolves `vault.greyroom.net` to the services address:

```bash
curl -s https://vault.greyroom.net/alive; echo                                     # a date
curl -sI https://vault.greyroom.net/ | grep -i strict-transport                    # HSTS
curl -s https://vault.greyroom.net/admin | grep -o "disabled, please configure the 'ADMIN_TOKEN'"   # admin page disabled
echo | openssl s_client -connect vault.greyroom.net:443 -servername vault.greyroom.net 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName   # the wildcard
```

By hand, in the web vault or an app:

- **Sign-ups off**: with `vaultwarden_signups_allowed: false`, creating an account with a new address fails with "Registration not allowed or user already exists".
- **Real client IP**: log in once with a wrong master password, then `sudo grep -i incorrect /srv/docker/app/vaultwarden/logs/vaultwarden.log | tail -1` shows the client's address, not a `10.0.2.x` or container address.

A second `--tags vaultwarden` run reports `changed=0`.

## 16. Immich

On the server:

```bash
docker-svc ps --filter name=immich --format '{{.Names}} {{.Status}}'     # immich_server, immich_postgres, immich_redis: Up ... (healthy)
docker-svc inspect immich_server --format '{{range $n, $_ := .NetworkSettings.Networks}}{{$n}} {{end}}'     # immich_backend proxy-immich
docker-svc inspect immich_postgres --format '{{range $n, $_ := .NetworkSettings.Networks}}{{$n}} {{end}}'   # immich_backend only
docker-svc network inspect proxy-immich --format '{{range .Containers}}{{.Name}} {{end}}'                   # traefik and immich_server, nothing else
docker-svc inspect immich_server --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}}'         # true [ALL]
docker-svc port immich_server                                                    # nothing: no published ports
docker-svc exec immich_server curl -s -m 5 -o /dev/null https://github.com; echo "exit code $?"   # not 0: no Internet access
docker-svc logs --since 10m immich_server 2>&1 | grep -E 'ERROR|Machine learning'                 # nothing, once machine learning is off in the settings
sudo cat /srv/docker/system/traefik/dynamic/immich.yml                           # the route to http://immich-server:2283
```

Dump and backup:

```bash
sudo /etc/backup/pre.d/immich                        # "database dumped to .../dump/immich.sql.gz"
sudo ls -l /srv/docker/app/immich/dump/
sudo systemctl start backup.service
journalctl -u backup.service -n 15 -o cat            # "✅ Pre-backup scripts: OK" and ✅ BACKUP OK
sudo backup usb ls latest /srv/docker/app/immich/dump        # the dump is in the snapshot
sudo backup usb ls latest /srv/docker/app/immich | grep -c 'immich/postgres$'   # 0: the live database is left out
```

From a client that resolves `photo.greyroom.net` to the services address:

```bash
curl -s https://photo.greyroom.net/api/server/ping; echo           # {"res":"pong"}
curl -s https://photo.greyroom.net/api/server/version; echo        # {"major":3,"minor":3,"patch":6}
curl -sI https://photo.greyroom.net/ | grep -i strict-transport    # HSTS
```

By hand, in the web app or the mobile app:

- **Upload**: upload a photo and a video longer than one minute from the mobile app over WireGuard. Both appear with a thumbnail; the video plays. A failure after about 60 seconds (error 499 in `access.log`) means the Traefik read timeout is not applied: run `--tags traefik`.
- **No machine learning**: *Administration → Settings → Machine Learning Settings* shows it turned off, and *Administration → Jobs* has no face detection or smart search running.

A second `--tags immich` run reports `changed=0`.
