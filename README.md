# Alpine Linux Server Setup & Maintenance Ansible Playbook

Questo repository contiene un playbook Ansible completo e modulare per la configurazione iniziale, l'hardening e la manutenzione periodica di un server **Alpine Linux** posizionato dietro un firewall OPNsense e dedicato all'hosting di container Docker.

---

## 🏗️ Struttura del Progetto

```text
.
├── ansible.cfg                    # Configurazione Ansible (privilegi doas, callbacks)
├── inventory.ini                  # Inventario dei server Alpine target
├── main.yml                       # Playbook principale
├── vars/
│   └── main.yml                   # Variabili di configurazione (Utenti, SSH, Telegram Bot)
├── tasks/
│   ├── setup.yaml                 # Configurazione iniziale pacchetti e repository
│   ├── hardening.yaml             # Hardening SSH e configurazione doas
│   ├── docker.yaml                # Installazione Docker Rootless e utente svc-docker
│   ├── clamav.yaml                # Installazione ClamAV, clamd daemon e Cron
│   └── update.yaml                # Aggiornamenti periodici di sistema
└── templates/
    └── clamav_scan_telegram.sh.j2 # Template script di scansione con notifiche Telegram
```

---

## 🚀 Caratteristiche Principali

1. **Configurazione Iniziale e Hardening Semplice:**
   - Abilitazione repository Alpine `community` e `main`.
   - Privilegi elevati via `doas` invece del pesante `sudo`.
   - Accesso SSH limitato: disabilitato il login `root` diretto e forzata l'autenticazione tramite chiavi SSH (porta 22).

2. **Docker Rootless (`svc-docker`):**
   - Installazione di Docker, `docker-compose` e `docker-buildx`.
   - Esecuzione di Docker in **modalità Rootless** sotto l'utente dedicato `svc-docker` con subuid/subgid mappati, garantendo massima sicurezza nel caso un container venisse compromesso.

3. **ClamAV & Notifiche Telegram:**
   - Demone `clamd` e `freshclam` in background per l'aggiornamento continuo delle firme virus in RAM.
   - Script di scansione programmato via Cron (es. ogni settimana) configurato in `templates/clamav_scan_telegram.sh.j2`.
   - Invio automatico di un avviso formattato in Markdown su Telegram se vengono rilevate minacce.
   - Opzioni personalizzabili in `vars/main.yml`: `notify_only`, `quarantine`, oppure `remove`.

4. **Integrazione con Ansible Semaphore:**
   - I task utilizzano i **Tags** di Ansible per permettere l'esecuzione selettiva su Semaphore:
     - `--tags setup`: Esegue setup iniziale e pacchetti.
     - `--tags hardening`: Configura SSH e doas.
     - `--tags docker`: Configura Docker Rootless.
     - `--tags clamav`: Configura antivirus e script notifiche Telegram.
     - `--tags update`: Esegue gli aggiornamenti di sistema e pacchetti (`apk update && apk upgrade`).

---

## 🛠️ Come Usare il Playbook

### 1. Configurazione Variabili
Modifica il file `vars/main.yml`:
- Inserisci le tue chiavi SSH pubbliche in `admin_ssh_keys`.
- Configura il `telegram_bot_token` e il `telegram_chat_id` per le notifiche ClamAV.

### 2. Configurazione Inventario
Aggiorna `inventory.ini` con l'indirizzo IP del tuo server Alpine:
```ini
[alpine_servers]
alpine-node-01 ansible_host=192.168.1.100 ansible_user=admin
```

### 3. Esecuzione via CLI

**Esecuzione completa (setup, hardening, docker, clamav):**
```bash
ansible-playbook -i inventory.ini main.yml
```

**Esecuzione solo degli aggiornamenti periodici (es. schedulata su Semaphore):**
```bash
ansible-playbook -i inventory.ini main.yml --tags update
```
