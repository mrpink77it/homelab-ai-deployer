# 🚀 GUIDA OPERATIVA MASTER - HOMELAB AI DEPLOYER (v2.0.0)

> **Benvenuto nel cuore operativo della Fabbrica del Software Autonoma.** 
> Questo file funge da punto di riferimento unico per comprendere, mantenere ed estendere l'infrastruttura `homelab-ai-deployer`.

---

## 1. VISIONE E FILOSOFIA DEL SISTEMA
L'obiettivo di `homelab-ai-deployer` è trasformare un'infrastruttura casalinga (Proxmox VE) in una **Fabbrica del Software Autonoma**.

### Pilastri Tecnici:
- **Modularità Chirurgica:** Ogni componente dell'ecosistema IA (Inferenza, Decisione, Addestramento, Memoria RAG, Sandbox) vive in un container LXC isolato.
- **Gestione Dinamica VRAM:** La risorsa più preziosa (la VRAM) è gestita dal demone `vram_manager.py` (CT 99). Questo script esegue il *load/unload* dinamico dei modelli dai worker (CT 100/102) per liberare spazio quando viene attivato il Trainer (CT 103).
- **Dual Mode (Server/Workstation):** Supporto per deploy headless (Proxmox Server) o Workstation Desktop (KDE Plasma su Proxmox Host).

---

## 2. ARCHITETTURA LXC (LA FABBRICA)
L'infrastruttura è suddivisa per ruoli. **Non modificare queste assegnazioni senza aggiornare il VRAM Manager.**

| CT ID | Ruolo | Funzione | VRAM (Allocata) |
|---|---|---|---|
| **99** | **Orchestratore** | Dashboard Web & VRAM Manager | 0 GB |
| **100** | **LLM Worker** | Inferenza veloce (vLLM / Ollama) | ~5.5 GB |
| **101** | **Agente Coder** | "Cervello" operativo (Coding/Test) | 0 GB |
| **102** | **Decisore** | Flusso logico & Decisioni | ~1.5 GB |
| **103** | **Trainer** | Fine-Tuning LoRA (Esclusivo) | ~3.3 GB |
| **104** | **Biblioteca RAG** | Documentazione/Vector DB | 0 GB |
| **20X+** | **Sandbox** | Esecuzione sicura codice (Nesting Docker) | 0 GB |

---

## 3. PROCEDURE OPERATIVE PER GLI AGENTI
Quando operi su questo repository, segui rigorosamente queste regole:

1.  **Trasparenza:** Non cancellare o sovrascrivere file esistenti senza esplicita conferma.
2.  **Robustezza:** Ogni nuovo script Bash deve utilizzare `set -euo pipefail` e deve essere testato con l'interfaccia TUI (`whiptail`).
3.  **Integrazione Systemd:** Ogni servizio (orchestrazione, API, forge) deve avere un unit file dedicato in `systemd/` per garantire il riavvio automatico al boot.
4.  **Manutenzione VRAM:** Se aggiungi componenti che consumano VRAM, aggiorna `script/vram_manager.py` per includerli nel ciclo di gestione.
5.  **Sicurezza:** I container Sandbox (`20X`) devono avere `nesting=1` e `keyctl=1` abilitati nel file di configurazione Proxmox.

---

## 4. STANDARD DI SVILUPPO (MODALITÀ SIMULAZIONE)
Tutti gli script principali (`main.sh` e futuri script di utility/deploy) devono implementare obbligatoriamente una **modalità simulazione**.

- **Flag di attivazione:** `--simulate`
- **Comportamento:**
    - Lo script non deve eseguire operazioni distruttive o di sistema (es. `apt-get`, `chmod`, `exec`, `rm`).
    - Ogni azione che verrebbe eseguita deve essere stampata a video come `[SIMULAZIONE] Would execute: ...`.
    - I controlli di sistema (come la verifica `root`) devono essere bypassati o adattati.
- **Obiettivo:** Permettere il test del flusso TUI e della logica di controllo in ambienti non di produzione, garantendo sicurezza e facilità di debug.

---

## 5. GUIDE DI SUPPORTO (docs/)
Per dettagli specifici, consulta i file nella cartella `/docs`:
- `manager-finetuning.md`: Dettagli su NVIDIA passthrough e fine-tuning.
- `sandbox.md`: Guida alla sicurezza e all'isolamento dell'esecuzione codice.
- `servizi.md`: Mappatura completa dei servizi (RAG, Voice, ecc.).
- `ollama_bench.md`: Metriche di performance.

---

## 6. COMANDI E SCRIPT CORE
- `script/main.sh`: Dispatcher TUI principale.
- `script/vram_manager.py`: Demone per l'orchestrazione delle risorse GPU.
- `script/deploy-lxc-ai.sh`: Automatizzazione creazione container.

*Per domande su specifiche tecniche, consultare sempre `docs/homelab_ai_deployer_master_architecture_technical_specification.md`.*
