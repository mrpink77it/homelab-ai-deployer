# 🧪 Architettura & Guida Operativa Sandbox (Unsloth Suite)

Questo documento fornisce una guida completa all'architettura, alla configurazione, al funzionamento dello script di gestione e alle procedure di test per l'ambiente **Sandbox** con il servizio **Code Runner API** (Porta 9000).

---

## 1. Architettura di Sistema

L'architettura separa nettamente il nodo di controllo (dove risiedono i modelli LLM, le interfacce e i driver GPU) dai nodi di esecuzione del codice (Sandbox). Questa separazione garantisce che eventuale codice generato o eseguito dall'AI non comprometta le risorse di sistema o i modelli in esecuzione sul Controller.

```text
+---------------------------------+             SSH             +---------------------------------+
|         CONTROLLER AI           |---------------------------->|          SANDBOX LXC/VM         |
|  - Unsloth Studio (Porta 8888)  |   Exec: python3 -c "..."    |  - Python 3                     |
|  - OpenCode AI   (Porta 8000)   |                             |  - Ambiente isolato             |
|  - Code Runner   (Porta 9000)   |<----------------------------|  - Nessun accesso a risorse GPU  |
+---------------------------------+        stdout / stderr      +---------------------------------+

Ruolo dei Nodi:
Controller AI (Host Principale):

Ospita l'ambiente PyTorch/CUDA per il fine-tuning e l'inferenza (Unsloth Studio).

Esegue l'interfaccia di sviluppo OpenCode AI.

Espone il microservizio Code Runner API su http://<CONTROLLER_IP>:9000 per orchestrare l'esecuzione remota del codice.

Nodo Sandbox (Container LXC o VM Dedicata):

Un ambiente Linux minimale ed isolato.

Riceve i comandi inviati dal Controller via SSH ed esegue il codice in un processo confinato.

Restituisce stdout, stderr e l'exit_code al Controller.

2. Come lo Script manager.sh Configura l'Ambiente
Durante l'esecuzione dell'opzione 1) INSTALLA Servizi, lo script manager.sh esegue automaticamente i seguenti passaggi per l'ambiente Code Runner:

Installazione Dipendenze: Installa i pacchetti Python uvicorn e fastapi a livello di sistema.

Creazione Directory: Prepara il percorso /opt/code_runner.

Generazione API (/opt/code_runner/code_runner_api.py):
Inizializza un'applicazione FastAPI che espone l'endpoint /execute. L'API accetta payload JSON contenenti il codice Python da eseguire e l'IP della Sandbox bersaglio, lanciando un comando SSH non interattivo con timeout di 30 secondi.

Configurazione Service Systemd (/etc/systemd/system/code-runner.service):
Registra il servizio affinché si avvii automaticamente al boot sulla porta 9000.

Generazione Documentazione: Crea il file README_AUTOMATION.md nella home dell'utente.

3. Requisiti della Sandbox
Sulla macchina/container destinata a fare da Sandbox devono essere garantiti i seguenti requisiti minimali:

Sistema Operativo: Debian 12, Ubuntu 22.04+ o qualsiasi distribuzione Linux standard.

SSH Server: Servizio openssh-server attivo ed in ascolto sulla porta 22.

Python 3: Interpreter python3 installato.

Connettività di Rete: Raggiungibile via IP locale dal Controller.

4. Configurazione Passo-Passo (Controller ➔ Sandbox)
Per fare in modo che il Controller possa inviare ed eseguire il codice sulla Sandbox in modo trasparente e senza interruzioni di autenticazione:

Step 1: Generazione della Chiave SSH sul Controller
Se non hai già una chiave SSH generata sul Controller, creala eseguendo:


