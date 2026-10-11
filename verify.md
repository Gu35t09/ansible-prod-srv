# 🧪 Guida di Verifica e Testing del Playbook Ansible e del Server Alpine Linux

Questa guida fornisce una procedura passo-passo con i comandi esatti da eseguire per verificare il corretto funzionamento dell'intero sistema: dalla validazione del Playbook Ansible fino al test dei singoli servizi configurati sul server **Alpine Linux** (Doas, SSH, Docker Rootless, ClamAV e notifiche Telegram).

---

## 📋 Indice
1. [Verifica del Playbook Ansible (Da locale / Controller)](#1-verifica-del-playbook-ansible-da-locale--controller)
2. [Verifica Accesso SSH e Elevazione Privilegi Doas](#2-verifica-accesso-ssh-e-elevazione-privilegi-doas)
3. [Verifica Hardening OpenSSH](#3-verifica-hardening-openssh)
4. [Verifica Docker Rootless (`svc-docker`)](#4-verifica-docker-rootless-svc-docker)
5. [Verifica ClamAV e Demoni (`clamd`, `freshclam`)](#5-verifica-clamav-e-demoni-clamd-freshclam)
6. [Test Notifiche Telegram con File di Test Malware (EICAR)](#6-test-notifiche-telegram-con-file-di-test-malware-eicar)

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
Se desideri testare solo un modulo specifico (es. solo ClamAV o solo Docker):

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
Controlla che le regole di hardening impostate da Ansible siano applicate nel file di configurazione di SSH:

```bash
doas grep -E "Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication" /etc/ssh/sshd_config
```
**Output atteso:**
```text
Port 22
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

---

## 4. Verifica Docker Rootless (`svc-docker`)

### 4.1 Verifica Creazione Utente e SubUID/SubGID
Verifica che l'utente `svc-docker` esista e che i range di SubUID/SubGID siano configurati correttamente:

```bash
id svc-docker
cat /etc/subuid
cat /etc/subgid
```
**Output atteso:**
Presenza delle righe `svc-docker:100000:65536` nei file `/etc/subuid` e `/etc/subgid`.

### 4.2 Verifica del Servizio OpenRC per Docker Rootless
Verifica lo stato del servizio `docker-rootless`:

```bash
doas rc-service docker-rootless status
```
**Output atteso:**
`status: started`

### 4.3 Test Esecuzione Container Docker come Utente `svc-docker`
Passa all'utente `svc-docker` ed esegui un container di test:

```bash
# Passa all'utente svc-docker caricando il suo ambiente (.bashrc)
doas -u svc-docker -i bash

# Assicurati che le variabili d'ambiente Rootless siano impostate
export XDG_RUNTIME_DIR="/run/user/1001"
export DOCKER_HOST="unix:///run/user/1001/docker.sock"

# Verifica le informazioni di Docker Rootless
docker info

# Esegui un container di test
docker run --rm hello-world

# Esci dalla shell dell'utente svc-docker
exit
```
**Output atteso:**
Il messaggio `Hello from Docker!` confermerà che il demone Docker Rootless è perfettamente operativo.

> 💡 **Nota Risoluzione Problemi Docker Rootless:**
> Se `docker info` restituisce l'errore `failed to connect to the docker API at unix:///var/run/docker.sock`, significa che `DOCKER_HOST` non è impostato sulla socket Rootless dell'utente (`unix:///run/user/1001/docker.sock`). Inoltre, se il servizio OpenRC `docker-rootless` non risulta avviato, eseguibile da root:
> ```bash
> doas rc-service docker-rootless restart
> ```

---

## 5. Verifica ClamAV e Demoni (`clamd`, `freshclam`)

### 5.1 Verifica dello Stato dei Servizi ClamAV
```bash
doas rc-service clamd status
doas rc-service freshclam status
```
**Output atteso:**
Entrambi i servizi devono risultare in stato `started`.

### 5.2 Verifica del Cron Job per la Scansione Schedulata
Verifica che il job Cron sia presente nel crontab di root:

```bash
doas crontab -l
```
**Output atteso:**
Presenza della riga:
`0 2 * * 0 /usr/local/bin/clamav_scan_telegram.sh > /dev/null 2>&1`

### 5.3 Esecuzione Manuale dello Script di Scansione
Esegui manualmente lo script generato da Ansible:

```bash
doas /usr/local/bin/clamav_scan_telegram.sh
```

Verifica il file di log appena generato in `/var/log/clamav/`:

```bash
doas cat $(ls -t /var/log/clamav/scan_*.log | head -n 1)
```
**Output atteso:**
Log dettagliato della scansione terminante con `Scansione completata. Nessuna minaccia rilevata.`

---

## 6. Test Notifiche Telegram con File di Test Malware (EICAR)

Per verificare che lo script rilevi correttamente le minacce e invii l'avviso formattato su Telegram, utilizziamo la stringa di test standard **EICAR** (un file di test innocuo riconosciuto da tutti gli antivirus).

### 6.1 Creazione del File di Test EICAR
Crea un file temporaneo con la firma EICAR in un percorso scansionato da ClamAV (es. `/home/svc-docker`):

```bash
echo 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' | doas tee /home/svc-docker/eicar.com
```

### 6.2 Esecuzione della Scansione e Verifica Notifica Telegram
Lancia lo script di scansione:

```bash
doas /usr/local/bin/clamav_scan_telegram.sh
```

**Esito atteso:**
1. Lo script termina con codice di uscita `1` (indicante minaccia trovata).
2. Riceverai immediatamente un messaggio sul tuo canale/chat Telegram configurato, simile a:

> ⚠️ **ALLERTA MALWARE CLAMAV** ⚠️
>
> 🖥️ **Server:** `alpine-node-01`
> 🦠 **File Infetti Rilevati:** `1`
> 🛠️ **Azione Eseguita:** `notify_only`
> 📁 **Percorsi Scansionati:** `/home/svc-docker /etc /var`
>
> 📋 **Dettagli Report:**
> ... `Eicar-Signature FOUND` ...

### 6.3 Pulizia del File di Test
Al termine della verifica, rimuovi il file di test EICAR:

```bash
doas rm -f /home/svc-docker/eicar.com
```

Verifica che rieseguendo la scansione non vengano più rilevate minacce:

```bash
doas /usr/local/bin/clamav_scan_telegram.sh
```
