# Homelab AI Deployer - Technical Reference Manual
**Script:** `manager-finetuning.sh` (Versione 1.9.3)  
**Ambiente Target:** Bare-metal / LXC (Debian 13 / Ubuntu 24)  
**Hardware Ottimizzato:** NVIDIA RTX 3060 Ti / Architettura CUDA  

---

## 1. Architettura e Filosofia del Sistema

Il deployer è progettato per creare un ambiente di **Fine-Tuning e Inferenza AI ad alte performance** rigorosamente disaccoppiato, evitando duplicazioni di motori di inferenza e sfruttando l'efficienza nativa di C++ CUDA. 

### Vantaggi dell'Architettura:
1. **Llama.cpp nativo (Porta 8080):** Compilato direttamente dai sorgenti ufficiali (`ggml-org/llama.cpp`) tramite CMake con supporto CUDA (`-DGGML_CUDA=ON`). Espone un server API standard (`/v1`) super-ottimizzato per la VRAM.
2. **Gestione Centralizzata dei Modelli:** Tutti i file GGUF sono risiedono in una cartella condivisa (`/opt/homelab-ai/backend/models/1_LLM_Text/`), accessibile sia da llama.cpp che da qualsiasi altro tool di inferenza o benchmark senza duplicazioni di storage.
3. **Unsloth Studio Isolato (Porta 7860):** Installato in un virtual environment dedicato tramite `uv`, configurato per delegare interamente l'inferenza al server `llama.cpp` esterno esistente tramite binding HTTP (`http://127.0.0.1:8080`), senza avviare istanze duplicate di llama.cpp.

---

## 2. Struttura delle Directory

Lo script organizza il file system secondo una separazione netta tra i file di gestione, i driver, i log e i backend di produzione:

* `/opt/homelab-ai-deployer/`
  * `tools/`: Script di supporto e downloader (es. `8gbModelCUDA.sh`)
  * `drivers/`: Driver NVIDIA `.run` scaricati in locale per installazioni offline/ripetibili
  * `logs/`: Log dettagliati di installazione ed errore con timestamp
* `/opt/homelab-ai/backend/`
  * `llama.cpp/`: Sorgenti e binari compilati di Llama.cpp
  * `models/1_LLM_Text/`: Repository centrale dei modelli GGUF (es. `Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf`)
  * `unsloth/`: Ambiente virtuale Python isolato per Unsloth Studio

---

## 3. Analisi Dettagliata delle Fasi di Installazione

### Fase 1: Timezone, Locales, Driver NVIDIA & CUDA 13.2
* **Configurazione di Sistema:** Imposta automaticamente la timezone su `Europe/Rome` in modalità non-interattiva e rigenera i locales per supportare `en_US.UTF-8` e `it_IT.UTF-8`.
* **Dipendenze Base:** Installa pacchetti essenziali per la compilazione e il monitoraggio (`build-essential`, `cmake`, `git`, `htop`, `btop`, `nvtop`, `glances`, ecc.).
* **Rilevamento Ambiente (Bare-metal vs LXC):** 
  * Rileva se il sistema è un container LXC (es. Proxmox) o un sistema bare-metal.
  * In ambiente LXC, estrae la versione del driver dall'host e installa il driver `.run` con l'opzione `--no-kernel-modules`. Su bare-metal utilizza il supporto DKMS completo.
* **Toolkit CUDA 13.2:** Scarica il repository keyring ufficiale di NVIDIA, installa `cuda-toolkit-13-2` e configura le variabili d'ambiente globali (`PATH` e `CUDACXX`).

### Fase 2: Compilazione Llama.cpp & Gestione Centralizzata Modelli
* **Clonazione e CMake:** Clona o aggiorna il repository ufficiale `ggml-org/llama.cpp`, pulisce le build precedenti e compila il progetto con il flag CUDA attivo (`-DGGML_CUDA=ON`) sfruttando tutti i core della CPU (`-j$(nproc)`).
* **Modelli Centralizzati:** Verifica la presenza della cartella centralizzata `models/1_LLM_Text/` ed esegue l'eventuale script di download helper se presente in `tools/`.
* **Servizio Systemd (`llama-server.service`):** Configura e avvia il demone di sistema per mantenere il server di inferenza sempre attivo sulla porta `8080` con caricamento del modello in VRAM (`-ngl 99`).

### Fase 3: Installazione Unsloth Studio & External Backend Binding
* **Tool di Gestione Pacchetti (`uv`):** Installa il gestore ultra-veloce `uv` di Astral.
* **Virtual Environment Isolato:** Crea un ambiente virtuale Python 3.11 pulito all'interno di `/opt/homelab-ai/backend/unsloth/venv`.
* **Installazione Pacchetti:** Installa PyTorch ottimizzato per CUDA 12.1/13, `unsloth-studio` e `unsloth` utilizzando direttamente il binario `pip` del virtual environment per aggirare i blocchi PEP 668 dei sistemi Debian/Ubuntu moderni.
* **Servizio Systemd (`unsloth-studio.service`):** Configura il demone web sulla porta `7860`, impostando le variabili d'ambiente per puntare al server `llama.cpp` esterno (`http://127.0.0.1:8080`).

### Fase 4: Dashboard Interattiva di Telemetria e Monitoraggio
Fornisce un'interfaccia a terminale in tempo reale che mostra:
* **Uptime e Carico di Sistema:** Statistiche di carico CPU e utilizzo RAM/Disco.
* **Telemetria GPU NVIDIA:** Modello della scheda, temperatura in tempo reale, velocità delle ventole, consumo energetico in Watt, utilizzo del core grafico e VRAM occupata.
* **Stato dei Servizi:** Monitoraggio dello stato attivo/offline di `llama-server` e `unsloth-studio` con relativi endpoint di accesso.
* **Comandi Rapidi:**
  * `[x]`: Esportazione immediata dei log di telemetria GPU in formato CSV.
  * `[b]`: Esecuzione di un benchmark di generazione testuale tramite `llama-cli` sul modello Qwen.
  * `[q]`: Uscita dalla dashboard.

---

## 4. Configurazione dei Servizi Systemd

### 1. `llama-server.service` (/etc/systemd/system/llama-server.service)
```ini
[Unit]
Description=Llama.cpp API Server (Shared Model Backend)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/homelab-ai/backend/llama.cpp
ExecStart=/opt/homelab-ai/backend/llama.cpp/build/bin/llama-server -m /opt/homelab-ai/backend/models/1_LLM_Text/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf -c 4096 --port 8080 -ngl 99
Restart=always

[Install]
WantedBy=multi-user.target
```

### 2. `unsloth-studio.service` (/etc/systemd/system/unsloth-studio.service)
```ini
[Unit]
Description=Unsloth Studio Web Interface (No Duplicate Llama.cpp)
After=network.target llama-server.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/homelab-ai/backend/unsloth
Environment="PATH=/opt/homelab-ai/backend/unsloth/venv/bin:/usr/local/bin:/usr/bin"
Environment="LLAMA_CPP_URL=http://127.0.0.1:8080"
ExecStart=/opt/homelab-ai/backend/unsloth/venv/bin/unsloth-studio --port 7860 --backend-url http://127.0.0.1:8080
Restart=always

[Install]
WantedBy=multi-user.target
```

---

## 5. Guida alle Opzioni del Menu Principale

Il menu testuale interattivo offre le seguenti scelte operative:

* **`A` (Autodeploy Completo):** Esegue in sequenza automatica le Fasi da 1 a 4 previa conferma dell'utente. Ideale per installazioni da zero su macchine pulite.
* **`1` (Fase 1):** Installa esclusivamente le dipendenze di sistema, locale/timezone, driver NVIDIA e Toolkit CUDA 13.2.
* **`2` (Fase 2):** Clona, compila e avvia `llama.cpp` configurando i percorsi centralizzati dei modelli e il servizio di systemd sulla porta 8080.
* **`3` (Fase 3):** Configura l'ambiente virtuale isolato con `uv`, installa Unsloth Studio e imposta il binding con il backend esterno.
* **`4` (Fase 4):** Lancia la Dashboard di monitoraggio hardware e dei servizi in tempo reale.
* **`5` (Esci):** Termina lo script ed esce dalla shell.
* **`P` (PURGE Totale):** Esegue una pulizia completa del sistema: arresta e rimuove i servizi systemd, elimina la cartella `/opt/homelab-ai`, e rimuove i pacchetti driver/CUDA per ripartire da uno stato pulito.
