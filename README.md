# Homelab AI Deployer

> **`mrpink77it/homelab-ai-deployer`** è uno script Bash automatizzato ("zero-config") progettato per configurare, gestire e distribuire un ambiente completo di AI Generativa, LLM Fine-Tuning e sviluppo su macchine Linux e container **Proxmox LXC**.

---

## Avvio Rapido

### Setup del Controller AI (Host Principale)

```bash
git clone [https://github.com/mrpink77it/homelab-ai-deployer.git](https://github.com/mrpink77it/homelab-ai-deployer.git)
cd homelab-ai-deployer
chmod +x manager.sh sandbox_setup.sh setup_jupyter.sh
sudo ./manager.sh
```

---

## Gestione ed Installazione JupyterLab (`setup_jupyter.sh`)

Lo script `setup_jupyter.sh` fornisce una procedura di configurazione e verifica intelligente per **JupyterLab**, eseguibile in modo autonomo sia su container LXC che su macchine virtuali o Baremetal.

### Funzionamento dello Script (Idempotente):
1. **Controllo Presenza**: Verifica se JupyterLab è già presente nell'ambiente `/opt/jupyter_env` e se il servizio `systemd` esiste.
2. **Se Già Installato**: Assicura che il demone `jupyter.service` sia attivo (lo riavvia se fermo), recupera l'IP della macchina e il token di autenticazione corrente e stampa a schermo le istruzioni di collegamento.
3. **Se Non Installato**:
   * Crea un ambiente virtuale Python dedicato in `/opt/jupyter_env`.
   * Installa le dipendenze e l'ultima versione di JupyterLab.
   * Crea e abilita il servizio `systemd` (`jupyter.service`) impostando come cartella di lavoro `/root/notebooks`.
   * Avvia il servizio e genera l'URL completo di token per il primo accesso.

```bash
# Esecuzione diretta dello script di gestione JupyterLab:
chmod +x setup_jupyter.sh
sudo ./setup_jupyter.sh
```

---

## Architettura Sandbox & Provisioning (`sandbox_setup.sh`)

L'architettura separa nettamente il **Controller AI** (dove girano i modelli, le interfacce e la GPU) dal **Nodo Sandbox** (LXC/VM separata) dove viene eseguito il codice generato dall'AI in un contesto confinato.

```text
+---------------------------------+             SSH             +---------------------------------+
|         CONTROLLER AI           |---------------------------->|          SANDBOX LXC/VM         |
|  - Unsloth Studio (Porta 8888)  |   Exec: python3 -c "..."    |  - Configurato da               |
|  - OpenCode AI    (Porta 8000)  |                             |    sandbox_setup.sh             |
|  - Code Runner    (Porta 9000)  |<----------------------------|  - Python 3 / OpenSSH            |
+---------------------------------+       stdout / stderr       +---------------------------------+
```

### Configurazione del Nodo Sandbox (In 2 Passaggi)

Per predisporre un nuovo container LXC o VM da utilizzare come Sandbox isolata:

#### 1. Prepara il Nodo Sandbox
Esegui lo script `sandbox_setup.sh` all'interno del container/VM destinato a fare da Sandbox per installare le dipendenze minimali (Python 3, OpenSSH Server) e configurare le regole SSH:

```bash
# Esegui sulla macchina Sandbox:
curl -fsSL [https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/sandbox_setup.sh](https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/sandbox_setup.sh) | sudo bash
```

#### 2. Associa Controller -> Sandbox
Dal Controller AI, genera ed invia la chiave SSH verso l'IP della Sandbox:

```bash
# 1. Genera la chiave SSH sul Controller (se non presente)
ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519

# 2. Autorizza la chiave sul nodo Sandbox
ssh-copy-id -i /root/.ssh/id_ed25519.pub root@<IP_SANDBOX>

# 3. Test di esecuzione via API Code Runner (:9000)
curl -X POST http://localhost:9000/execute \
  -H "Content-Type: application/json" \
  -d '{
    "code": "import sys, platform; print(f\"Sandbox attiva! OS: {platform.system()} - Python: {sys.version}\")",
    "sandbox_ip": "<IP_SANDBOX>"
  }'
```

---

## Opzioni del Menu `manager.sh`

Eseguendo `./manager.sh` si accederà al menu interattivo TUI:

* **`1) INSTALLA Servizi`**: Installazione automatica completa (Driver GPU, CUDA Toolkit, Unsloth, OpenCode AI, Code Runner API).
* **`2) VERIFICA Stato`**: Controllo dello stato dei servizi `systemd` e della disponibilità GPU via PyTorch/CUDA.
* **`3) AGGIORNA Componenti`**: Git pull e aggiornamento dipendenze per OpenCode AI e Unsloth.
* **`4) CONFIGURA Sandbox`**: Helper interattivo per la gestione ed il test dell'endpoint API remota.
* **`5) DISINSTALLA`**: Rimozione completa delle directory, configurazioni ed unità `systemd`.

---

## Gestione Storage e Modelli

Per evitare di esaurire lo spazio sul disco root dell'LXC, le directory principali di lavoro e di cache dei modelli sono organizzate come segue:

* **Cache Modelli HuggingFace / Unsloth**: `~/.cache/huggingface/hub`
* **Ambiente Virtuale Python (`uv`)**: `/root/unsloth_env`
* **Ambiente Virtuale JupyterLab**: `/opt/jupyter_env/`
* **Cartella di Lavoro Notebook**: `/root/notebooks/`
* **Servizio Code Runner**: `/opt/code_runner/`

---

## Verifica e Gestione Servizi

Dopo il completamento dello script, puoi verificare il corretto riconoscimento della GPU e di CUDA eseguendo:

```bash
/root/unsloth_env/bin/python3 -c "import torch; print('CUDA disponibile:', torch.cuda.is_available()); print('GPU:', torch.cuda.get_device_name(0))"
```

### Gestione tramite Systemd

Puoi controllare i singoli servizi tramite `systemctl`:

* **JupyterLab Server**: `systemctl status jupyter.service`
* **Unsloth Studio**: `systemctl status unsloth-studio.service`
* **OpenCode AI**: `systemctl status opencode.service`
* **Code Runner API**: `systemctl status code-runner.service`

---

## Risoluzione Problemi (FAQ)

<details>
<summary><b><code>nvidia-smi</code> funziona nell'LXC ma PyTorch restituisce <code>CUDA available: False</code></b></summary>

Assicurati che i permessi dei device `/dev/nvidia*` all'interno del container siano corretti. Esegui:
```bash
chmod 666 /dev/nvidia*
```
Se usi un container **Unprivileged**, verifica che i permessi UID/GID tra Host e LXC siano mappati correttamente per i nodi `/dev/nvidia*`.
</details>

<details>
<summary><b>Come recuperare il token di JupyterLab se smarrito?</b></summary>

Ti basterà rieseguire lo script `./setup_jupyter.sh` oppure lanciare direttamente il comando:
```bash
/opt/jupyter_env/bin/jupyter server list
