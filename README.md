# Homelab AI Deployer

> **`mrpink77it/homelab-ai-deployer`** è uno script Bash automatizzato ("zero-config") progettato per configurare, gestire e distribuire un ambiente completo di AI Generativa, LLM Fine-Tuning e sviluppo su macchine Linux e container **Proxmox LXC**.

---

## Avvio Rapido

### Setup del Controller AI (Host Principale)

```bash
sudo apt install git
git clone [https://github.com/mrpink77it/homelab-ai-deployer.git](https://github.com/mrpink77it/homelab-ai-deployer.git)
cd homelab-ai-deployer
sudo chmod +x manager.sh sandbox_setup.sh setup_jupyter.sh
sudo ./manager.sh
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
```
</details>

<details>
<summary><b>Errore di connessione SSH verso la Sandbox</b></summary>

Verifica che lo script `sandbox_setup.sh` sia stato eseguito sul nodo Sandbox e che il servizio SSH sia attivo (`systemctl status ssh`). Assicurati che l'IP del nodo Sandbox sia raggiungibile dal Controller via ping/SSH.
</details>

<details>
<summary><b>Errore di memoria durante il caricamento dei modelli LLM</b></summary>

Per l'inferenza e il fine-tuning con Unsloth, assegna al container LXC almeno **16 GB di RAM** e abilita uno swap di almeno **8 GB** nelle impostazioni di Proxmox.
</details>

---

## Roadmap & WIP Features

- [x] Installatore automatico CUDA + NVIDIA Container Toolkit per LXC
- [x] Integrazione Unsloth Studio + OpenCode AI
- [x] Script idoneo ed idempotente `setup_jupyter.sh` per la gestione di JupyterLab
- [x] API Runner isolato con SSH Sandbox execution
- [x] Script di provisioning dedicato `sandbox_setup.sh` per nodi remoti
- [ ] Supporto multi-node Sandbox (gestione di più container esecutori in pool)
- [ ] Dashboard Web centralizzata per il monitoraggio GPU/RAM
- [ ] Integrazione opzionale ComfyUI (Generative AI Image/Video)

---

## Requisiti di Sistema

* **Sistema Operativo**: Debian 12 (Bookworm / Trixie) o Ubuntu 22.04 LTS / 24.04 LTS.
* **Privilegi**: Accesso Root o utente con permessi `sudo`.
* **Hardware GPU**: GPU NVIDIA supportata (consigliati almeno 12 GB VRAM per Fine-Tuning/Inferenza).
* **Virtualizzazione**: Bare-Metal oppure Container **Proxmox LXC** (Unprivileged/Privileged con GPU Pass-Through attivo).

---

## Struttura della Repository

```text
homelab-ai-deployer/
├── README.md                     # Documentazione generale e guida rapida
├── manager.sh                    # Script TUI principale per la gestione del Controller
├── prepare_sandbox_baremetal.md # Guida alla configurazione Sandbox su Bare Metal / VM
├── prepare_sandbox_lxc.md        # Guida alla configurazione Sandbox LXC su Proxmox VE
├── proxmox_lxc_sandbox_setup.sh # Script Proxmox VE per la creazione automatica dell'LXC
├── sandbox.md                    # Documentazione generale e requisiti delle Sandbox
├── sandbox_setup.sh              # Script di setup interno alla Sandbox (UTF-8, SSH, Python)
└── setup_jupyter.sh              # Script di installazione, verifica e gestione per JupyterLab
```

---

## Descrizione dei File

* **`README.md`** *(Documentazione Generale)*  
  La guida principale del progetto che illustra la visione d'insieme, l'architettura a due nodi (Controller + Sandbox), i requisiti e le istruzioni rapide per iniziare.

* **`manager.sh`** *(Script di Gestione Controller)*  
  Il cuore operativo da eseguire sulla macchina Controller. Offre un menu TUI interattivo per installare Unsloth Studio, OpenCode AI, configurare gli ambienti virtuali Python, scambiare le chiavi SSH con la Sandbox ed eseguire i test delle API.

* **`setup_jupyter.sh`** *(Script Gestione JupyterLab)*  
  Script indipendente per qualsiasi ambiente Linux (LXC, VM o Baremetal). Rileva se JupyterLab è già installato: in caso positivo ne assicura l'avvio via systemd e restituisce l'URL con il token di autenticazione; in caso contrario configura un ambiente Python isolato in `/opt/jupyter_env`, installa JupyterLab, imposta il demone `jupyter.service` e restituisce i dati di accesso.

* **`prepare_sandbox_baremetal.md`** *(Guida Bare Metal / VM)*  
  Guida per preparare una Sandbox su un PC/Server fisico dedicato o su hypervisor tradizionali (VirtualBox, ESXi, KVM, Hyper-V).

* **`prepare_sandbox_lxc.md`** *(Guida LXC Proxmox)*  
  Documentazione specifica con la procedura guidata per la creazione e la configurazione di una Sandbox isolata in ambiente Proxmox VE.

* **`proxmox_lxc_sandbox_setup.sh`** *(Script Shell per Proxmox VE)*  
  Script Bash interattivo da lanciare direttamente nella shell del nodo Proxmox: scarica il template OS (Debian/Ubuntu), crea il container LXC con le risorse allocate e configura automaticamente SSH, Python e i locale UTF-8.

* **`sandbox.md`** *(Panoramica e Requisiti Sandbox)*  
  File di riferimento generale che riassume le specifiche minime, la sicurezza e la struttura di rete necessarie per qualsiasi nodo Sandbox.

* **`sandbox_setup.sh`** *(Script di Provisioning Sandbox)*  
  Script da eseguire direttamente all'interno della macchina Sandbox (Bare Metal o VM generica) per installare Python 3, OpenSSH Server, configurare `PermitRootLogin yes` e applicare la localizzazione `en_US.UTF-8`.

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

## Licenza

Questo progetto è rilasciato sotto licenza [MIT](LICENSE).
