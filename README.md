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

### Come funziona? (Generazione ed Esecuzione Automatica)

Il sistema sfrutta un'architettura a due componenti per unire **automazione totale** e **massima sicurezza**:

1. **Controller (L'Ingegneria ed Elaborazione AI - con GPU):**  
   È il "cervello" della tua infrastruttura. Qui girano i modelli AI (tramite OpenCode AI e Unsloth Studio) che analizzano le tue richieste, **ragionano e generano il codice** sfruttando la potenza della tua scheda video.

2. **Sandbox (L'Esecutore Sicuro):**  
   È un container LXC o macchina virtuale isolata dal resto della rete. Quando l'IA genera uno script o un comando, **lo invia ed esegue automaticamente all'interno della Sandbox**. L'IA riceve il risultato dell'esecuzione (o eventuali errori) e può correggerlo da sola, il tutto senza toccare né rischiare di danneggiare il tuo server principale.

> **Nota:** Questo progetto è attualmente in fase di sviluppo attivo (**Work in Progress**). Alcune funzionalità e configurazioni potrebbero subire variazioni.

---

## Caratteristiche Principali

* **Installazione Automatica Controller**: Interfaccia TUI guidata in tempo reale con monitoraggio avanzato del log via `manager.sh`.
* **Setup Automatizzato Sandbox**: Script helper dedicato (`sandbox_setup.sh`) per la preparazione lampo di nodi esecutori LXC/VM remoti.
* **Stack GPU & CUDA Completo**: Installazione e configurazione automatica dei driver NVIDIA, CUDA Toolkit e NVIDIA Container Toolkit (con fix nativi per container LXC e gestione trust SHA1 per Debian 12 / Trixie).
* **Unsloth Studio**: Ambiente di sviluppo per Fine-Tuning & Inferenza LLM ad alte prestazioni via Astral `uv` con Jupyter Lab (`:8888`).
* **OpenCode AI Web**: Piattaforma web di sviluppo assistito da intelligenza artificiale (`:8000`).
* **Code Runner API (Sandbox Execution)**: Microservizio FastAPI (`:9000`) per eseguire codice generato dall'AI in un ambiente remoto isolato via SSH.
* **Gestione & Uninstall Pulito**: Script integrato per la rimozione selettiva o totale dei servizi e delle unità `systemd`.

---

## Servizi Esposti

| Servizio | Porta | Descrizione |
| :--- | :---: | :--- |
| **Unsloth Studio** | `8888` | Interfaccia Jupyter Lab per Fine-Tuning & Inferenza LLM |
| **OpenCode AI** | `8000` | Interfaccia Web OpenCode |
| **Code Runner API** | `9000` | Endpoint REST FastAPI per l'esecuzione remota sicura in Sandbox |

---

## Pre-requisiti Proxmox Host (GPU Passthrough)

Se stai eseguendo lo script all'interno di un container **Proxmox LXC**, assicurati che l'Host Proxmox abbia i driver NVIDIA installati e che il file di configurazione del container (`/etc/pve/lxc/<CONTAINER_ID>.conf`) contenga le regole per il passthrough dei nodi di device NVIDIA.

**Importante:** In Proxmox LXC, ogni risorsa hardware passata al container deve essere dichiarata specificando i device con un indice numerico progressivo e consecutivo (`dev0`, `dev1`, `dev2`, e così via). Se nel tuo sistema sono presenti più schede video o ulteriori nodi `/dev/nvidia*`, devi continuare ad aggiungere i dispositivi incrementando progressivamente il prefisso numerico (`dev6`, `dev7`, ecc.) senza saltare alcun indice.

```ini
# Aggiungere al file /etc/pve/lxc/<CONTAINER_ID>.conf sull'host Proxmox.
# I device devono essere aggiunti in ordine numerico progressivo e consecutivo:
dev0: /dev/nvidia0,gid=44
dev1: /dev/nvidiactl,gid=44
dev2: /dev/nvidia-uvm,gid=44
dev3: /dev/nvidia-uvm-tools,gid=44
dev4: /dev/nvidia-caps/nvidia-cap1,gid=44
dev5: /dev/nvidia-caps/nvidia-cap2,gid=44

# Se sono presenti ulteriori GPU o nodi di sistema, prosegui la numerazione consecutivamente:
# dev6: /dev/nvidia1,gid=44
# dev7: /dev/nvidia2,gid=44
