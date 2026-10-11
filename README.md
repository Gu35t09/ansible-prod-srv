# Alpine Linux Server Setup & Maintenance Ansible Playbook

Questo repository contiene un playbook Ansible completo e modulare per la configurazione iniziale, l'hardening e la manutenzione periodica di un server **Alpine Linux** posizionato dietro un firewall OPNsense.

---

## 🏗️ Struttura del Progetto

```text
.
├── ansible.cfg                    # Configurazione Ansible (privilegi doas, callbacks)
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
    └── clamav_scan_telegram.sh.j2 # Template script di scansione con notifiche Telegram
```

---

## 🔐 Gestione Variabili Sensibili con Ansible Vault

I dati riservati come **Bot Token Telegram** e **Chat ID** sono memorizzati nel file `vars/vault.yml`.

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
   - Abilitazione repository Alpine `community` e `main`.
   - Privilegi elevati via `doas` invece del pesante `sudo`.
   - Accesso SSH limitato: disabilitato il login `root` diretto e forzata l'autenticazione tramite chiavi SSH (porta 22).

2. **ClamAV & Notifiche Telegram:**
   - Demone `clamd` e `freshclam` in background per l'aggiornamento continuo delle firme virus in RAM.
   - Script di scansione programmato via Cron (es. ogni settimana) configurato in `templates/clamav_scan_telegram.sh.j2`.
   - Invio automatico di un avviso formattato in Markdown su Telegram se vengono rilevate minacce.
   - Opzioni personalizzabili in `vars/main.yml`: `notify_only`, `quarantine`, oppure `remove`.

3. **Integrazione con Ansible Semaphore:**
   - In Semaphore, aggiungi la password di Ansible Vault nelle credenziali/environment del Key Store.
   - I task utilizzano i **Tags** di Ansible per permettere l'esecuzione selettiva su Semaphore:
     - `--tags setup`: Esegue setup iniziale e pacchetti.
     - `--tags hardening`: Configura SSH e doas.
     - `--tags clamav`: Configura antivirus e script notifiche Telegram.
     - `--tags update`: Esegue gli aggiornamenti di sistema e pacchetti (`apk update && apk upgrade`).

---

## 🛠️ Come Usare il Playbook

### 1. Configurazione Variabili e Vault
- Modifica `vars/main.yml` (es. `admin_ssh_keys`).
- Configura `vars/vault.yml` con il tuo Token Telegram e Chat ID, quindi cripta il file:
  ```bash
  ansible-vault encrypt vars/vault.yml
  ```

### 2. Configurazione Inventario
Aggiorna `inventory.ini` con l'indirizzo IP del tuo server Alpine:
```ini
[alpine_servers]
alpine-node-01 ansible_host=192.168.1.100 ansible_user=admin
```

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
