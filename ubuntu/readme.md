# Progetto: Workstation AI Ibrida Locale (Ubuntu 26.04)

## 1. Descrizione di Massima del Progetto
Questo progetto mira alla realizzazione di un ecosistema di Intelligenza Artificiale locale, completo, autonomo e distribuito, basato su hardware consumer di fascia alta. L'infrastruttura sfrutta in modo sinergico e congiunto due schede video differenti (**AMD RX 5700 XT** e **NVIDIA RTX 3060 Ti**, entrambe con 8 GB di VRAM), un processore multicore (**Intel i7-13700F a 24 thread**) e un'ampia dotazione di memoria (**64 GB di RAM DDR4**). 

L'obiettivo è disaccoppiare i carichi di lavoro tramite un livello di orchestrazione intelligente (routing, offloading e gestione della memoria vettoriale in RAM), permettendo di eseguire in locale task complessi che spaziano dal coding intensivo alla generazione di immagini, visione artificiale, trascrizione vocale, elaborazione audio/video e gestione semantica di una Wiki personale, azzerando la dipendenza da API cloud esterne e massimizzando l'efficienza energetica e computazionale.

---

## 2. Specifiche della Macchina (Hardware & Software)
- **Modello Hardware:** ASUS PRIME H770-PLUS D4
- **Memoria di Sistema:** 64.0 GiB RAM DDR4
- **Processore:** 13th Gen Intel® Core™ i7-13700F × 24 thread
- **GPU Principale:** AMD Radeon™ RX 5700 XT (8 GB VRAM, Vulkan)
- **GPU Secondaria:** NVIDIA GeForce RTX™ 3060 Ti (8 GB VRAM, CUDA)
- **Capacità Disco:** 4.9 TB
- **Sistema Operativo:** Ubuntu 26.04.1 LTS
- **Versione Kernel:** Linux 7.0.0-38-generic

---

## 3. Tassonomia dei Compiti e Software di Supporto
| Macro-Area | Task / Funzione | Software / Programma Utilizzato |
| :--- | :--- | :--- |
| **Generazione e Sintesi Testuale** | Scrittura tecnica e creativa, sintesi (summarization) di documenti lunghi e traduzione/localizzazione. | `llama.cpp` / `llama-server` |
| **Analisi ed Estrazione Dati** | Classificazione di testi, sentiment analysis, parsing strutturato (JSON) ed estrazione di entità (NER). | Script Python custom / API locali |
| **Sviluppo Software (Coding)** | Generazione di codice, debugging, refactoring e code review di codebase estese. | Unsloth / Server API dedicati |
| **Ragionamento e Pianificazione** | Problem solving logico avanzato (Chain-of-Thought) e scomposizione di obiettivi complessi in task sequenziali. | Modelli di ragionamento specializzati (es. famiglia `DeepSeek-R1`) |
| **Automazione e Conoscenza (RAG)** | Interrogazione semantica dinamica di una Wiki o di una base di memoria interna e function calling. | Qdrant / Chroma / Framework di orchestrazione Python |
| **Generazione Immagini** | Creazione di concept art, texture, grafiche e rendering fotorealistico o stilizzato da prompt testuali. | ComfyUI / AUTOMATIC1111 |
| **Visione Artificiale (VLM)** | Analisi visiva di screenshot, lettura di diagrammi di architettura software, OCR avanzato e interpretazione UI. | Qwen2-VL / LLaVA / Moondream2 |
| **Trascrizione Vocale (STT)** | Conversione in tempo reale di memo audio, riunioni o comandi vocali in testo scritto. | Faster-Whisper |
| **Sintesi Vocale (TTS)** | Clonazione vocale, lettura espressiva e sintesi vocale rapida per risposte audio. | XTTS-v2 / Piper |
| **Musica e Sound Design** | Generazione di tracce musicali, jingle, pattern ritmici ed effetti sonori da descrizioni testuali. | Meta MusicGen / AudioCraft / Stable Audio |
| **Generazione Video** | Trasformazione di immagini statiche in clip video in movimento o creazione di brevi animazioni da testo. | Stable Video Diffusion (SVD) / LTX-Video |

---

## 4. Mappa di Allocazione delle Risorse Hardware
| Funzione / Task | NVIDIA RTX 3060 Ti (CUDA) | AMD RX 5700 XT (Vulkan) | CPU Intel i7 (24t) + 64 GB RAM |
| :--- | :--- | :--- | :--- |
| **Sviluppo Software (Coding)** | **Principale:** Gestione server Unsloth per coding intensivo (`Qwen2.5-Coder`) | - | - |
| **Generazione Immagini** | **Principale:** Esecuzione di ComfyUI, Stable Diffusion e Flux | - | - |
| **Ragionamento e Pianificazione** | Esecuzione di modelli di ragionamento avanzato (`DeepSeek-R1`) | - | Hybrid offloading per modelli di grandi dimensioni (14B/32B) |
| **Generazione e Sintesi Testuale** | - | **Principale:** `llama-server` per chat rapide, riassunti e servizi generali | Supporto per esecuzione distribuita o modelli di taglia superiore |
| **Visione Artificiale (VLM)** | - | Esecuzione di modelli visivi (`Qwen2-VL` / `LLaVA`) tramite Vulkan | - |
| **Trascrizione Vocale (STT)** | - | - | **Principale:** Esecuzione parallela di Faster-Whisper sui 24 core |
| **Sintesi Vocale (TTS)** | - | - | **Principale:** Esecuzione di Piper / XTTS-v2 |
| **Musica e Sound Design** | Esecuzione di Meta MusicGen / Stable Audio | - | - |
| **Generazione Video** | Esecuzione di Stable Video Diffusion / LTX-Video | - | - |
| **Automazione e Conoscenza (RAG)** | - | Esecuzione di modelli di embedding leggeri | **Principale:** Database vettoriale in-memory (Qdrant) e parsing documenti |

---

## 5. Modelli Quantizzati in Formato GGUF Consigliati
| Task / Funzione | Modello GGUF 1 (Consigliato) | Modello GGUF 2 (Alternativa) |
| :--- | :--- | :--- |
| **Sviluppo Software (Coding)** | `unsloth/Qwen2.5-Coder-7B-Instruct-GGUF` (Q4_K_M) | `bartowski/Qwen2.5-Coder-14B-Instruct-GGUF` (Q4_K_M) |
| **Generazione Immagini** | `city96/FLUX.1-dev-gguf` (Q4_K) | `second-state/FLUX.1-schnell-GGUF` (Q4_0) |
| **Ragionamento e Pianificazione** | `bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF` (Q4_K_M) | `unsloth/DeepSeek-R1-Distill-Qwen-14B-GGUF` (Q4_K_M) |
| **Generazione e Sintesi Testuale** | `bartowski/Qwen2.5-7B-Instruct-GGUF` (Q4_K_M) | `bartowski/Llama-3.1-8B-Instruct-GGUF` (Q4_K_M) |
| **Visione Artificiale (VLM)** | `bartowski/Qwen2.5-VL-7B-Instruct-GGUF` (Q4_K_M) | `unsloth/Llama-3.2-11B-Vision-Instruct-GGUF` (Q4_K_M) |
| **Trascrizione Vocale (STT)** | `ggerganov/whisper.cpp` (`ggml-large-v3-q5_0.bin`) | `ggerganov/whisper.cpp` (`ggml-base.en.bin`) |
| **Sintesi Vocale (TTS)** | `rhasspy/piper` (Modelli ONNX quantizzati INT8) | `coqui/XTTS-v2` (Versioni ottimizzate 4-bit) |
| **Musica e Sound Design** | `facebook/musicgen-medium` (Versione INT8 quantizzata) | `facebook/audiocraft` (Checkpoint ottimizzati) |
| **Generazione Video** | `stabilityai/stable-video-diffusion-img2vid-xt` (INT8) | `Lightricks/LTX-Video` (Versioni quantizzate VRAM-safe) |
| **Automazione e Conoscenza (RAG)** | `bartowski/bge-large-en-v1.5-GGUF` (Q8_0) | `mradermacher/embeddinggemma-270m-GGUF` (F16) |