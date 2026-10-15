Markdown
# 🚀 HOMELAB AI DEPLOYER - SPECIFICA TECNICA ED ARCHITETTURALE (v2.0.0)
> **Target System**: OpenCode Agent / Software Factory Autonoma su Proxmox VE  
> **Ambienti Supportati**: Proxmox VE (LXC/VM), Ubuntu Bare Metal, Windows WSL 2  

---

## 1. VISIONE GENERALE E FILOSOFIA DEL PROGETTO
`homelab-ai-deployer` è un framework di automazione per trasformare un'infrastruttura casalinga o aziendale in una **Fabbrica del Software Autonoma**. 

Il sistema opera in due modalità principali:
- **Server Edition (Headless)**: Installazione ottimizzata su Proxmox VE con orchestrazione di container LXC specializzati e passthrough hardware Multi-GPU (NVIDIA / AMD ROCm / Intel Vulkan).
- **Workstation Edition**: Installazione per ambiente desktop (KDE Plasma su Proxmox Host o Windows via WSL 2) mantenendo l'infrastruttura di orchestrazione IA attiva in background.

### Vincolo Critico di Risorsa (VRAM Management)
In presenza di risorse GPU limitate (es. singola GPU da 8GB/12GB VRAM), l'architettura applica una gestione chirurgica della memoria video: i modelli di inferenza (LLM Worker e Decisore) vengono temporaneamente scaricati dalla VRAM quando viene avviato un task intensivo di addestramento o fine-tuning (Trainer LoRA Soup), per poi essere automaticamente ripristinati al termine.

---

## 2. ALBERO COMPLETO DEL REPOSITORY
```text
homelab-ai-deployer/
├── AGENTS.md                                                       # Istruzioni principali per gli agenti OpenCode
├── .github/
│   └── workflows/
│       └── ci-cd.yml                                               # Pipeline CI/CD per validazione sintassi script
├── docs/
│   ├── homelab_ai_deployer_master_architecture_technical_specification.md  # Architettura master v2.0.0
│   ├── homelab_ai_opencode_complete_specification.md              # Questo file di specifica
│   ├── manager-finetuning.md                                       # Guida al manager NVIDIA / Fine-Tuning
│   ├── sandbox.md                                                  # Architettura e API Code Runner (:9000)
│   ├── prepare_sandbox_lxc.md                                      # Guida preparazione Sandbox LXC
│   ├── prepare_sandbox_baremetal.md                                # Guida preparazione Sandbox Bare Metal / VM
│   ├── ollama_bench.md                                             # Benchmark e metriche Ollama
│   ├── servizi.md                                                  # Mappatura servizi (OCR, Voice, RAG, Vibe Coding)
│   └── windows.md                                                  # Guida alla configurazione su Windows WSL 2
├── script/
│   ├── main.sh                                                     # Dispatcher TUI principale (whiptail)
│   ├── install.sh                                                  # Bootstrap script per la clonazione repo
│   ├── first-boot.sh                                               # Script di primo avvio per ISO Zero-Touch
│   ├── deploy-lxc-ai.sh                                            # Creazione e configurazione container LXC Proxmox
│   ├── setup-tika.sh                                               # Automated setup per Apache Tika (RAG)
│   ├── sandbox_setup.sh                                            # Setup del nodo Sandbox per esecuzione codice
│   ├── setup_jupyter.sh                                            # Setup ambiente JupyterLab isolato (:8888)
│   ├── setup-server.sh                                             # Setup headless per nodi Proxmox IA
│   ├── utility-menu.sh                                             # Menu utility per pulizia VRAM, cache e log
│   └── vram_manager.py                                             # Demone Python di orchestrazione VRAM
├── orchestrator/
│   ├── app.py                                                      # Dashboard web Streamlit (CT 99)
│   ├── requirements.txt                                            # Dipendenze Python dell'Orchestratore
│   └── Dockerfile                                                  # Dockerfile dell'Orchestratore
├── iso-builder/
│   ├── win-gui/
│   │   ├── MainForm.cs                                             # Builder grafico C# per Windows
│   │   └── Program.cs                                              # Entry point C# per scrittura ISO RAW
│   └── answers/
│       └── proxmox-answer.toml                                     # Configurazione unattended Proxmox
└── systemd/
    ├── homelab-ai-frontend.servicefr                               # Service frontend
    ├── ollama.service                                              # Service demone Ollama
    ├── homelab-ai-vibevoice-api.service                            # Service Voice/Audio API
    ├── homelab-ai-forge.service                                    # Service motore Forge
    └── homelab-ai-orchestrator.service                             # Service Orchestratore (CT 99)
3. SPECIFICHE PER LA CREAZIONE DEI CONTAINER LXC SU PROXMOX
La Fabbrica del Software è suddivisa in container LXC isolati su Proxmox VE. La creazione avviene combinando Proxmox Helper Scripts (per i container standard) e creazione manuale/custom (per i container che richiedono passthrough GPU o configurazioni speciali).

A. Container Standard (Tramite Proxmox Helper Scripts)
I container che non necessitano di accesso diretto alle GPU o di passthrough hardware specifico devono essere creati utilizzando gli Helper Script della community Proxmox (tteck / community-scripts):

CT 104 - Biblioteca RAG & Tika (ai-rag-library):

Metodo: Creazione via Helper Script Debian/Ubuntu LXC avanzato.

Comando Helper: bash -c "$(wget -qLO - https://github.com/community-scripts/ProxmoxVE/raw/main/ct/ubuntu.sh)"

Risorse: 2 CPU Core, 4 GB RAM, 32 GB Storage.

Configurazione: Esegue Apache Tika (setup-tika.sh) e un Vector Database locale (ChromaDB / Qdrant) accessibile via HTTP.

B. Container Specializzati (Creazione Manuale / Custom Script)
I container con passthrough GPU o esigenze di nesting Docker devono essere creati manualmente o tramite script/deploy-lxc-ai.sh:

CT 99 - Orchestratore & VRAM Manager (ai-orchestrator):

Metodo: Creazione manuale LXC Unprivileged.

Risorse: 2 CPU Core, 2 GB RAM, 16 GB Storage.

Ruolo: Gestisce la dashboard Streamlit (orchestrator/app.py) e il demone vram_manager.py.

CT 100 - LLM Worker (ai-llm-worker):

Metodo: Creazione LXC Privileged o Unprivileged con idmap per passthrough GPU.

Risorse: 4-8 CPU Core, 16-32 GB RAM, 64 GB Storage + Passthrough /dev/nvidia* o /dev/dri/*.

Ruolo: Esegue vLLM o Ollama per l'inferenza veloce dei modelli di base.

CT 101 - Agente Coder (ai-agent-coder):

Metodo: Creazione manuale LXC.

Risorse: 4 CPU Core, 8 GB RAM, 32 GB Storage.

Ruolo: Ambiente dedicato all'agente di coding (OpenCode / AutoCode).

CT 102 - Decisore Rizzo Flow (ai-decisore):

Metodo: Creazione manuale LXC con GPU Passthrough (se condivisa).

Risorse: 2-4 CPU Core, 8 GB RAM, 32 GB Storage.

Ruolo: Esegue i modelli decisionali e di orchestrazione del flusso logico.

CT 103 - Trainer LoRA Soup (ai-trainer):

Metodo: Creazione LXC con passthrough GPU esclusivo o prioritario.

Risorse: 8 CPU Core, 32 GB RAM, 128 GB Storage.

Ruolo: Esegue script di Fine-Tuning e merge LoRA (LoRA Soup). Avviato su richiesta dal VRAM Manager.

CT 20X - Container Target Sandbox (ai-sandbox-201+):

Metodo: Creazione LXC con abilitazione nesting=1 e keyctl=1.

Risorse: Variabili in base ai test.

Ruolo: Ambiente isolato con supporto Docker in Docker per l'esecuzione e il collaudo sicuro del codice prodotto.

4. LOGICA DI FUNZIONAMENTO DELL'ORCHESTRATORE E VRAM MANAGER
L'Orchestratore (CT 99) è il cervello operativo del sistema e garantisce che la memoria GPU non vada mai in Out-Of-Memory (OOM).

Flusso di Coordinamento VRAM (vram_manager.py)
Monitoraggio: Il demone interroga continuamente lo stato della GPU (tramite nvidia-smi o API Ollama/vLLM) e lo stato del CT 103 (Trainer).

Richiesta Fine-Tuning: Quando l'utente o l'agente avvia un task di addestramento su CT 103:

vram_manager.py invia una richiesta di unload a CT 100 e CT 102 per liberare la VRAM occupata dai modelli di inferenza.

Verifica che la VRAM libera superi la soglia di sicurezza (es. 90% di VRAM libera).

Avvia il container CT 103 ed esegue il task di training.

Ripristino:

Al completamento del training su CT 103, il container viene arrestato o messo in standby.

vram_manager.py ricarica i modelli di inferenza principali su CT 100 e CT 102.

5. ULTERIORI ISTRUZIONI E DOCUMENTAZIONE DI SUPPORTO
Oltre a questo file, all'interno della directory docs/ del progetto sono presenti ulteriori file .md che contengono istruzioni dettagliate, guide operative e specifiche tecniche utili da consultare in base alle necessità di sviluppo:

manager-finetuning.md: Dettagli operativi sul manager NVIDIA e procedure di fine-tuning.

sandbox.md & guide correlate (prepare_sandbox_lxc.md, prepare_sandbox_baremetal.md): Specifiche per l'isolamento dei test di codice.

ollama_bench.md: Metriche e linee guida per il benchmarking delle performance LLM.

servizi.md: Mappatura approfondita dei microservizi (OCR, Voice, RAG, Vibe Coding).

windows.md: Configurazione specifica per l'esecuzione in ambiente Windows WSL 2.

6. ISTRUZIONI PER OPENCODE
Quando lavori su questo repository:

Trasparenza sui File: Non cancellare o sovrascrivere mai script esistenti senza conferma esplicita.

Modularità: Assicurati che ogni script bash includa il controllo degli errori (set -euo pipefail) e sia compatibile con la TUI whiptail.

Integrazione Systemd: Ogni servizio deve possedere la corrispondente unit file in systemd/ per l'avvio automatico al boot.
