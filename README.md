# Unsloth Suite Manager 🚀

[![Shell Script](https://img.shields.io/badge/shell_script-bash-blue.svg)](https://www.gnu.org/software/bash/)
[![Linux](https://img.shields.io/badge/OS-Debian_%2F_Ubuntu-orange.svg)](https://www.debian.org/)
[![NVIDIA CUDA](https://img.shields.io/badge/NVIDIA-CUDA-green.svg)](https://developer.nvidia.com/cuda-toolkit)

**Unsloth Suite Manager** è uno script Bash avanzato e interattivo progettato per automatizzare la configurazione, l'installazione e la rimozione di ambienti di intelligenza artificiale su distribuzioni **Debian** e **Ubuntu**. 

Supporta nativamente sia ambienti **Bare-Metal / VM** che **Container LXC (es. Proxmox VE)** con accelerazione GPU NVIDIA.

---

## 🛠️ Servizi Inclusi

1. **Unsloth & Unsloth Studio** (Porta `8888`): Ambiente JupyterLab ottimizzato per il fine-tuning efficiente di Large Language Models (LLM) tramite PyTorch e Unsloth.
2. **OpenCode AI Web Service** (Porta `8000`): Servizio web per l'assistenza alla programmazione e sviluppo assistito da IA.

---

## ⚙️ Caratteristiche Principali

* **Rilevamento Ambiente Intelligente:** Riconosce automaticamente se è in esecuzione su un server fisico/VM o all'interno di un container LXC (configurando correttamente i driver userspace e il toolkit CUDA).
* **Gestione Avanzata Repository NVIDIA:** Aggira i blocchi di sicurezza moderni di APT legati alle firme SHA1 legacy e alla sincronizzazione dei mirror.
* **Interfaccia Guidata in Tempo Reale:** Mostra un pannello di controllo pulito con l'avanzamento dei log in tempo reale.
* **Package Manager Moderno:** Sfrutta **Astral UV** per velocizzare drasticamente l'installazione delle dipendenze Python.
* **Gestione a Demoni (Systemd):** Tutti i servizi vengono configurati come servizi di sistema per garantire l'avvio automatico e la persistenza in background.

---

## 📥 Requisiti di Sistema

* **Sistema Operativo:** Debian 12+ o Ubuntu 22.04 / 24.04 (consigliato OS pulito).
* **Hardware:** GPU NVIDIA con supporto CUDA (consigliata VRAM adeguata).
* **Privilegi:** Accesso root (`sudo`).

---

Lo script ti guiderà attraverso:

La configurazione della localizzazione di sistema (en_US.UTF-8).

La scelta se Installare o Disinstallare i servizi.

La selezione dei singoli componenti (Unsloth Studio, OpenCode AI o entrambi).

🧹 Rimozione (Disinstallazione)
Eseguendo nuovamente lo script (sudo ./manager.sh) e selezionando l'opzione 2 (Disinstalla), potrai ripulire completamente il sistema rimuovendo ambienti virtuali, file di configurazione e servizi systemd associati in modo pulito.



## 🚀 Istruzioni per l'uso

### 1. Clona o scarica lo script
Salva lo script principale con il nome `manager.sh` nella tua macchina di destinazione.

### 2. Rendi lo script eseguibile
Apri il terminale ed esegui il comando:
```bash
chmod +x manager.sh


Lo script ti guiderà attraverso:

La configurazione della localizzazione di sistema (en_US.UTF-8).

La scelta se Installare o Disinstallare i servizi.

La selezione dei singoli componenti (Unsloth Studio, OpenCode AI o entrambi).

🧹 Rimozione (Disinstallazione)
Eseguendo nuovamente lo script (sudo ./manager.sh) e selezionando l'opzione 2 (Disinstalla), potrai ripulire completamente il sistema rimuovendo ambienti virtuali, file di configurazione e servizi systemd associati in modo pulito.

📄 Licenza
Distribuito sotto licenza MIT. Sentiti libero di forkare, migliorare e adattare questo script alle tue esigenze.
