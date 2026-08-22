# 🛠️ Architettura dei Servizi Homelab AI

Questa tabella riassume l'ecosistema dei servizi implementabili all'interno dell'infrastruttura, suddividendoli tra i componenti di produzione (Ollama / Open WebUI), l'ambiente di ricerca e laboratorio (Unsloth / Jupyter) e gli agenti di automazione.

| Area di Servizio | Modulo / Funzione | Backend / Motore Ideale | Integrazione nell'Homelab | Scopo Principale |
| :--- | :--- | :--- | :--- | :--- |
| **OCR & Vision** | Estrazione testo, tabelle e analisi layout da fatture/PDF storici | Ollama (`qwen2-vl`, `minicpm-v`) / Unsloth (Fine-tuning OCR) | Open WebUI (nativo multimodale) o script Jupyter custom | Digitalizzazione e catalogazione automatica di archivi cartacei e documentali. |
| **Voice & Audio** | Speech-to-Text (STT) e Text-to-Speech (TTS) | Whisper (Python API) + Ollama per la sintesi | Microservizio integrato nel backend o collegato a Open WebUI | Trascrizione di riunioni, interazione vocale diretta e generazione di podcast o risposte audio. |
| **Ricerca Web & RAG** | Navigazione web in tempo reale e interrogazione di archivi locali | Ollama (`bge-m3` + `deepseek-r1`/`qwen2.5`) + SearXNG | Open WebUI (Knowledge base & Web Search) o pipeline LangChain | Fornire risposte basate su documenti aziendali interni o dati aggiornati presi dal web. |
| **Video Processing** | Estrazione fotogrammi, object detection e riassunto flussi | Python (`ffmpeg` / OpenCV) + Ollama Vision | Script schedulati via Bash/Jupyter Lab | Analisi di sequenze video o video di sorveglianza/trasporti (es. integrazione TMS). |
| **Vibe Coding & Git** | Generazione di codice on-the-fly, refactoring, code review e gestione repository | Unsloth (`qwen2.5-coder-7b`) + Codex CLI / VS Code SSH | Estensione VS Code remota + Repository GitHub locali | Sviluppo software assistito da AI, scrittura rapida di script di sistema e gestione commit/PR. |
| **Agente Locale (OpenClaw)** | Agente autonomo 24/7 per automazione di task complessi su Telegram/WhatsApp | OpenClaw (Node.js/TypeScript) collegato a Ollama o API locali | Container Docker o demone systemd su Debian 13 | Esecuzione autonoma di flussi di lavoro, notifiche eventi critici, gestione messaggistica e task multi-step. |
| **Fine-Tuning & Data Science** | Adattamento e addestramento custom di modelli open-source (QLoRA) | Unsloth + Jupyter Lab su RTX 3060 Ti | Ambiente di laboratorio isolato con gestione VRAM ottimizzata | Specializzare i modelli sul gergo tecnico locale, dialetti o cataloghi specifici di editoria/libri rari. |
