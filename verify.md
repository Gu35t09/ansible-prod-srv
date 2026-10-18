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
sudo sshd -T | grep -E '^(port|listenaddress|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowusers|allowtcpforwarding|maxauthtries) '
```

Expected: `permitrootlogin no`, `passwordauthentication no`, `allowusers <admin_user>` and, once `ssh_listen_address` is set, `listenaddress <management IP>:22`.

## 3. Automatic updates

```bash
sudo unattended-upgrade --dry-run -d 2>&1 | grep -i 'allowed origins'
```

Expected: only `codename=trixie-security,label=Debian-Security`.

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

Real client IP check (from a machine on another network):

```bash
docker-svc run -d --rm --name whoami -p <services IP>:80:80 traefik/whoami:v1.10
curl http://<services IP>/ | grep RemoteAddr      # shows the client's address, not 10.0.2.x
docker-svc stop whoami
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

A reboot happens only when needed. To test the reboot path: `sudo touch /run/reboot-required` on the server, then run the job. After the reboot the play checks that the rootless Docker daemon is running again.
