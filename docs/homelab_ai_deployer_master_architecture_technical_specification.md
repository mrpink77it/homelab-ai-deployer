# 🚀 Homelab AI Deployer: Master Architecture & Technical Specification (v2.0.0)

Questo documento raccoglie la filosofia, l'architettura di sistema e le specifiche tecniche derivate dallo sviluppo congiunto degli script di autoinstallazione per Proxmox, Debian/Ubuntu e dei pattern di orchestrazione IA orientati all'ottimizzazione di risorse hardware limitate (es. GPU da 8GB di VRAM).

---

## 1. Filosofia e Visione del Progetto

Il progetto **Proxmox AI Deployer** (`homelab-ai-deployer`) trasforma un nodo Proxmox VE in una **Fabbrica del Software Autonoma** o in una **AI Workstation** completa. 
L'obiettivo primario è superare i limiti dell'hardware consumer (es. singola GPU con 8GB di VRAM) tramite una containerizzazione LXC spinta, isolamento dei ruoli, e un sistema di orchestrazione dinamica delle risorse (VRAM Manager).

### Modalità di Deployment (Dual Mode)
1. **Server Edition:** Ambiente headless strettamente isolato, ottimizzato al 100% per l'esecuzione di carichi di lavoro e container IA su Proxmox VE.
2. **Workstation Edition:** Configurazione avanzata che installa automaticamente KDE Plasma e i driver GPU direttamente sull'host Proxmox, consentendo l'uso desktop quotidiano in parallelo con lo stack di intelligenza artificiale in background.

---

## 2. Architettura dei Container LXC (La Fabbrica del Software)

L'infrastruttura è suddivisa in ruoli specializzati altamente isolati per evitare conflitti di librerie, dipendenze o crash di memoria.

| CT ID | Ruolo | Funzione Principale | Accesso GPU | VRAM Allocata | Tool Core / Stack |
| :---: | :--- | :--- | :---: | :---: | :--- |
| **99** | **Orchestratore** | Dashboard Web & VRAM Manager, coordinamento flussi | No | 0 GB | Streamlit, FastAPI, Bash API |
| **100** | **LLM Worker** | Server API per inferenza e generazione codice | Sì | ~5.5 GB | vLLM / Ollama |
| **101** | **Agente Coder** | "Cervello": scrive, testa ed esegue il codice | No | 0 GB | OpenDevin / Aider |
| **102** | **Decisore** | Acceleratore di scelte logiche e branch | Sì | ~1.5 GB | Rizzo Flow |
| **103** | **Trainer** | Fine-Tuning LoRA tramite layer streaming | Sì (Esclusivo) | ~3.3 GB | Soup Framework |
| **104** | **Biblioteca** | Memoria RAG a lungo termine e linee guida | No (CPU) | 0 GB | AnythingLLM / Dify |
| **20X** | **Progetti** | Container target isolati per test del codice | No | 0 GB | Docker Nesting Enabled |

---

## 3. Gestione Dinamica delle Risorse (VRAM Manager)

Con un vincolo di 8GB di VRAM (es. RTX 3070/4060), l'esecuzione contemporanea di inferenza, agenti e fine-tuning porterebbe inevitabilmente a errori critici di `CUDA Out of Memory`.

### Strategia di Gestione VRAM
- **Spegnimento Dinamico:** Quando viene avviato un task di addestramento sul **CT 103** (Trainer), l'Orchestratore (**CT 99**) invia automaticamente un comando via SSH per smontare o scaricare i modelli caricati sui worker di inferenza (**CT 100** e **CT 102**).
- **Rilascio e Ripristino:** Al termine del fine-tuning, i servizi di inferenza vengono ricaricati automaticamente nello spazio VRAM liberato.

---

## 4. Metodi di Installazione e Automazione

### Metodo 1: Script TUI Modulare (Nodi Esistenti)
- **Target:** Installazioni Proxmox VE pre-esistenti.
- **Funzionamento:** Uno script Bash interattivo guidato (TUI) permette la selezione granulare dei container da installare, configurando reti, bridge, e pass-through della GPU in modo automatico.

### Metodo 2: ISO "Zero-Touch" (Nuove Installazioni)
- **Target:** Deploy puliti e rapidi su nuovi nodi hardware.
- **Funzionamento:** Un modulo `iso-builder` inietta lo script di `first-boot.sh` direttamente nella ISO ufficiale di Proxmox.
- **Risultato:** Al termine dell'installazione del sistema operativo, il sistema configura in autonomia l'ambiente (es. autologin su KDE e prompt a schermo intero) avviando il provisioning dell'infrastruttura IA senza intervento manuale.

---

## 5. Roadmap di Sviluppo

- [ ] **Refactoring v2.0:** Revisione e modularizzazione degli script LXC ereditati dalla v1.0.
- [ ] **TUI Integrata:** Espansione dello script principale per supportare la configurazione dei nuovi container (CT 102, CT 103, CT 104).
- [ ] **ISO Builder Engine:** Automatizzazione dell'iniezione dei pacchetti KDE, SDDM e degli script di primo avvio.
- [ ] **Orchestratore Web:** Sviluppo della dashboard di controllo in Streamlit/FastAPI sul CT 99 per il monitoraggio in tempo reale della VRAM e dello stato dei container.