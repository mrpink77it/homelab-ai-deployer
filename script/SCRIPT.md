# Homelab AI & Local LLM Deployment Scripts

Una raccolta di script Bash automatizzati per il provisioning, la gestione e l'ottimizzazione di ambienti AI locali, motori di inferenza LLM, modelli di embedding e interfacce web su architetture NVIDIA, AMD e CPU.

---

## 📜 Panoramica Script

| Script | Sistema / Piattaforma | Descrizione Sintetica |
| :--- | :--- | :--- |
| `download_models.sh` | Generico (Ollama) | Utility per il download batch e l'aggiornamento automatico di modelli Ollama con verifica preventiva di quelli già installati. |
| `Install_AnythingLLM_Omarchy.sh` | Arch / Debian | Setup completo headless di AnythingLLM: isolamento Node.js v20 LTS, gestione backup/ripristino dello storage e servizio `systemd`. |
| `install-coding-workstation-ubuntu.sh` | Ubuntu 24.04 LTS | Provisioning completo per workstation AI Dual-GPU (AMD Vulkan + NVIDIA CUDA). Compila `llama.cpp` e configura helper CLI e Aider. |
| `install_tei_debian_cpu.sh` | Debian (CPU) | Installazione da sorgente tramite Rust/Cargo del motore HuggingFace *Text Embeddings Inference* (TEI) con modello `bge-m3`. |
| `install_tei_omarchy_cpu.sh` | Omarchy / Arch (CPU) | Deployment bare-metal di TEI per CPU con configurazione utente dedicato, cache Hugging Face e servizio `systemd`. |
| `manager-amd.sh` | Ubuntu / Debian (AMD) | Console di gestione TUI (Whiptail) per stack AMD: build `llama.cpp` Vulkan, Open WebUI e orchestrazione modelli GGUF. |
| `manager-cpu.sh` | Linux (CPU) | Manager TUI per infrastrutture CPU-only: auto-tuning dei thread/RAM, ottimizzazione AVX2/AVX-512 e installazione Open WebUI via `uv`. |
| `manager-finetuning.sh` | Debian / Ubuntu (NVIDIA) | Suite di gestione per training e fine-tuning: installazione driver NVIDIA, CUDA, Unsloth Studio e dashboard di telemetria GPU in tempo reale. |
| manager-nvidia.sh | Debian / Ubuntu (NVIDIA) | Console TUI (Whiptail) per stack NVIDIA: installazione driver/CUDA, compilazione llama.cpp (CUDA), Open WebUI, Jupyter/Unsloth e gestione servizi/porte. |
| manager-wsl-amd.sh | WSL2 / Windows (AMD) | Manager TUI per ambienti WSL2 con GPU AMD (Vulkan): build llama.cpp, setup Open WebUI e gestione modelli. |
| manager-wsl-cpu.sh | WSL2 / Windows (CPU) | Console TUI per deployment AI su WSL2 CPU-only: auto-tuning delle risorse CPU/RAM, build llama.cpp e integrazione Open WebUI. |
| manager-wsl-nvidia.sh | WSL2 / Windows (NVIDIA) | Manager TUI per WSL2 con GPU NVIDIA (CUDA): build di llama.cpp, configurazione Open WebUI e gestione dei servizi systemd. |
| monitor.sh | Linux / Proxmox LXC | Dashboard web in tempo reale (FastAPI/WebSocket) per il monitoraggio di CPU, RAM e VRAM/carico GPU (NVIDIA & AMD). |
| ollama_bench.py | Generico (Ollama / Python) | Suite di benchmark per modelli Ollama: misurazione tok/s (prompt/generazione), monitoraggio VRAM/RAM e generazione di grafici e report. |
| proxmox_lxc_sandbox_setup.sh | Proxmox VE | Wizard interattivo per il provisioning automatico di container LXC (Debian/Ubuntu) ottimizzati come ambienti sandbox per l'AI. |
---

## 🛠️ Dettaglio Funzionalità

### Gestione Motori & Modelli
* **Inference Engine Setup:** Compilazione nativa e ottimizzata di `llama.cpp` per backend CUDA, Vulkan o estensioni vettoriali CPU (AVX2/AVX-512).
* **Text Embeddings Inference (TEI):** Script dedicati per la compilazione e il tuning delle performance del modello di embedding `BAAI/bge-m3`.

### Interfacce & Strumenti
* **Frontend Web:** Deployment e configurazione di AnythingLLM, Open WebUI e Unsloth Studio collegati direttamente alle API locali.
* **TUI & Telemetria:** Interfacce a riga di comando per il monitoraggio hardware (temperatura GPU, VRAM, consumo energetico) e gestione delle porte dei servizi.

---

## 🚀 Guida Rapida all'Uso

1. Clona il repository e accedi alla cartella:
   ```bash
   git clone <url-repository>
   cd <nome-cartella>
