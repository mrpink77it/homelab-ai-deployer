# 🦥 Homelab AI Deployer

[![Status WIP](https://img.shields.io/badge/status-Work_in_Progress-yellow.svg)](https://github.com/mrpink77it/homelab-ai-deployer)
[![shell script](https://img.shields.io/badge/shell_script-bash-1f425f.svg)](https://www.gnu.org/software/bash/)
[![OS](https://img.shields.io/badge/OS-Debian_%2F_Ubuntu-orange.svg)](https://debian.org)
[![NVIDIA CUDA](https://img.shields.io/badge/NVIDIA-CUDA-76B900.svg?logo=nvidia&logoColor=white)](https://developer.nvidia.com/cuda-toolkit)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> **`mrpink77it/homelab-ai-deployer`** è uno script Bash automatizzato ("zero-config") progettato per configurare, gestire e distribuire un ambiente completo di AI Generativa, LLM Fine-Tuning e sviluppo su macchine Linux e container **Proxmox LXC**.

> ⚠️ **Nota:** Questo progetto è attualmente in fase di sviluppo attivo (**Work in Progress**). Alcune funzionalità e configurazioni potrebbero subire variazioni.

---

## 📸 Caratteristiche Principali

* ⚡ **Installazione Automatica**: Interfaccia TUI guidata in tempo reale con monitoraggio avanzato del log.
* 🎮 **Stack GPU & CUDA Completo**: Installazione e configurazione automatica dei driver NVIDIA, CUDA Toolkit e NVIDIA Container Toolkit (con fix nativi per container LXC e gestione trust SHA1 per Debian 12 / Trixie).
* 🦥 **Unsloth Studio**: Ambiente di sviluppo per Fine-Tuning & Inferenza LLM ad alte prestazioni via Astral `uv` con Jupyter Lab (`:8888`).
* 🎨 **ComfyUI**: Piattaforma nodale per la generazione di immagini e video AI (`:8188`).
* 💻 **OpenCode AI Web**: Piattaforma web di sviluppo assistito da intelligenza artificiale (`:8000`).
* 🛡️ **Code Runner API (Sandbox Execution)**: Microservizio FastAPI (`:9000`) per eseguire codice generato dall'AI in un ambiente remoto isolato via SSH.
* 🧹 **Gestione & Uninstall Pulito**: Script integrato per la rimozione selettiva o totale dei servizi e delle unità `systemd`.

---

## 📊 Servizi Esposti

| Servizio | Porta | Descrizione |
| :--- | :---: | :--- |
| **Unsloth Studio** | `8888` | Interfaccia Jupyter Lab per Fine-Tuning & Inferenza LLM |
| **ComfyUI** | `8188` | Interfaccia grafica nodale per Generative AI (Images/Video) |
| **OpenCode AI** | `8000` | Interfaccia Web OpenCode |
| **Code Runner API** | `9000` | Endpoint REST FastAPI per l'esecuzione remota sicura in Sandbox |

---

## 🚀 Avvio Rapido

### Clonazione ed Esecuzione

```bash
git clone [https://github.com/mrpink77it/homelab-ai-deployer.git](https://github.com/mrpink77it/homelab-ai-deployer.git)
cd homelab-ai-deployer
chmod +x manager.sh
sudo ./manager.sh
```

---

## 🧪 Architettura Sandbox & Execution

L'architettura separa nettamente il **Controller AI** (dove girano i modelli, le interfacce e la GPU) dal **Nodo Sandbox** dove viene eseguito il codice generato.

```text
+---------------------------------+             SSH             +---------------------------------+
|         CONTROLLER AI           |---------------------------->|          SANDBOX LXC/VM         |
|  - Unsloth Studio (Porta 8888)  |   Exec: python3 -c "..."    |  - Python 3                     |
|  - ComfyUI        (Porta 8188)  |                             |  - Ambiente isolato             |
|  - OpenCode AI    (Porta 8000)  |                             |  - Nessun accesso alla GPU Host  |
|  - Code Runner    (Porta 9000)  |<----------------------------|  - Nessun accesso alla LAN      |
+---------------------------------+        stdout / stderr      +---------------------------------+
```

### Configurazione Autenticazione SSH (Controller ➔ Sandbox)

1. **Genera la chiave SSH sul Controller** (se non presente):
   ```bash
   ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
   ```

2. **Copia la chiave sulla Sandbox**:
   ```bash
   ssh-copy-id -i /root/.ssh/id_ed25519.pub root@<IP_SANDBOX>
   ```

3. **Invia una richiesta di test all'API Code Runner (`:9000`)**:
   ```bash
   curl -X POST http://localhost:9000/execute \
     -H "Content-Type: application/json" \
     -d '{
       "code": "import sys; print(f\"Hello Sandbox! Python: {sys.version}\")",
       "sandbox_ip": "<IP_SANDBOX>"
     }'
   ```

---

## 🔍 Verifica dell'Installazione

Dopo il completamento dello script, puoi verificare il corretto riconoscimento della GPU e di CUDA eseguendo:

```bash
/root/unsloth_env/bin/python3 -c "import torch; print('CUDA disponibile:', torch.cuda.is_available()); print('GPU:', torch.cuda.get_device_name(0))"
```

### Gestione dei Servizi Systemd

Puoi controllare i singoli servizi tramite `systemctl`:

* **Unsloth Studio**: `systemctl status unsloth-studio.service`
* **ComfyUI**: `systemctl status comfyui.service`
* **OpenCode AI**: `systemctl status opencode.service`
* **Code Runner API**: `systemctl status code-runner.service`

---

## 🛠️ Requisiti di Sistema

* **Sistema Operativo**: Debian 12 (Bookworm / Trixie) o Ubuntu 22.04 LTS / 24.04 LTS.
* **Privilegi**: Accesso Root o utente con permessi `sudo`.
* **Hardware GPU**: GPU NVIDIA supportata (consigliati almeno 12 GB VRAM per Fine-Tuning o ComfyUI).
* **Virtualizzazione**: Bare-Metal oppure Container **Proxmox LXC** (Unprivileged/Privileged con GPU Pass-Through attivo).

---

## 📁 Struttura della Repository

* `manager.sh`: Script principale di installazione, configurazione e manutenzione.
* `sandbox.md`: Guida dettagliata sull'architettura, API e configurazione della Sandbox.
* `README.md`: Documentazione generale del progetto.

---

## 📄 Licenza

Questo progetto è rilasciato sotto licenza [MIT](LICENSE).
