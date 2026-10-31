# Workstation AI - W.I.P. - NOT FOR PRODUCTION USE

---

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

## Modelli Quantizzati in Formato GGUF Consigliati
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
