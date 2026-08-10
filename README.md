# 🚀 UNSLOTH SUITE — Unsloth + ComfyUI + OpenCode Orchestration Suite

Una suite completa di gestione e orchestrazione automatizzata disegnata per deploy su **Debian** e **Ubuntu** (con supporto nativo per **Container LXC Proxmox** con GPU Pass-Through).

Questo strumento gestisce l'intero ciclo di vita dell'ambiente AI: dall'allineamento automatico dei driver NVIDIA/CUDA con l'Host Proxmox, fino all'installazione e orchestrazione via `systemd` di **Unsloth**, **ComfyUI** e **OpenCode Interpreter**.

---

## 📋 Indice
- [Caratteristiche Principali](#-caratteristiche-principali)
- [Prerequisiti e Requisiti di Sistema](#-prerequisiti-e-requisiti-di-sistema)
- [Requisiti LXC Proxmox (Pass-Through GPU)](#-requisiti-lxc-proxmox-pass-through-gpu)
- [Installazione Rapida](#-installazione-rapida)
- [Utilizzo dello Script](#-utilizzo-dello-script)
  - [Interfaccia Interattiva (CLI Menu)](#1-interfaccia-interattiva-cli-menu)
  - [Utilizzo da Riga di Comando (CLI Flags)](#2-utilizzo-da-riga-di-comando-cli-flags)
- [Architettura della Suite](#-architettura-della-suite)
- [Gestione dei Servizi Systemd](#-gestione-dei-servizi-systemd)

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

* **Sistema Operativo Supportato:** Debian 11/12+, Ubuntu 20.04 / 22.04 / 24.04 LTS.
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

-- VER: 0.0.1 --
