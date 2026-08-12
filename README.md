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

* ⚡ **Installazione Automatica Controller**: Interfaccia TUI guidata in tempo reale con monitoraggio avanzato del log via `manager.sh`.
* 🛡️ **Setup Automatizzato Sandbox**: Script helper dedicato (`sandbox_setup.sh`) per la preparazione lampo di nodi esecutori LXC/VM remoti.
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
|  - ComfyUI        (Porta 8188)  |                             |    sandbox_setup.sh             |
|  - OpenCode AI    (Porta 8000)  |                             |  - Python 3 / OpenSSH           |
|  - Code Runner    (Porta 9000)  |<----------------------------|  - Nessun accesso GPU Host / LAN |
+---------------------------------+        stdout / stderr      +---------------------------------+
