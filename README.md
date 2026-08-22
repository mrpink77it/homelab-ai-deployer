# Homelab AI Deployer

![Status](https://img.shields.io/badge/Status-Work_in_Progress-orange)
![Language](https://img.shields.io/badge/Language-Bash-4EAA25)
![License](https://img.shields.io/badge/License-MIT-blue)

> **`mrpink77it/homelab-ai-deployer`** è una suite di script Bash automatizzati ("zero-config") progettata per configurare, gestire e distribuire un ambiente completo di AI Generativa (Inferenza), LLM Fine-Tuning e sviluppo nativo su macchine Linux, server Bare-Metal e container **Proxmox LXC**. 

---

## 🏗️ Architecture & Hardware Compatibility

Il progetto supporta un'architettura **Multi-Backend** in grado di rilevare automaticamente l'hardware installato e selezionare lo stack software ottimale, includendo un fallback nativo per sistemi privi di GPU:

```text
                               +-----------------------+
                               |        main.sh        |
                               | (Hardware Discovery)  |
                               +-----------+-----------+
                                           |
     +-------------------------------------+-------------------------------------+
     |                                     |                                     |
     v                                     v                                     v
[ GPU NVIDIA ]                        [ GPU AMD ]                      [ Nessuna GPU / CPU ]
     |                                     |                                     |
Esegue manager.sh                   Esegue manager-amd.sh                  Esegue manager-cpu.sh
     |                                     |                                     |
 +---+---+            +--------------------+--------------------+            +---+---+
 | CUDA  |            |                    |                    |            | CPU   |
 | vLLM  |            v                    v                    v            | AVX2  |
 +-------+    [ ROCm Ufficiale ]   [ Vulkan / llama.cpp ]   [ ROCm Exp ]     +-------+
```

### Matrice di Supporto

| Produttore | Architettura / Schede | Backend Selezionato | Note & Performance |
| :--- | :--- | :--- | :--- |
| **NVIDIA** | GTX / RTX / Tesla (T4, A100, ecc.) | **CUDA / vLLM** | Supporto nativo completo, massimo throughput ed accelerazione PyTorch. |
| **AMD** | RDNA 2 / RDNA 3 (RX 6000 / 7000) | **ROCm Ufficiale** | Supporto nativo bare-metal via PyTorch ROCm (`rocm-hip-sdk`). |
| **AMD** | RDNA 1 (RX 5000 / 5700 XT) | **Vulkan (llama.cpp)** | **Raccomandato:** Massima stabilità via API Vulkan senza rischio crash/OOM. |
| **AMD** | RDNA 1 (RX 5700 / 5700 XT) | **ROCm Experimental** | Utilizza l'override `HSA_OVERRIDE_GFX_VERSION=10.3.0` per PyTorch. |
| **CPU** | x86_64 / ARM64 (Intel/AMD) | **CPU (llama.cpp)** | Fallback universale. Inferenza pura su RAM di sistema (dipendente dalle istruzioni AVX2/AVX512). |

---

## 🚀 Avvio Rapido

### Setup del Controller AI (Host Principale)

Copia ed incolla questo comando per eseguire l'installazione. Eseguire come root (`su`) o super user (`sudo`):

```bash
wget -q [https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/install.sh](https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/install.sh) && chmod +x install.sh && ./install.sh
```

---

## 🎛️ Funzionamento degli Installer (Manager Scripts)

In base all'hardware rilevato da `main.sh`, verrà avviata l'interfaccia di gestione (TUI basata su `whiptail`) specifica per il tuo sistema. Tutti i manager offrono un'interfaccia uniforme ma applicano configurazioni specifiche sotto il cofano.

### 🟢 Menu NVIDIA (`manager.sh`)
* **`1) INSTALLA Servizi`**: Installazione completa dei driver proprietari, CUDA Toolkit, e deploy nativo di Unsloth, OpenCode AI, e frontend AI.
* **`2) VERIFICA Stato & Dashboard`**: Monitoraggio dei servizi `systemd` in tempo reale e convalida dell'accelerazione hardware CUDA via PyTorch.
* **`3) GESTIONE Modelli`**: Interfaccia per il download automatizzato dei modelli GGUF/Safetensors dai repository HuggingFace.
* **`4) AGGIORNA Componenti`**: Git pull e rebuild degli ambienti virtuali (`uv`) per tutti i tool AI installati.
* **`5) CONFIGURA Sandbox`**: Helper per il test dell'endpoint API remota e associazione chiavi SSH.
* **`6) DISINSTALLA`**: Purge totale di directory, cache e rimozione dei servizi `systemd`.

### 🔴 Menu AMD (`manager-amd.sh`)
Integra in fase d'installazione la selezione guidata dello stack software AMD:
* **`1) INSTALLA Servizi`**: Richiede la scelta dell'accelerazione:
  1. *ROCm Ufficiale*: Installa `rocm-hip-sdk` (consigliato per RX 6000/7000).
  2. *Vulkan (llama.cpp)*: Compila i binari con accelerazione `GGML_VULKAN=1` (stabilità massima per RDNA 1).
  3. *ROCm Sperimentale*: Applica hack ambientali per forzare il supporto PyTorch su schede legacy.
* *(Le restanti opzioni 2-6 replicano le medesime logiche di gestione, verifica e disinstallazione del manager NVIDIA, adattate ai tool ROCm/Vulkan).*

### 🔵 Menu CPU (`manager-cpu.sh`)
Versione ottimizzata per ambienti privi di acceleratori dedicati (es. Mini-PC, NUC, server basici):
* **`1) INSTALLA Servizi`**: Compila il backend di inferenza sfruttando esclusivamente OpenBLAS e le istruzioni CPU vettoriali native (AVX/AVX2). Non installa driver GPU pesanti, mantenendo il sistema leggero.
* Offre le medesime funzioni di gestione modelli, controllo stato servizi e associazione Sandbox degli altri manager, limitando l'esecuzione ai limiti della RAM di sistema.

---

## 🔌 Porte di Rete e Servizi Systemd

L'intero ecosistema è orchestrato nativamente (senza Docker) per evitare overhead. I processi sono isolati tramite file Unit di `systemd` e le porte sono rigorosamente separate per impedire conflitti (es. errore `[Errno 98]`).

| Servizio / Tool | Porta | Demone Systemd | Descrizione |
| :--- | :--- | :--- | :--- |
| **AI Backend** | `8080` | `homelab-ai-backend.service` | Motore di inferenza (`llama-server`) in binding su `0.0.0.0` |
| **AI Frontend** | `3000` | `homelab-ai-frontend.service` | Open WebUI (variabili d'ambiente `WEBUI_PORT` forzate) |
| **Unsloth Studio** | `8888` | `unsloth-studio.service` | Interfaccia dedicata alle operazioni di Fine-Tuning LLM |
| **JupyterLab** | `8889` | `jupyter.service` | Ambiente Data Science (scala dinamicamente se porta occupata) |
| **OpenCode AI** | `8000` | `opencode.service` | Piattaforma di sviluppo assistita da AI |
| **Code Runner** | `9000` | `code-runner.service` | API Endpoint locale per il proxy dell'esecuzione remota |

---

## 🛡️ Architettura Sandbox & Provisioning

L'architettura separa il **Controller AI** (dove girano i modelli e le GUI) dal **Nodo Sandbox** (LXC/VM separata) dove viene eseguito il codice generato in un contesto confinato per ragioni di sicurezza.

```text
+---------------------------------+             SSH             +---------------------------------+
|          CONTROLLER AI          |---------------------------->|          SANDBOX LXC/VM         |
|  - OpenCode AI    (Porta 8000)  |  Exec: python3 -c "..."     |  - Configurato da               |
|  - Code Runner    (Porta 9000)  |<----------------------------|    sandbox_setup.sh             |
+---------------------------------+       stdout / stderr       +---------------------------------+
```

### Configurazione del Nodo Sandbox

1. **Prepara il Nodo Sandbox:** Esegui lo script direttamente nel container/VM destinato a fare da esecutore isolato:
   ```bash
   curl -fsSL [https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/sandbox_setup.sh](https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/sandbox_setup.sh) | sudo bash
   ```
2. **Associa Controller -> Sandbox:** Usa il gestore (es. opzione 5 nel menu) oppure genera e invia manualmente la chiave SSH:
   ```bash
   ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
   ssh-copy-id -i /root/.ssh/id_ed25519.pub root@<IP_SANDBOX>
   ```

---

## 💾 Gestione Storage e Directory

Per evitare di esaurire lo spazio sul disco root dell'LXC/VM, il filesystem è standardizzato:

* **Modelli GGUF (Inferenza)**: `/opt/homelab-ai/backend/models/`
* **Cache HuggingFace (Unsloth)**: `~/.cache/huggingface/hub`
* **Ambiente Virtuale (Backend/Frontend)**: `/opt/homelab-ai/*/venv/`
* **Ambiente Virtuale (Unsloth)**: `/root/unsloth_env`
* **Ambiente Virtuale (Jupyter)**: `/opt/jupyter_env/`
* **Workspace Notebooks**: `/root/notebooks/`

---

## 🩺 Risoluzione Problemi (FAQ)

<details>
<summary><b>Conflitto porta 8080 (Address already in use)</b></summary>

Se Open WebUI non parte e segnala errore `[Errno 98]`, verifica che `homelab-ai-frontend.service` stia esportando correttamente `Environment="WEBUI_PORT=3000"`. Riavvia con `systemctl daemon-reload && systemctl restart homelab-ai-frontend`.
</details>

<details>
<summary><b><code>nvidia-smi</code> o <code>rocm-smi</code> funziona nell'LXC ma PyTorch restituisce <code>False</code></b></summary>

Assicurati che i permessi dei nodi device all'interno del container siano corretti. Esegui:
```bash
chmod 666 /dev/nvidia*     # Per NVIDIA
chmod 666 /dev/kfd /dev/dri/*  # Per AMD
```
</details>

<details>
<summary><b>La RX 5700 XT va in Segmentation Fault in modalità ROCm</b></summary>

L'architettura RDNA 1 non è ufficialmente supportata da ROCm 6.x. Se risulta instabile, riesegui `./manager-amd.sh`, seleziona **Disinstalla**, reinstalla e scegli la modalità **Vulkan / llama.cpp**, che garantisce stabilità al 100%.
</details>

<details>
<summary><b>Errore di memoria durante il caricamento dei modelli LLM</b></summary>

Per l'inferenza e il fine-tuning assegna al container LXC/VM almeno **16 GB di RAM** e abilita uno swap di almeno **8 GB** nelle impostazioni di Proxmox.
</details>

---

## 📋 Requisiti di Sistema

* **Sistema Operativo**: Debian 13 (Trixie) o Ubuntu 24.04 LTS.
* **Privilegi**: Accesso Root o utente con permessi `sudo`.
* **Hardware GPU / CPU**: 
  * **NVIDIA:** GPU supportata da CUDA (consigliati almeno 8-12 GB VRAM).
  * **AMD:** GPU RDNA1, RDNA2 o RDNA3 (RX 5000 / 6000 / 7000 series).
  * **CPU:** Processore moderno con istruzioni AVX2 (minimo 16GB RAM di sistema).
* **Virtualizzazione**: Bare-Metal oppure Container **Proxmox LXC** (con GPU Pass-Through attivo).

---

## ⚠️ Disclaimer

Tutti gli script sono forniti "così come sono" (AS IS). Sebbene siano testati regolarmente, **sei caldamente invitato a leggere e comprendere il codice sorgente** prima di eseguirlo sui tuoi server, specialmente se in produzione. Non mi assumo alcuna responsabilità per eventuali malfunzionamenti o perdite di dati.

## 📄 Licenza

Questo progetto è distribuito sotto licenza **MIT**. Sei libero di utilizzare, modificare e distribuire il codice, mantenendo l'attribuzione originale.

---

## 📂 Struttura della Repository

```text
homelab-ai-deployer/
├── docs/                               # Documentazione e guide
│   ├── prepare_sandbox_baremetal.md
│   ├── prepare_sandbox_lxc.md
│   └── sandbox.md
├── script/                             # Script secondari e di utilità
│   ├── monitor.sh
│   ├── proxmox_lxc_sandbox_setup.sh
│   ├── purge-homelab-ai.sh
│   ├── sandbox_setup.sh
│   ├── setup_jupyter.sh
│   └── uninstall.sh
├── README.md                           # Documentazione generale (Italiano)
├── README_ENG.md                       # Documentazione generale (Inglese)
├── install.sh                          # Script di avvio rapido
├── main.sh                             # Router per rilevamento hardware
├── manager-amd.sh                      # TUI per gestione Controller AMD
├── manager-cpu.sh                      # TUI per gestione fallback CPU
├── manager-fine-tuning-nvidia.sh       # TUI per Fine-Tuning su NVIDIA
├── manager-nvidia.sh                   # TUI per gestione Controller NVIDIA
├── purge-homelab-ai.sh                 # Tool root-level di pulizia ambiente
└── uninstall.sh                        # Tool root-level di rimozione servizi
