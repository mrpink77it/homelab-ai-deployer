# Guida Preparazione Sandbox Bare Metal / VM Generica

Questa guida descrive i passaggi per preparare un server fisico (**Bare Metal**) o una Macchina Virtuale generica (ESXi, VirtualBox, KVM, Hyper-V) da utilizzare come **Sandbox di Esecuzione** tramite l'Opzione 4 dell'**Homelab AI Deployer**.

---

## 📋 Requisiti Minimi
Per consentire la configurazione automatica delle chiavi SSH e l'esecuzione di codice remoto tramite l'API Code Runner (`:9000`), la Sandbox deve soddisfare i seguenti requisiti:
- Sistema Operativo: **Debian 13 (Trixie)** o **Ubuntu 24.04 LTS (Noble)**
- Server SSH attivo (`openssh-server`)
- Accesso SSH Root abilitato (`PermitRootLogin yes`)
- Interprete Python 3 installato (`python3`)
- Connettività di rete raggiungibile dal Controller Homelab AI

---

## 🖥️ Procedura di Installazione e Configurazione

### 1. Installazione del Sistema Operativo
1. Scarica l'ISO ufficiale ed installa **Debian 13** o **Ubuntu Server 24.04 LTS** sulla tua macchina fisica o VM.
2. Durante la fase di installazione guidata:
   * Imposta la password per l'utente `root` oppure crea un utente con privilegi `sudo`.
   * Seleziona l'installazione del pacchetto **OpenSSH Server** (se richiesto/disponibile).

### 2. Configurazione Post-Installazione
Accedi alla console del server Bare Metal (o tramite SSH) come utente **root** (oppure passa a root con `sudo su`) ed esegui questo comando unificato:

```bash
apt update && apt install -y openssh-server python3 && sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && systemctl restart ssh
```

### 3. Recupero dell'Indirizzo IP
Ottieni l'indirizzo IP di rete della macchina appena configurata:

```bash
hostname -I | awk '{print $1}'
```

---

## 🛠️ Cosa fa il comando di configurazione:

1. **Aggiorna APT**: Aggiorna l'indice dei pacchetti disponibili (`apt update`).
2. **Installa Dipendenze**: Installa `openssh-server` per la gestione SSH remota e `python3` per l'esecuzione degli script inviati dal Controller.
3. **Abilita Accesso Root**: Configura la direttiva `PermitRootLogin yes` nel file `/etc/ssh/sshd_config`.
4. **Riavvia il Servizio**: Riavvia il demone `ssh` per applicare immediatamente le modifiche.

---

## 🎯 Prossimi Passi

1. Prendi nota dell'indirizzo IP della Sandbox appena ottenuto.
2. Torna sul server Controller dove risiede l'**Homelab AI Deployer**.
3. Avvia lo script di gestione:

```bash
./manager.sh
```

4. Seleziona la voce `4) CONFIGURA Sandbox`.
5. Inserisci l'IP della Sandbox quando richiesto:
   * Lo script genererà e invierà la chiave SSH ed25519 tramite `ssh-copy-id`.
   * Verrà verificato il funzionamento del servizio via API Code Runner sulla porta `9000`.
