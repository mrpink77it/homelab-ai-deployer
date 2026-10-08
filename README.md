# 🚀 Proxmox AI Deployer

Benvenuto in **Proxmox AI Deployer** (`homelab-ai-deployer`), la suite definitiva per trasformare il tuo nodo Proxmox VE in una **Fabbrica del Software Autonoma** o in una **AI Workstation** completa. 

Sfruttando la containerizzazione LXC, questo progetto permette di orchestrare un intero stack di intelligenza artificiale (LLM, Agenti Coding, RAG, Addestramento locale) ottimizzando in modo chirurgico risorse hardware limitate (es. una singola GPU da 8GB di VRAM).

## 🌟 Caratteristiche Principali (v2.0.0)

- **Dual Mode Deployment:**
  - 🖥️ **Server Edition:** Ambiente headless isolato, ottimizzato al 100% per i container IA.
  - 🎨 **Workstation Edition:** Installa automaticamente KDE Plasma e i driver GPU direttamente sull'host per un utilizzo quotidiano desktop, con lo stack IA che gira fluidamente in background.
- **Gestione Dinamica VRAM (VRAM Manager):** Massimizza l'uso degli 8GB. Il nostro Orchestratore spegne dinamicamente l'inferenza quando lanci l'addestramento, evitando il crash `CUDA Out of Memory`.
- **Interfaccia TUI Modulare:** Script bash interattivi per selezionare e configurare individualmente i container.
- **ISO "Zero-Touch" (Noob-Friendly):** Builder integrato per generare una ISO di Proxmox che si auto-installa e pre-configura la Workstation al primissimo avvio.

## 🏗️ Architettura dei Container (LXC)

La Fabbrica del Software è divisa in ruoli specifici altamente isolati:

| CT ID | Ruolo | Funzione | Accesso GPU | VRAM | Tool Core |
|---|---|---|---|---|---|
| **99** | **Orchestratore** | Dashboard Web & VRAM Manager | No | 0 GB | Streamlit, FastAPI |
| **100** | **LLM Worker** | Server API per la generazione di codice | Sì | ~5.5 GB | vLLM / Ollama |
| **101** | **Agente Coder** | "Cervello": scrive, testa ed esegue il codice | No | 0 GB | OpenDevin / Aider |
| **102** | **Decisore** | Acceleratore di scelte logiche e branch | Sì | ~1.5 GB | Rizzo Flow |
| **103** | **Trainer** | Fine-Tuning LoRA tramite layer streaming | Sì (Esclusivo)| ~3.3 GB | Soup |
| **104** | **Biblioteca** | Memoria RAG a lungo termine (Linee guida) | No (CPU) | 0 GB | AnythingLLM / Dify |
| **20X** | **Progetti** | Container target dove l'agente esegue i test | No | 0 GB | Docker Nesting |

> **Nota Tecnica:** Durante l'esecuzione del task sul **CT 103** (Addestramento), l'Orchestratore (**CT 99**) invia automaticamente un comando SSH per smontare i modelli sul CT 100 e 102, garantendo lo spazio in VRAM necessario al fine-tuning.

## ⚙️ Come Iniziare

### Metodo 1: Script TUI (Per installazioni Proxmox esistenti)
Esegui lo script principale direttamente dal tuo nodo Proxmox (richiede privilegi di root):
```bash
git clone [https://github.com/mrpink77it/homelab-ai-deployer.git](https://github.com/mrpink77it/homelab-ai-deployer.git)
cd homelab-ai-deployer
chmod +x install.sh
./install.sh
