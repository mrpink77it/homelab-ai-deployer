# Homelab AI Deployer

> **`mrpink77it/homelab-ai-deployer`** è uno script Bash automatizzato ("zero-config") progettato per configurare, gestire e distribuire un ambiente completo di AI Generativa, LLM Fine-Tuning e sviluppo su macchine Linux, server Bare-Metal e container **Proxmox LXC**.

---

## Architecture & Hardware Compatibility

Il progetto supporta un'architettura **Multi-Backend** in grado di rilevare automaticamente l'hardware grafico installato e selezionare lo stack software ottimale:

```text
                               +-----------------------+
                               |        main.sh        |
                               | (Hardware Discovery)  |
                               +-----------+-----------+
                                           |
                    +----------------------+----------------------+
                    |                                             |
                    v                                             v
         [ GPU NVIDIA Rilevata ]                        [ GPU AMD Rilevata ]
                    |                                             |
            Esegue manager.sh                             Esegue manager-amd.sh
                    |                                             |
             +--------------+                +--------------------+--------------------+
             | CUDA / vLLM  |                |                    |                    |
             +--------------+                v                    v                    v
                                     [ ROCm Ufficiale ]   [ Vulkan / llama.cpp ]   [ ROCm Experimental ]
                                     (RX 6000/7000 Series)   (RX 5000 / RDNA1)      (RX 5700 XT Override)
```

### Matrice di Supporto GPU

| Produttore | Architettura / Schede | Backend Selezionato | Note & Performance |
| :--- | :--- | :--- | :--- |
| **NVIDIA** | GTX / RTX / Tesla (T4, A100, ecc.) | **CUDA / vLLM** | Supporto nativo completo, massimo throughput ed accelerazione PyTorch. |
| **AMD** | RDNA 2 / RDNA 3 (RX 6000 / 7000) | **ROCm Ufficiale** | Supporto nativo bare-metal via PyTorch ROCm (`rocm-hip-sdk`). |
| **AMD** | RDNA 1 (RX 5000 / 5700 XT) | **Vulkan (llama.cpp)** | **Raccomandato:** Massima stabilità via API Vulkan senza rischio crash/OOM. |
| **AMD** | RDNA 1 (RX 5700 / 5700 XT) | **ROCm Experimental** | Utilizza l'override `HSA_OVERRIDE_GFX_VERSION=10.3.0` per PyTorch. |

---

## Avvio Rapido

### Setup del Controller AI (Host Principale)

Copiare ed incollare questo comando per eseguire l'installazione. Eseguire come root (su) o super user (sudo)

```bash
wget -q https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/install.sh && chmod +x install.sh &&  ./install.sh```

```

---

## Architettura Sandbox & Provisioning (`sandbox_setup.sh`)

L'architettura separa nettamente il **Controller AI** (dove girano i modelli, le interfacce e la GPU) dal **Nodo Sandbox** (LXC/VM separata) dove viene eseguito il codice generato dall'AI in un contesto confinato.

```text
+---------------------------------+              SSH              +---------------------------------+
|          CONTROLLER AI          |------------------------------>|          SANDBOX LXC/VM         |
|  - Unsloth Studio (Porta 8888)  |   Exec: python3 -c "..."      |  - Configurato da               |
|  - OpenCode AI    (Porta 8000)  |                               |    sandbox_setup.sh             |
|  - Code Runner    (Porta 9000)  |<------------------------------|  - Python 3 / OpenSSH             |
+---------------------------------+        stdout / stderr        +---------------------------------+
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

## Funzionamento degli Installer (`manager.sh` / `manager-amd.sh`)

In base all'hardware rilevato da `main.sh`, verrà avviata l'interfaccia di gestione specifica. Entrambi gli script offrono la medesima struttura TUI a menu per la gestione completa dell'ambiente.

### Menu NVIDIA (`manager.sh`)
* **`1) INSTALLA Servizi`**: Installazione automatica completa (Driver GPU, CUDA Toolkit, Unsloth, OpenCode AI, Code Runner API).
* **`2) VERIFICA Stato`**: Controllo dello stato dei servizi `systemd` e della disponibilità GPU via PyTorch/CUDA.
* **`3) AGGIORNA Componenti`**: Git pull e aggiornamento dipendenze per OpenCode AI e Unsloth.
* **`4) CONFIGURA Sandbox`**: Helper interattivo per la gestione ed il test dell'endpoint API remota.
* **`5) DISINSTALLA`**: Rimozione completa delle directory, configurazioni ed unità `systemd`.

### Menu AMD (`manager-amd.sh`)
Offre un menu TUI del tutto speculare a `manager.sh` (Installazione, Verifica, Aggiornamento, Sandbox, Disinstallazione), integrando in fase d'installazione la selezione guidata del backend per GPU AMD:

* **`1) INSTALLA Servizi`**: Avvia l'installatore interattivo chiedendo di scegliere lo stack software desiderato prima di distribuire Unsloth, OpenCode AI e Code Runner:
  1. **ROCm Ufficiale:** Installa `rocm-hip-sdk` e la build PyTorch ROCm ufficiale (consigliato per serie RX 6000/7000).
  2. **Vulkan (llama.cpp):** Compila nativamente `llama.cpp` con accelerazione `GGML_VULKAN=1` per la massima stabilità su schede RDNA 1 (RX 5700 / 5700 XT).
  3. **ROCm Sperimentale:** Applica l'environment hack `HSA_OVERRIDE_GFX_VERSION=10.3.0` ed imposta il runtime PyTorch ROCm per schede non ufficialmente supportate.
* **`2) VERIFICA Stato`**: Controllo dello stato dei servizi `systemd` e del rilevamento della GPU AMD via PyTorch ROCm o Vulkan.
* **`3) AGGIORNA Componenti`**: Git pull e aggiornamento dipendenze per gli strumenti AI ed i sorgenti `llama.cpp`.
* **`4) CONFIGURA Sandbox`**: Helper interattivo per l'associazione SSH ed il test delle chiamate API verso la Sandbox.
* **`5) DISINSTALLA`**: Rimozione completa di file, ambienti Python, repository e servizi `systemd` installati.

---

## Gestione Storage e Modelli

Per evitare di esaurire lo spazio sul disco root dell'LXC/VM, le directory principali di lavoro e di cache dei modelli sono organizzate come segue:

* **Cache Modelli HuggingFace / Unsloth**: `~/.cache/huggingface/hub`
* **Ambiente Virtuale Python (`uv`)**: `/root/unsloth_env`
* **Ambiente Virtuale JupyterLab**: `/opt/jupyter_env/`
* **Cartella di Lavoro Notebook**: `/root/notebooks/`
* **Servizio Code Runner**: `/opt/code_runner/`
* **Binary llama.cpp (Vulkan)**: `./llama.cpp/build/bin/`

---

## Verifica e Gestione Servizi

Dopo il completamento dello script, puoi verificare il corretto riconoscimento della GPU eseguendo:

### Per NVIDIA (CUDA):
```bash
/root/unsloth_env/bin/python3 -c "import torch; print('CUDA disponibile:', torch.cuda.is_available()); print('GPU:', torch.cuda.get_device_name(0))"
```

### Per AMD (ROCm):
```bash
/root/unsloth_env/bin/python3 -c "import torch; print('ROCm disponibile:', torch.cuda.is_available()); print('GPU:', torch.cuda.get_device_name(0))"
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
<summary><b><code>nvidia-smi</code> o <code>rocm-smi</code> funziona nell'LXC ma PyTorch restituisce <code>CUDA available: False</code></b></summary>

Assicurati che i permessi dei nodi device all'interno del container siano corretti. Esegui:
```bash
# Per NVIDIA:
chmod 666 /dev/nvidia*
# Per AMD:
chmod 666 /dev/kfd /dev/dri/*
```
Se usi un container **Unprivileged**, verifica che i permessi UID/GID tra Host e LXC siano mappati correttamente per i nodi GPU.
</details>

<details>
<summary><b>La RX 5700 XT va in Segmentation Fault / Kernel Panic in modalità ROCm</b></summary>

L'architettura RDNA 1 (`gfx1010`) non è ufficialmente supportata dalle versioni recenti di ROCm 6.x. Se la modalità *ROCm Experimental* risulta instabile sul tuo sistema, riesegui `./main.sh`, seleziona la GPU AMD e scegli la modalità **Vulkan / llama.cpp**, che garantisce stabilità al 100% senza crash.
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

Per l'inferenza e il fine-tuning con Unsloth o vLLM, assegna al container LXC/VM almeno **16 GB di RAM** e abilita uno swap di almeno **8 GB** nelle impostazioni di Proxmox.
</details>

---

## Roadmap & WIP Features

- [x] Router hardware automatico (`main.sh`) per la selezione del driver
- [x] Installatore automatico CUDA + NVIDIA Container Toolkit per LXC
- [x] Supporto nativo AMD GPU via **ROCm Ufficiale**, **Vulkan** e **ROCm Experimental**
- [x] Integrazione Unsloth Studio + OpenCode AI
- [x] Script idoneo ed idempotente `setup_jupyter.sh` per la gestione di JupyterLab
- [x] API Runner isolato con SSH Sandbox execution
- [x] Script di provisioning dedicato `sandbox_setup.sh` per nodi remoti
- [ ] Supporto multi-node Sandbox (gestione di più container esecutori in pool)
- [ ] Dashboard Web centralizzata per il monitoraggio GPU/RAM
- [ ] Integrazione opzionale ComfyUI (Generative AI Image/Video)



---

## Requisiti di Sistema

* **Sistema Operativo**: Debian 13 (Trixie) o Ubuntu 24.04 LTS.
* **Privilegi**: Accesso Root o utente con permessi `sudo`.
* **Hardware GPU**: 
  * **NVIDIA:** GPU supportata da CUDA (consigliati almeno 8-12 GB VRAM).
  * **AMD:** GPU RDNA1, RDNA2 o RDNA3 (RX 5000 / 6000 / 7000 series o modelli PRO).
* **Virtualizzazione**: Bare-Metal oppure Container **Proxmox LXC** (Unprivileged/Privileged con GPU Pass-Through attivo).

---

## ⚠️ Disclaimer

Tutti gli script sono forniti "così come sono" (AS IS). Sebbene siano utilizzati e testati regolarmente nel mio ambiente, **sei caldamente invitato a leggere e comprendere il codice sorgente** prima di eseguirlo sui tuoi server, specialmente se in produzione. Non mi assumo alcuna responsabilità per eventuali malfunzionamenti o perdite di dati.

## 📄 Licenza

Questo progetto è distribuito sotto licenza **MIT**. Sei libero di utilizzare, modificare e distribuire il codice, anche per scopi commerciali, mantenendo l'attribuzione originale.

---

## Struttura della Repository

```text

homelab-ai-deployer/
├── README.md                 # Documentazione generale e guida rapida
├── main.sh                   # Router principale per il rilevamento hardware (NVIDIA/AMD)
├── manager.sh                # Script TUI principale per la gestione del Controller NVIDIA
├── manager-amd.sh            # Script TUI principale per la gestione del Controller AMD (ROCm/Vulkan)
├── prepare_sandbox_baremetal.md # Guida alla configurazione Sandbox su Bare Metal / VM
├── prepare_sandbox_lxc.md    # Guida alla configurazione Sandbox LXC su Proxmox VE
├── proxmox_lxc_sandbox_setup.sh # Script Proxmox VE per la creazione automatica dell'LXC
├── sandbox.md                # Documentazione generale e requisiti delle Sandbox
├── sandbox_setup.sh          # Script di setup interno alla Sandbox (UTF-8, SSH, Python)
└── setup_jupyter.sh          # Script di installazione, verifica e gestione per JupyterLab

