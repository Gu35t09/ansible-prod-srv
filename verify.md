# 🧪 Guida di Verifica e Testing del Playbook Ansible e del Server Alpine Linux

Questa guida fornisce una procedura passo-passo con i comandi esatti da eseguire per verificare il corretto funzionamento dell'intero sistema: dalla validazione del Playbook Ansible fino al test dei singoli servizi configurati sul server **Alpine Linux** (Doas, SSH, ClamAV e notifiche Telegram).

---

## 📋 Indice
1. [Verifica del Playbook Ansible (Da locale / Controller)](#1-verifica-del-playbook-ansible-da-locale--controller)
2. [Verifica Accesso SSH e Elevazione Privilegi Doas](#2-verifica-accesso-ssh-e-elevazione-privilegi-doas)
3. [Verifica Hardening OpenSSH](#3-verifica-hardening-openssh)
4. [Verifica ClamAV e Demoni (`clamd`, `freshclam`)](#4-verifica-clamav-e-demoni-clamd-freshclam)
5. [Test Notifiche Telegram con File di Test Malware (EICAR)](#5-test-notifiche-telegram-con-file-di-test-malware-eicar)

---

## 1. Verifica del Playbook Ansible (Da locale / Controller)

Prima di applicare le modifiche o per testare le sintassi locali, esegui i seguenti comandi dalla radice della repository.

### 1.1 Verifica Sintattica del Playbook
Verifica che la sintassi YAML e le direttive Ansible siano corrette:

```bash
ansible-playbook -i inventory.ini main.yml --syntax-check
```
**Output atteso:**
`playbook: main.yml` (senza errori di sintassi).

### 1.2 Esecuzione in Modalità Check (Dry-Run)
Simula l'esecuzione del playbook senza apportare modifiche reali al server target:

```bash
ansible-playbook -i inventory.ini main.yml --check --ask-vault-pass
```

### 1.3 Esecuzione di Tag Specifici
Se desideri testare solo un modulo specifico (es. solo ClamAV):

```bash
# Esempio: Esecuzione del solo tag clamav
ansible-playbook -i inventory.ini main.yml --tags clamav --ask-vault-pass
```

---

## 2. Verifica Accesso SSH e Elevazione Privilegi Doas

Connettiti via SSH al server Alpine Linux con l'utente amministrativo configurato (`admin_user` in `vars/main.yml`, es. `v`).

### 2.1 Connessione SSH tramite Chiave Pubblica
```bash
ssh -p 22 v@<IP_DEL_SERVER>
```

### 2.2 Test Elevazione Privilegi con `doas`
Verifica che l'utente possa elevarsi a `root` senza richiedere password (come configurato in `/etc/doas.d/doas.conf`):

```bash
doas whoami
```
**Output atteso:**
`root`

---

## 3. Verifica Hardening OpenSSH

### 3.1 Verifica dello Stato del Servizio SSH
```bash
doas rc-service sshd status
```
**Output atteso:**
`status: started`

### 3.2 Verifica Direttive di Sicurezza
L'hardening è nel drop-in `/etc/ssh/sshd_config.d/00-hardening.conf`. Controlla la configurazione **effettiva** di sshd (dopo l'unione di tutti i file):

```bash
doas sshd -T | grep -E "^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|allowusers|maxauthtries) "
```
**Output atteso:**
```text
port 22
permitrootlogin no
pubkeyauthentication yes
passwordauthentication no
kbdinteractiveauthentication no
maxauthtries 3
allowusers v
```

---

## 4. Verifica ClamAV e Demoni (`clamd`, `freshclam`)

### 4.1 Verifica dello Stato dei Servizi ClamAV
```bash
doas rc-service clamd status
doas rc-service freshclam status
```
**Output atteso:**
Entrambi i servizi devono risultare in stato `started`.

### 4.2 Verifica del Cron Job per la Scansione Schedulata
Verifica che il demone `crond` sia attivo e che il job sia presente nel crontab di root:

```bash
doas rc-service crond status
doas crontab -l
```
**Output atteso:**
`status: started` e la riga (con lo schedule di default `clamav_scan_schedule_cron: "0 0 * * *"`):
`0 0 * * * /usr/local/bin/clamav_scan_telegram.sh > /dev/null 2>&1`

### 4.3 Esecuzione Manuale dello Script di Scansione
Esegui manualmente lo script generato da Ansible:

```bash
doas /usr/local/bin/clamav_scan_telegram.sh
```

Verifica il file di log appena generato in `/var/log/clamav/`:

```bash
doas cat $(ls -t /var/log/clamav/scan_*.log | head -n 1)
```
**Output atteso:**
1. Log dettagliato della scansione terminante con `Scansione completata. Nessuna minaccia rilevata.`
2. Ricezione di una notifica su Telegram con l'esito:
   > ✅ SCANSIONE CLAMAV COMPLETATA - PULITA
   >
   > 🖥️ Server: alpine-node-01
   > 🦠 File infetti rilevati: 0
   > 📁 Percorsi scansionati: /home/v /etc /var /srv /tmp

Se la notifica non arriva, nel log è presente la riga `ERRORE: invio della notifica Telegram fallito.` con il dettaglio dell'errore di curl.

---

## 5. Test Notifiche Telegram con File di Test Malware (EICAR)

Per verificare che lo script rilevi correttamente le minacce e invii l'avviso formattato su Telegram, utilizziamo la stringa di test standard **EICAR** (un file di test innocuo riconosciuto da tutti gli antivirus).

### 5.1 Creazione del File di Test EICAR
Crea un file temporaneo con la firma EICAR in un percorso scansionato da ClamAV (es. `/home/v`):

```bash
echo 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' | doas tee /home/v/eicar.com
```

### 5.2 Esecuzione della Scansione e Verifica Notifica Telegram
Lancia lo script di scansione:

```bash
doas /usr/local/bin/clamav_scan_telegram.sh
```

**Esito atteso:**
1. Lo script termina con codice di uscita `1` (indicante minaccia trovata).
2. Riceverai immediatamente un messaggio sul tuo canale/chat Telegram configurato, simile a:

> ⚠️ ALLERTA MALWARE CLAMAV ⚠️
>
> 🖥️ Server: alpine-node-01
> 🦠 File infetti rilevati: 1
> 🛠️ Azione eseguita: quarantine
> 📁 Percorsi scansionati: /home/v /etc /var /srv /tmp
>
> 📋 File rilevati (max 20):
> /home/v/eicar.com: Eicar-Signature FOUND

Con `clamav_action_on_detect: quarantine` (default) il file viene spostato in `/root/clamav-quarantine`.

### 5.3 Pulizia del File di Test
Al termine della verifica, rimuovi il file di test EICAR (dalla quarantena, se l'azione è `quarantine`):

```bash
doas rm -f /home/v/eicar.com /root/clamav-quarantine/eicar.com
```

Verifica che rieseguendo la scansione non vengano più rilevate minacce:

```bash
doas /usr/local/bin/clamav_scan_telegram.sh
```
