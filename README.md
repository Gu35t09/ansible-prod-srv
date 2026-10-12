# Alpine Linux Server Setup & Maintenance Ansible Playbook

Questo repository contiene un playbook Ansible completo e modulare per la configurazione iniziale, l'hardening e la manutenzione periodica di un server **Alpine Linux** posizionato dietro un firewall OPNsense.

---

## 🏗️ Struttura del Progetto

```text
.
├── .gitignore                     # Esclude password vault, file temporanei e log locali
├── ansible.cfg                    # Configurazione Ansible (privilegi doas)
├── inventory.ini                  # Inventario dei server Alpine target
├── main.yml                       # Playbook principale
├── vars/
│   ├── main.yml                   # Variabili di configurazione generale
│   ├── vault.yml                  # Variabili riservate/sensibili gestite con Ansible Vault
│   └── vault.yml.example          # Esempio di file vault in chiaro
├── tasks/
│   ├── setup.yaml                 # Configurazione iniziale pacchetti e repository
│   ├── hardening.yaml             # Hardening SSH e configurazione doas
│   ├── clamav.yaml                # Installazione ClamAV, clamd daemon e Cron
│   └── update.yaml                # Aggiornamenti periodici di sistema
└── templates/
    ├── clamav_scan_telegram.sh.j2 # Template script di scansione con notifiche Telegram
    └── sshd_hardening.conf.j2     # Drop-in di hardening OpenSSH (/etc/ssh/sshd_config.d/)
```

---

## 🔐 Gestione Variabili Sensibili con Ansible Vault

I dati riservati come **Bot Token Telegram** e **Chat ID** sono memorizzati nel file `vars/vault.yml`.

> ⚠️ `vars/vault.yml` va committato **solo criptato** (deve iniziare con `$ANSIBLE_VAULT;`). La password del vault (`.vault_pass`) non va mai nel repository ed è esclusa da `.gitignore`.

### Criptare il file vault:
```bash
ansible-vault encrypt vars/vault.yml
```

### Modificare un file vault criptato:
```bash
ansible-vault edit vars/vault.yml
```

### Decriptare temporaneamente per ispezione:
```bash
ansible-vault decrypt vars/vault.yml
```

---

## 🚀 Caratteristiche Principali

1. **Configurazione Iniziale e Hardening Semplice:**
   - Abilitazione repository Alpine `community`.
   - Privilegi elevati via `doas` (senza password) concessi al solo `admin_user`, con validazione della sintassi prima della scrittura.
   - Accesso SSH limitato tramite drop-in `/etc/ssh/sshd_config.d/00-hardening.conf` validato con `sshd -t`: login `root` disabilitato, solo chiavi SSH, `AllowUsers` limitato ad `admin_user`.
   - Il playbook si interrompe se `admin_ssh_keys` è vuota o se `ansible_user` è diverso da `admin_user`, per non perdere l'accesso al server.

2. **ClamAV & Notifiche Telegram:**
   - Demone `clamd` e `freshclam` in background per l'aggiornamento continuo delle firme virus in RAM.
   - Script di scansione (`/usr/local/bin/clamav_scan_telegram.sh`, permessi `0700` perché contiene il token) programmato via `crond` secondo `clamav_scan_schedule_cron` (default: ogni giorno alle 00:00).
   - Invio automatico di una notifica in testo semplice su Telegram al termine di ogni scansione (`✅ SCANSIONE CLAMAV COMPLETATA - PULITA`, `⚠️ ALLERTA MALWARE CLAMAV` con l'elenco dei file rilevati, o `❌ ERRORE SCANSIONE CLAMAV`). Il token non compare mai nella lista dei processi.
   - Opzioni personalizzabili in `vars/main.yml`: `notify_only`, `quarantine`, oppure `remove`.
   - La quarantena (`clamav_quarantine_dir`, default `/root/clamav-quarantine`, permessi `0700`) deve stare fuori dai percorsi scansionati: il playbook lo verifica.
   - I log `scan_*.log` più vecchi di `clamav_log_retention_days` (default 30) vengono eliminati automaticamente.

3. **Integrazione con Ansible Semaphore:**
   - In Semaphore, aggiungi la password di Ansible Vault nelle credenziali/environment del Key Store.
   - I task utilizzano i **Tags** di Ansible per permettere l'esecuzione selettiva su Semaphore:
     - `--tags setup`: Esegue setup iniziale e pacchetti.
     - `--tags hardening`: Configura SSH e doas.
     - `--tags clamav`: Configura antivirus e script notifiche Telegram.
     - `--tags update`: Esegue gli aggiornamenti di sistema e pacchetti (`apk update && apk upgrade`); `clamd` viene riavviato solo se sono stati aggiornati pacchetti.
   - I task sono importati con `import_tasks` (statico): è necessario perché i tag vengano ereditati dai task importati.

---

## 🛠️ Come Usare il Playbook

### 1. Configurazione Variabili e Vault
- Modifica `vars/main.yml` (es. `admin_user`, `admin_ssh_keys`, `system_timezone`).
- Configura `vars/vault.yml` con il tuo Token Telegram e Chat ID, quindi cripta il file:
  ```bash
  ansible-vault encrypt vars/vault.yml
  ```

### 2. Configurazione Inventario
Aggiorna `inventory.ini` con l'indirizzo IP del tuo server Alpine. `ansible_user` deve coincidere con `admin_user`:
```ini
[alpine_servers]
alpine-node-01 ansible_host=192.168.1.100 ansible_user=v
```

> **Primo avvio (bootstrap):** il playbook usa `doas` per elevare i privilegi, quindi sul server deve già esistere l'utente `admin_user` con la tua chiave SSH, il pacchetto `doas` installato e una regola `permit nopass <admin_user>` in `/etc/doas.d/doas.conf`. Dalla prima esecuzione in poi la configurazione è gestita dal playbook.

### 3. Esecuzione via CLI

**Esecuzione completa chiedendo la password di Ansible Vault:**
```bash
ansible-playbook -i inventory.ini main.yml --ask-vault-pass
```

**Esecuzione usando un file password Vault (utile in automazioni/Semaphore):**
```bash
ansible-playbook -i inventory.ini main.yml --vault-password-file .vault_pass
```

**Esecuzione solo degli aggiornamenti periodici:**
```bash
ansible-playbook -i inventory.ini main.yml --tags update --ask-vault-pass
```

---

## 🧪 Testing e Verifica dei Servizi

Per la guida completa passo-passo con tutti i comandi necessari per verificare il Playbook Ansible e i componenti del server Alpine Linux (Doas, SSH, ClamAV e test notifiche Telegram con firma EICAR), fai riferimento a:
👉 **[verify.md](verify.md)**
