# Unsloth Suite Manager 🚀

[![Shell Script](https://img.shields.io/badge/shell_script-bash-blue.svg)](https://www.gnu.org/software/bash/)
[![Linux](https://img.shields.io/badge/OS-Debian_%2F_Ubuntu-orange.svg)](https://www.debian.org/)
[![NVIDIA CUDA](https://img.shields.io/badge/NVIDIA-CUDA-green.svg)](https://developer.nvidia.com/cuda-toolkit)

**Unsloth Suite Manager** è uno script Bash avanzato per automatizzare la configurazione e la gestione di ambienti di intelligenza artificiale su **Debian** e **Ubuntu** (sia su **macchine fisiche/VM** che su **container LXC** come Proxmox).

Include un'architettura **Controller-Sandbox** per permettere all'IA di eseguire codice in totale sicurezza su un nodo separato.

---

## 🛠️ Servizi Inclusi nel Controller
1. **Unsloth & Unsloth Studio** (Porta `8888`): JupyterLab ottimizzato per il fine-tuning di LLM.
2. **OpenCode AI Web Service** (Porta `8000`): Interfaccia web per lo sviluppo assistito da IA.
3. **Code Runner API** (Porta `9000`): Servizio FastAPI per l'esecuzione remota e sicura del codice generato dall'IA.

---

## 🚀 Guida Rapida all'Installazione

### Sul Nodo Controller (Macchina Principale)
Clona o scarica il repository, rendi eseguibile lo script di installazione e avvialo come `root`:

```bash
chmod +x manager.sh
sudo ./manager.sh
