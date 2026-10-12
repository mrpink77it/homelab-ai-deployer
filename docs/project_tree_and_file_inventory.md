# 🌳 Homelab AI Deployer: Project Tree & File Inventory

Questo documento definisce l'albero strutturale (`tree`) ufficiale del repository `homelab-ai-deployer` (v2.0.0), specificando per ogni cartella e file il ruolo, l'utilità operativa e il contesto d'uso all'interno della "Fabbrica del Software Autonoma" su Proxmox VE.

---

## 📂 Struttura dell'Albero di Progetto (Tree)

```text
homelab-ai-deployer/
├── README.md
├── LICENSE
├── install.sh
├── iso-builder/
│   ├── build-iso.sh
│   ├── custom-iso-files/
│   │   └── first-boot.sh
│   └── configs/
│       └── unswering-answers.cfg
├── lxc-scripts/
│   ├── 00-common-setup.sh
│   ├── ct-99-orchestrator.sh
│   ├── ct-100-llm-worker.sh
│   ├── ct-101-coder-agent.sh
│   ├── ct-102-decision-maker.sh
│   ├── ct-103-trainer.sh
│   └── ct-104-rag-library.sh
├── orchestrator/
│   ├── app.py
│   ├── vram_manager.py
│   ├── requirements.txt
│   └── Dockerfile
└── docs/
    ├── homelab_ai_master_spec.md
    └── project_tree_inventory.md
```

---

## 🔍 Dettaglio dei File e Componenti

### 1. Root Directory (Radice del Progetto)

*   **`README.md`**
    *   *A cosa serve:* Presentazione principale del progetto, istruzioni di avvio rapido e panoramica della v2.0.0.
    *   *Utilità:* Primo punto di contatto per gli utenti su GitHub; spiega la filosofia "Dual Mode" e la gestione VRAM.
    *   *Dove si usa:* Su GitHub e come documentazione di benvenuto.
*   **`install.sh`**
    *   *A cosa serve:* Script principale d'ingresso (TUI Launcher) per nodi Proxmox pre-esistenti.
    *   *Utilità:* Avvia un'interfaccia testuale interattiva che guida l'utente nella selezione e installazione modulare dei container LXC.
    *   *Dove si usa:* Eseguito direttamente via terminale sul nodo Proxmox (`bash <(curl -s ...)`).

---

### 2. Cartella `iso-builder/` (Automazione Zero-Touch)

*   **`iso-builder/build-iso.sh`**
    *   *A cosa serve:* Script di automazione per scaricare la ISO ufficiale di Proxmox VE, decomprimerla, iniettare gli script di personalizzazione e ricompilarla.
    *   *Utilità:* Permette di generare una ISO customizzata per installazioni pulite su nuovo hardware senza intervento manuale.
    *   *Dove si usa:* Eseguito su una macchina di build Linux esterna o su un server di staging.
*   **`iso-builder/custom-iso-files/first-boot.sh`**
    *   *A cosa serve:* Script eseguito automaticamente al primissimo avvio dopo l'installazione del sistema operativo.
    *   *Utilità:* Configura l'ambiente (es. autologin su KDE Plasma nella Workstation Edition) e lancia il provisioning iniziale dell'infrastruttura IA.
    *   *Dove si usa:* Eseguito in background al boot inaugurale del nodo Proxmox installato da ISO custom.
*   **`iso-builder/configs/unswering-answers.cfg`**
    *   *A cosa serve:* File di risposta pre-configurata (Ansic/Debian preseed style o simile per Proxmox) per automatizzare l'installer di Proxmox.
    *   *Utilità:* Evita qualsiasi prompt interattivo durante l'installazione della ISO, rendendola "Zero-Touch".

---

### 3. Cartella `lxc-scripts/` (Provisioning dei Container)

*   **`lxc-scripts/00-common-setup.sh`**
    *   *A cosa serve:* Script di configurazione base condiviso per tutti i container LXC.
    *   *Utilità:* Installa dipendenze comuni, configura i repository APT, gestisce le chiavi SSH e prepara l'ambiente di rete containerizzato.
    *   *Dove si usa:* Richiamato da tutti gli script di creazione container specifici.
*   **`lxc-scripts/ct-99-orchestrator.sh`**
    *   *A cosa serve:* Script di creazione e setup del CT 99 (Orchestratore).
    *   *Utilità:* Configura l'ambiente per ospitare la dashboard Web e il modulo di gestione dinamica delle risorse.
    *   *Dove si usa:* Sul nodo Proxmox, per generare il CT 99.
*   **`lxc-scripts/ct-100-llm-worker.sh`**
    *   *A cosa serve:* Configura il container dedicato all'inferenza dei modelli linguistici (vLLM / Ollama).
    *   *Utilità:* Configura il pass-through della GPU e i framework di inferenza ad alte prestazioni (\~5.5 GB VRAM).
    *   *Dove si usa:* Sul nodo Proxmox, per generare il CT 100.
*   **`lxc-scripts/ct-101-coder-agent.sh`**
    *   *A cosa serve:* Configura il container "Cervello" (OpenDevin / Aider).
    *   *Utilità:* Isola l'agente di scrittura codice che riceve input dal LLM e interagisce con i container di progetto.
    *   *Dove si usa:* Sul nodo Proxmox, per generare il CT 101.
*   **`lxc-scripts/ct-102-decision-maker.sh`**
    *   *A cosa serve:* Configura il container per l'accelerazione di scelte logiche e branch (Rizzo Flow, \~1.5 GB VRAM).
    *   *Utilità:* Supporta l'agente nella ramificazione e validazione logica delle decisioni di codice.
    *   *Dove si usa:* Sul nodo Proxmox, per generare il CT 102.
*   **`lxc-scripts/ct-103-trainer.sh`**
    *   *A cosa serve:* Configura il container Trainer per il Fine-Tuning LoRA (Soup Framework, \~3.3 GB VRAM).
    *   *Utilità:* Gestisce l'addestramento locale con accesso esclusivo temporaneo alla GPU coordinato dall'Orchestratore.
    *   *Dove si usa:* Sul nodo Proxmox, per generare il CT 103.
*   **`lxc-scripts/ct-104-rag-library.sh`**
    *   *A cosa serve:* Configura il container Biblioteca / Memoria a lungo termine (AnythingLLM / Dify, basato su CPU).
    *   *Utilità:* Gestisce la base di conoscenza e le linee guida del progetto senza occupare VRAM.
    *   *Dove si usa:* Sul nodo Proxmox, per generare il CT 104.

---

### 4. Cartella `orchestrator/` (Logica Centrale & Dashboard)

*   **`orchestrator/app.py`**
    *   *A cosa serve:* Codice principale dell'applicazione Web (Streamlit / FastAPI).
    *   *Utilità:* Fornisce la dashboard visiva per il monitoraggio in tempo reale dei container, dei task attivi e dello stato dell'hardware.
    *   *Dove si usa:* Eseguito all'interno del **CT 99**.
*   **`orchestrator/vram_manager.py`**
    *   *A cosa serve:* Modulo core di orchestrazione intelligente della VRAM (8GB limit).
    *   *Utilità:* Monitora la richiesta di addestramento sul CT 103 e invia comandi SSH automatici per scaricare/smontare i modelli sul CT 100 e CT 102, prevenendo errori `CUDA Out of Memory`.
    *   *Dove si usa:* Eseguito in background sul **CT 99** o richiamato dall'API dell'Orchestratore.
*   **`orchestrator/requirements.txt`**
    *   *A cosa serve:* Elenco delle dipendenze Python per l'Orchestratore.
    *   *Utilità:* Garantisce la riproducibilità dell'ambiente Python.
    *   *Dove si usa:* Durante la fase di build o setup del CT 99.
*   **`orchestrator/Dockerfile`**
    *   *A cosa serve:* Ricetta per la containerizzazione Docker dell'Orchestratore (se eseguito in container Docker all'interno del CT LXC).
    *   *Utilità:* Isola l'applicazione web in un ulteriore layer gestibile.
    *   *Dove si usa:* Sulla build directory del CT 99.

---

### 5. Cartella `docs/` (Specifiche Tecniche)

*   **`docs/homelab_ai_master_spec.md`**
    *   *A cosa serve:* Master Architecture & Technical Specification v2.0.0.
    *   *Utilità:* Riferimento centrale e documento di specifica tecnica per il progetto.
    *   *Dove si usa:* Utilizzato per l'istruzione del modello e come documentazione architetturale nel workspace.
*   **`docs/project_tree_inventory.md`**
    *   *A cosa serve:* Inventario completo dell'albero di progetto e delle specifiche dei singoli file (questo documento).
    *   *Utilità:* Mappa visiva e funzionale per orientare lo sviluppo e la scrittura del codice.
    *   *Dove si usa:* Consultato come mappa di navigazione del repository.