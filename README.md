# unslot-suite.sh
LXC installer for Unsloth Studio - NVidia Driver/CUDA/Container Toolkit - ComfyUI - opencode

# 🚀 Unsloth + ComfyUI + OpenCode Orchestration Suite

Una suite completa di gestione e orchestrazione automatizzata disegnata per deploy su **Debian** e **Ubuntu** (con supporto nativo per **Container LXC Proxmox** con GPU Pass-Through).

Questo strumento gestisce l'intero ciclo di vita dell'ambiente AI: dall'allineamento automatico dei driver NVIDIA/CUDA con l'Host Proxmox, fino all'installazione e orchestrazione via `systemd` di **Unsloth**, **ComfyUI** e **OpenCode Interpreter**.

---


## ✨ Caratteristiche Principali

* **NVIDIA Driver Host-Matching Auto-Detect:** Legge la versione esatta dei driver usati dal kernel dell'Host direttamente dal container LXC ed installa l'esatto branch user-space corrispondente.
* **Stack GPU Completo:** Supporto per l'installazione granulare di Driver NVIDIA, CUDA Toolkit e NVIDIA Container Toolkit (per Docker).
* **Integrazione OpenCode Interpreter / Studio:** Configurazione automatica delle variabili d'ambiente (`OPENAI_API_BASE`, `OPENAI_API_KEY`) per collegare OpenCode direttamente all'endpoint LLM di Unsloth.
* **Orchestratore Python:** Script intermedio automatico che fa da bridge tra Unsloth (generazione testo/prompt) e ComfyUI (generazione immagini).
* **Gestione Daemon Systemd:** Registrazione, avvio, arresto e monitoraggio dei servizi in background con un solo comando.
* **Menu Grafico ASCII + CLI Flags:** Utilizzabile sia in modalità guidata che tramite scripting/automazioni CLI.

---

## 💻 Prerequisiti e Requisiti di Sistema

* **Sistema Operativo Supported:** Debian 11/12+, Ubuntu 20.04 / 22.04 / 24.04 LTS.
* **Privilegi:** Utente con permessi `sudo`.
* **Hardware:** Scheda Video NVIDIA (consigliate GPU con al minimo 8GB-12GB VRAM per Unsloth + ComfyUI).

---

## ⚙️ Requisiti LXC Proxmox (Pass-Through GPU)

Se si installa la suite all'interno di un container LXC su Proxmox VE, assicurarsi che nel file di configurazione del container sull'Host (`/etc/pve/lxc/<ID_CONTAINER>.conf`) siano presenti i pass-through per le periferiche NVIDIA:

```text
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 239:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file

📥 Installazione RapidaClona o scarica lo script sulla tua macchina Debian/Ubuntu:Bashwget [https://raw.githubusercontent.com/tuo-repo/unsloth-suite.sh](https://raw.githubusercontent.com/tuo-repo/unsloth-suite.sh)
# oppure crea il file in locale:
nano unsloth-suite.sh
Rendi lo script eseguibile:Bashchmod +x unsloth-suite.sh
Lancia il menu interattivo:Bash./unsloth-suite.sh
🛠️ Utilizzo dello Script1. Interfaccia Interattiva (CLI Menu)Eseguendo ./unsloth-suite.sh senza argomenti, si accederà al menu grafico ASCII:Plaintext==========================================================================
      __  ______  _____ __    ____  ______ __  __   _____ __  ______ _____ 
     / / / / __ \/ ___// /   / __ \/_  __// / / /  / ___// / / /  _// ___/ 
    / / / / / / /\__ \/ /   / / / / / /  / /_/ /   \__ \/ / / // / / /__   
   / /_/ / /_/ /___/ / /___/ /_/ / / /  / __  /   ___/ / /_/ // / / ___/   
   \____/\____//____/_____/\____/ /_/  /_/ /_/   /____/\____/___//_/       

       Unsloth + ComfyUI + OpenCode Orchestration Suite Manager           
==========================================================================

MENU PRINCIPALE:
1) Menu Installazione Applicazioni (NVIDIA / OpenCode / Unsloth / ComfyUI)
2) Menu Gestione OpenCode Interpreter / Studio
3) Verifica Stato Generale (verify)
4) Avvia Tutti i Servizi Suite (start)
5) Ferma Tutti i Servizi Suite (stop)
6) Configura/Installa Servizi Systemd (service)
7) Aggiorna ComfyUI e Componenti (update)
8) Rimuovi Servizi Systemd (remove)
9) Mostra Guida CLI (--help)
10) Uscita
Sezioni Sub-Menu:Sub-Menu NVIDIA: Permette di installare lo stack completo o singole parti (solo driver matching Host, solo CUDA Toolkit, o solo NVIDIA Container Toolkit per Docker).Sub-Menu OpenCode: Gestisce l'installazione dell'ambiente Python per open-interpreter / opencode-ai, configura i token/endpoint di Unsloth e installa il daemon Systemd separato.2. Utilizzo da Riga di Comando (CLI Flags)È possibile eseguire direttamente comandi specifici bypassando il menu interattivo:Bash# Mostra la guida dei comandi
./unsloth-suite.sh -h

# Rileva i driver dell'Host ed installa lo stack NVIDIA completo
./unsloth-suite.sh install-nvidia

# Installa e configura OpenCode Interpreter collegato ad Unsloth
./unsloth-suite.sh install-opencode

# Esegue una verifica diagnostica completa del sistema
./unsloth-suite.sh verify

# Registra e abilita i servizi Systemd per l'avvio automatico
./unsloth-suite.sh service

# Avvia tutti i servizi della suite
./unsloth-suite.sh start

# Arresta tutti i servizi e processi collegati
./unsloth-suite.sh stop

# Aggiorna i repository Git di ComfyUI e ComfyUI-Manager
./unsloth-suite.sh update

# Disinstalla e rimuove i servizi Systemd dal sistema
./unsloth-suite.sh remove
🏗️ Architettura della SuiteI componenti vengono organizzati ed installati all'interno della cartella Home dell'utente ($HOME):Plaintext$HOME/
├── ComfyUI/                         # Repository principale ComfyUI + venv
│   ├── custom_nodes/ComfyUI-Manager # Manager di nodi per ComfyUI
│   └── models/checkpoints/          # Modelli SD (es. Stable Diffusion 1.5)
├── unsloth/                         # Virtual environment dedicato ad Unsloth
├── opencode/                        # Virtual environment ed ambiente OpenCode
├── unsloth_comfy_orchestrator.py    # Bridge Script Python tra Unsloth e ComfyUI
├── start_suite_wrapper.sh           # Script wrapper avvio orchestratore + ComfyUI
├── start_opencode_wrapper.sh        # Script wrapper avvio daemon OpenCode
└── .unsloth_suite.conf              # File di configurazione variabili ed endpoint
🔄 Gestione dei Servizi SystemdLa suite registra due servizi principali gestiti tramite systemctl:Nome ServizioFile di ServizioDescrizioneunsloth-orchestrator/etc/systemd/system/unsloth-orchestrator.serviceGestisce l'istanza di ComfyUI e l'orchestratore Python.opencode-orchestrator/etc/systemd/system/opencode-orchestrator.serviceGestisce il daemon di background di OpenCode Interpreter.Monitoraggio nei Log di SistemaPuoi controllare i log in tempo reale tramite journalctl:Bash# Controlla i log dell'orchestratore Unsloth + ComfyUI
journalctl -u unsloth-orchestrator -f

# Controlla i log del servizio OpenCode
journalctl -u opencode-orchestrator -f
📄 LicenzaRilasciato sotto licenza MIT. Puoi utilizzarlo, modificarlo e redistribuirlo liberamente.
