# Homelab AI Deployer

[![Status WIP](https://img.shields.io/badge/status-Work_in_Progress-yellow.svg)](https://github.com/mrpink77it/homelab-ai-deployer)
[![shell script](https://img.shields.io/badge/shell_script-bash-1f425f.svg)](https://www.gnu.org/software/bash/)
[![OS](https://img.shields.io/badge/OS-Debian_%2F_Ubuntu-orange.svg)](https://debian.org)
[![NVIDIA CUDA](https://img.shields.io/badge/NVIDIA-CUDA-76B900.svg?logo=nvidia&logoColor=white)](https://developer.nvidia.com/cuda-toolkit)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> **`mrpink77it/homelab-ai-deployer`** è uno script Bash automatizzato ("zero-config") progettato per configurare, gestire e distribuire un ambiente completo di AI Generativa, LLM Fine-Tuning e sviluppo su macchine Linux e container **Proxmox LXC**.
> **La tua suite AI per l'Homelab: genera ed esegue codice automaticamente in totale sicurezza.**

Benvenuto in **Homelab AI Deployer**! Questo progetto nasce per mettere a tua disposizione un assistente AI avanzato in grado di **scrivere ed eseguire automaticamente codice** direttamente nel tuo laboratorio domestico (Homelab) o ambiente **Proxmox VE**.

Non dovrai più copiare e incollare manualmente gli script generati dall'IA: il sistema permette all'Intelligenza Artificiale di creare il codice, inviarlo ed eseguirlo in autonomia, gestendo al contempo tutta la configurazione complessa di driver NVIDIA, CUDA e ambienti Python.

---

### 💡 Come funziona? (Generazione ed Esecuzione Automatica)

Il sistema sfrutta un'architettura a due componenti per unire **automazione totale** e **massima sicurezza**:

1. **🧠 Controller (L'Ingegneria ed Elaborazione AI - con GPU):** 
   È il "cervello" della tua infrastruttura. Qui girano i modelli AI (tramite OpenCode AI e Unsloth Studio) che analizzano le tue richieste, **ragionano e generano il codice** sfruttando la potenza della tua scheda video.

2. **🛡️ Sandbox (L'Esecutore Sicuro):** 
   È un container LXC o macchina virtuale isolata dal resto della rete. Quando l'IA genera uno script o un comando, **lo invia ed esegue automaticamente all'interno della Sandbox**. L'IA riceve il risultato dell'esecuzione (o eventuali errori) e può correggerlo da sola, il tutto senza toccare né rischiare di danneggiare il tuo server principale.



> ⚠️ **Nota:** Questo progetto è attualmente in fase di sviluppo attivo (**Work in Progress**). Alcune funzionalità e configurazioni potrebbero subire variazioni.

---

## 📸 Caratteristiche Principali

* ⚡ **Installazione Automatica Controller**: Interfaccia TUI guidata in tempo reale con monitoraggio avanzato del log via `manager.sh`.
* 🛡️ **Setup Automatizzato Sandbox**: Script helper dedicato (`sandbox_setup.sh`) per la preparazione lampo di nodi esecutori LXC/VM remoti.
* 🎮 **Stack GPU & CUDA Completo**: Installazione e configurazione automatica dei driver NVIDIA, CUDA Toolkit e NVIDIA Container Toolkit (con fix nativi per container LXC e gestione trust SHA1 per Debian 12 / Trixie).
* 🦥 **Unsloth Studio**: Ambiente di sviluppo per Fine-Tuning & Inferenza LLM ad alte prestazioni via Astral `uv` con Jupyter Lab (`:8888`).
* 💻 **OpenCode AI Web**: Piattaforma web di sviluppo assistito da intelligenza artificiale (`:8000`).
* 🛡️ **Code Runner API (Sandbox Execution)**: Microservizio FastAPI (`:9000`) per eseguire codice generato dall'AI in un ambiente remoto isolato via SSH.
* 🧹 **Gestione & Uninstall Pulito**: Script integrato per la rimozione selettiva o totale dei servizi e delle unità `systemd`.

---

## 📊 Servizi Esposti

| Servizio | Porta | Descrizione |
| :--- | :---: | :--- |
| **Unsloth Studio** | `8888` | Interfaccia Jupyter Lab per Fine-Tuning & Inferenza LLM |
| **OpenCode AI** | `8000` | Interfaccia Web OpenCode |
| **Code Runner API** | `9000` | Endpoint REST FastAPI per l'esecuzione remota sicura in Sandbox |

---

## 🔌 Pre-requisiti Proxmox Host (GPU Passthrough)

Se stai eseguendo lo script all'interno di un container **Proxmox LXC**, assicurati che l'Host Proxmox abbia i driver NVIDIA installati e che il file di configurazione del container (`/etc/pve/lxc/<CONTAINER_ID>.conf`) contenga le regole per il passthrough dei device NVIDIA:

```ini
# Aggiungere a /etc/pve/lxc/<CONTAINER_ID>.conf sull'host Proxmox:
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 508:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
```

---

## 🚀 Avvio Rapido

### Setup del Controller AI (Host Principale)

```bash
git clone [https://github.com/mrpink77it/homelab-ai-deployer.git](https://github.com/mrpink77it/homelab-ai-deployer.git)
cd homelab-ai-deployer
chmod +x manager.sh sandbox_setup.sh
sudo ./manager.sh
```

---

## 🧪 Architettura Sandbox & Provisioning (`sandbox_setup.sh`)

L'architettura separa nettamente il **Controller AI** (dove girano i modelli, le interfacce e la GPU) dal **Nodo Sandbox** (LXC/VM separata) dove viene eseguito il codice generato dall'AI in un contesto confinato.

```text
+---------------------------------+             SSH             +---------------------------------+
|         CONTROLLER AI           |---------------------------->|          SANDBOX LXC/VM         |
|  - Unsloth Studio (Porta 8888)  |   Exec: python3 -c "..."    |  - Configurato da               |
|  - OpenCode AI    (Porta 8000)  |                             |    sandbox_setup.sh             |
|  - Code Runner    (Porta 9000)  |<----------------------------|  - Python 3 / OpenSSH           |
+---------------------------------+        stdout / stderr      +---------------------------------+
```

### Configurazione del Nodo Sandbox (In 2 Passaggi)

Per predisporre un nuovo container LXC o VM da utilizzare come Sandbox isolata:

#### 1. Prepara il Nodo Sandbox
Esegui lo script `sandbox_setup.sh` all'interno del container/VM destinato a fare da Sandbox per installare le dipendenze minimali (Python 3, OpenSSH Server) e configurare le regole SSH:

```bash
# Esegui sulla macchina Sandbox:
curl -fsSL [https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/sandbox_setup.sh](https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/sandbox_setup.sh) | sudo bash
```

#### 2. Associa Controller ➔ Sandbox
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

## 🎛️ Opzioni del Menu `manager.sh`

Eseguendo `./manager.sh` si accederà al menu interattivo TUI:

1. **`1) INSTALLA Servizi`**: Installazione automatica completa (Driver GPU, CUDA Toolkit, Unsloth, OpenCode AI, Code Runner API).
2. **`2) VERIFICA Stato`**: Controllo dello stato dei servizi `systemd` e della disponibilità GPU via PyTorch/CUDA.
3. **`3) AGGIORNA Componenti`**: Git pull e aggiornamento dipendenze per OpenCode AI e Unsloth.
4. **`4) CONFIGURA Sandbox`**: Helper interattivo per la gestione ed il test dell'endpoint API remota.
5. **`5) DISINSTALLA`**: Rimozione completa delle directory, configurazioni ed unità `systemd`.

---

## 💾 Gestione Storage e Modelli

Per evitare di esaurire lo spazio sul disco root dell'LXC, le directory principali di lavoro e di cache dei modelli sono organizzate come segue:

* **Cache Modelli HuggingFace / Unsloth**: `~/.cache/huggingface/hub`
* **Ambiente Virtuale Python (`uv`)**: `/root/unsloth_env`
* **Servizio Code Runner**: `/opt/code_runner/`

---

## 🔍 Verifica e Gestione Servizi

Dopo il completamento dello script, puoi verificare il corretto riconoscimento della GPU e di CUDA eseguendo:

```bash
/root/unsloth_env/bin/python3 -c "import torch; print('CUDA disponibile:', torch.cuda.is_available()); print('GPU:', torch.cuda.get_device_name(0))"
```

### Gestione tramite Systemd

Puoi controllare i singoli servizi tramite `systemctl`:

* **Unsloth Studio**: `systemctl status unsloth-studio.service`
* **OpenCode AI**: `systemctl status opencode.service`
* **Code Runner API**: `systemctl status code-runner.service`

---

## ❓ Risoluzione Problemi (FAQ)

<details>
<summary><b><code>nvidia-smi</code> funziona nell'LXC ma PyTorch restituisce <code>CUDA available: False</code></b></summary>

Assicurati che i permessi dei device `/dev/nvidia*` all'interno del container siano corretti. Esegui:
```bash
chmod 666 /dev/nvidia*
```
Se usi un container **Unprivileged**, verifica che i permessi UID/GID tra Host e LXC siano mappati correttamente per i nodi `/dev/nvidia*`.
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

## 🗺️ Roadmap & WIP Features

- [x] Installatore automatico CUDA + NVIDIA Container Toolkit per LXC
- [x] Integrazione Unsloth Studio + OpenCode AI
- [x] API Runner isolato con SSH Sandbox execution
- [x] Script di provisioning dedicato `sandbox_setup.sh` per nodi remoti
- [ ] Supporto multi-node Sandbox (gestione di più container esecutori in pool)
- [ ] Dashboard Web centralizzata per il monitoraggio GPU/RAM
- [ ] Integrazione opzionale ComfyUI (Generative AI Image/Video)

---

## 🛠️ Requisiti di Sistema

* **Sistema Operativo**: Debian 12 (Bookworm / Trixie) o Ubuntu 22.04 LTS / 24.04 LTS.
* **Privilegi**: Accesso Root o utente con permessi `sudo`.
* **Hardware GPU**: GPU NVIDIA supportata (consigliati almeno 12 GB VRAM per Fine-Tuning/Inferenza).
* **Virtualizzazione**: Bare-Metal oppure Container **Proxmox LXC** (Unprivileged/Privileged con GPU Pass-Through attivo).

---

## 📁 Struttura della Repository

```text
homelab-ai-deployer/
├── README.md                     # Documentazione generale e guida rapida
├── manager.sh                    # Script TUI principale per la gestione del Controller
├── prepare_sandbox_baremetal.md  # Guida alla configurazione Sandbox su Bare Metal / VM
├── prepare_sandbox_lxc.md        # Guida alla configurazione Sandbox LXC su Proxmox VE
├── proxmox_lxc_sandbox_setup.sh  # Script Proxmox VE per la creazione automatica dell'LXC
├── sandbox.md                    # Documentazione generale e requisiti delle Sandbox
└── sandbox_setup.sh              # Script di setup interno alla Sandbox (UTF-8, SSH, Python)
```

---

### 📄 Descrizione dei File

* **`README.md`** *(Documentazione Generale)*  
  La guida principale del progetto che illustra la visione d'insieme, l'architettura a due nodi (Controller + Sandbox), i requisiti e le istruzioni rapide per iniziare.

* **`manager.sh`** *(Script di Gestione Controller)*  
  Il cuore operativo da eseguire sulla macchina **Controller**. Offre un menu TUI interattivo per installare Unsloth Studio, OpenCode AI, configurare gli ambienti virtuali Python, scambiare le chiavi SSH con la Sandbox ed eseguire i test delle API.

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

## 📄 Licenza

Questo progetto è rilasciato sotto licenza [MIT](LICENSE).
