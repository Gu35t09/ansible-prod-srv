# Sentinel Journal

## 2025-02-17 - SSH and Script Security Hardening for Alpine Ansible Playbook
**Vulnerability:** Default SSH server configs without strict brute-force limits, `host_key_checking = False` in `ansible.cfg` allowing MitM risks, and unencoded parameters in shell script curl requests for Telegram webhooks.
**Learning:** Ansible playbooks managing server infrastructure and Telegram alerts must strictly validate SSH host identities, restrict SSH authentication attempts/timeouts, and safely URL-encode dynamic notification payloads to prevent parameter injection and unintended execution failures.
**Prevention:** Always enforce `host_key_checking = True` for Ansible, configure explicit SSH `MaxAuthTries` and `ClientAliveInterval`, and use `curl --data-urlencode` for webhook parameters.
