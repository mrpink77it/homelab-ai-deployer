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
