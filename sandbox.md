# 🧪 Architettura & Guida Operativa Sandbox 

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
```

### Ruolo dei Nodi:
1. **Controller AI (Host Principale)**:
   - Ospita l'ambiente PyTorch/CUDA per il fine-tuning e l'inferenza (Unsloth Studio).
   - Esegue l'interfaccia di sviluppo OpenCode AI.
   - Espone il microservizio **Code Runner API** su `http://<CONTROLLER_IP>:9000` per orchestrare l'esecuzione remota del codice.
2. **Nodo Sandbox (Container LXC o VM Dedicata)**:
   - Un ambiente Linux minimale ed isolato.
   - Riceve i comandi inviati dal Controller via SSH ed esegue il codice in un processo confinato.
   - Restituisce `stdout`, `stderr` e l'`exit_code` al Controller.

---

## 2. Come lo Script `manager.sh` Configura l'Ambiente

Durante l'esecuzione dell'opzione `1) INSTALLA Servizi`, lo script `manager.sh` esegue automaticamente i seguenti passaggi per l'ambiente Code Runner:

1. **Installazione Dipendenze**: Installa i pacchetti Python `uvicorn` e `fastapi` a livello di sistema.
2. **Creazione Directory**: Prepara il percorso `/opt/code_runner`.
3. **Generazione API (`/opt/code_runner/code_runner_api.py`)**:
   Inizializza un'applicazione FastAPI che espone l'endpoint `/execute`. L'API accetta payload JSON contenenti il codice Python da eseguire e l'IP della Sandbox bersaglio, lanciando un comando SSH non interattivo con timeout di 30 secondi.
4. **Configurazione Service Systemd (`/etc/systemd/system/code-runner.service`)**:
   Registra il servizio affinché si avvii automaticamente al boot sulla porta 9000.
5. **Generazione Documentazione**: Crea il file `README_AUTOMATION.md` nella home dell'utente.

---

## 3. Requisiti della Sandbox

Sulla macchina/container destinata a fare da Sandbox devono essere garantiti i seguenti requisiti minimali:
- **Sistema Operativo**: Debian 12, Ubuntu 22.04+ o qualsiasi distribuzione Linux standard.
- **SSH Server**: Servizio `openssh-server` attivo ed in ascolto sulla porta 22.
- **Python 3**: Interpreter `python3` installato.
- **Connettività di Rete**: Raggiungibile via IP locale dal Controller.

---

## 4. Configurazione Passo-Passo (Controller ➔ Sandbox)

Per fare in modo che il Controller possa inviare ed eseguire il codice sulla Sandbox in modo trasparente e senza interruzioni di autenticazione:

### Step 1: Generazione della Chiave SSH sul Controller
Se non hai già una chiave SSH generata sul Controller, creala eseguendo:
```bash
ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
```

### Step 2: Copia della Chiave Pubblica sulla Sandbox
Autorizza la chiave del Controller sulla Sandbox (sostituisci `<IP_SANDBOX>` con l'indirizzo IP reale del nodo Sandbox):
```bash
ssh-copy-id -i /root/.ssh/id_ed25519.pub root@<IP_SANDBOX>
```

### Step 3: Verifica della Connessione Passwordless
Esegui un test di verifica dal Controller:
```bash
ssh -o StrictHostKeyChecking=no root@<IP_SANDBOX> "python3 --version"
```
> **Esito atteso**: Il comando deve restituire la versione di Python installata sulla Sandbox senza richiedere alcuna password.

---

## 5. Struttura dell'API Code Runner (Porta 9000)

L'API risponde a richieste HTTP `POST` sull'endpoint `/execute`.

### Payload di Richiesta (JSON)
```json
{
  "code": "stringa del codice Python da eseguire",
  "sandbox_ip": "192.168.x.x"
}
```

### Risposta dell'API (JSON)
```json
{
  "stdout": "output standard generato dallo script",
  "stderr": "eventuali errori di esecuzione o warning",
  "exit_code": 0
}
```

---

## 6. Procedure di Test e Verifica

### Test A: Invio Rapido via `curl` (Da CLI)
Puoi testare l'API direttamente dal terminale del Controller o da qualsiasi client della rete locale:

```bash
curl -X POST http://localhost:9000/execute \
  -H "Content-Type: application/json" \
  -d '{
    "code": "import sys, platform; print(f\"Sandbox OS: {platform.system()} - Python: {sys.version}\")",
    "sandbox_ip": "<IP_SANDBOX>"
  }'
```

---

### Test B: Script di Verifica in Python
Puoi eseguire questo script all'interno di Jupyter Lab (Unsloth Studio) o da un file `.py` per verificare il flusso completo:

```python
import requests
import json

API_URL = "http://localhost:9000/execute"
SANDBOX_IP = "<IP_SANDBOX>"  # Inserisci l'IP della tua Sandbox

test_script = """
import os
import math

print("=== TEST ESECUZIONE SANDBOX ===")
print(f"Directory di lavoro: {os.getcwd()}")
print(f"PID del processo: {os.getpid()}")

# Calcolo di prova
risultato = [math.factorial(i) for i in range(1, 6)]
print(f"Calcolo fattoriali (1..5): {risultato}")
"""

try:
    response = requests.post(
        API_URL,
        json={"code": test_script, "sandbox_ip": SANDBOX_IP},
        headers={"Content-Type": "application/json"},
        timeout=35
    )
    
    if response.status_code == 200:
        data = response.json()
        print("✅ Chiamata API completata con successo!")
        print("\n--- STDOUT ---")
        print(data.get("stdout"))
        print("--- STDERR ---")
        print(data.get("stderr"))
        print(f"Exit Code: {data.get('exit_code')}")
    else:
        print(f"❌ Errore API (Status Code {response.status_code}): {response.text}")

except Exception as e:
    print(f"❌ Errore di connessione all'API: {e}")
```

---

### Test C: Audit di Sicurezza e Timeout
Per verificare che i meccanismi di protezione (es. isolamento e timeout) funzionino correttamente:

1. **Test di Timeout (Loop Infinito)**:
   Verifica che la Sandbox blocchi lo script dopo 30 secondi:
   ```bash
   curl -X POST http://localhost:9000/execute \
     -H "Content-Type: application/json" \
     -d '{
       "code": "import time\nwhile True:\n    time.sleep(1)",
       "sandbox_ip": "<IP_SANDBOX>"
     }'
   ```
   > **Esito atteso**: Risposta HTTP 500 con dettaglio di timeout raggiunto.

2. **Test Isolamento Risorse Hardware**:
   Verifica che la Sandbox non acceda alle GPU dell'Host Controller:
   ```bash
   curl -X POST http://localhost:9000/execute \
     -H "Content-Type: application/json" \
     -d '{
       "code": "import subprocess\ntry:\n    res = subprocess.run([\"nvidia-smi\"], capture_output=True, text=True)\n    print(res.stdout)\nexcept Exception as e:\n    print(f\"NVIDIA-SMI non disponibile (Corretto): {e}\")",
       "sandbox_ip": "<IP_SANDBOX>"
     }'
   ```

---

## 7. Gestione dei Servizi Systemd

Il servizio `code-runner` viene gestito interamente tramite `systemctl`:

* **Verifica dello Stato**:
  ```bash
  systemctl status code-runner.service
  ```
* **Riavvio del Servizio**:
  ```bash
  systemctl restart code-runner.service
  ```
* **Arresto del Servizio**:
  ```bash
  systemctl stop code-runner.service
  ```
* **Ispezione dei Log in Tempo Reale**:
  ```bash
  journalctl -u code-runner.service -f
  ```

---

## 8. Best Practice per la Sicurezza

1. **Firewall & Isolamento di Rete**:
   Configura il firewall dell'hypervisor (es. Proxmox Datacenter/Node Firewall) per limitare il traffico della Sandbox: consenti l'ingresso solo sulla porta `22` dall'IP del Controller e blocca l'accesso della Sandbox verso la LAN interna.
2. **Utente Dedicato Non-Root (Consigliato in Produzione)**:
   Per ridurre ulteriormente i rischi, crea sulla Sandbox un utente a basso privilegio (es. `runner`) anziché usare `root`.
   Modifica quindi lo script `/opt/code_runner/code_runner_api.py` per connettersi via SSH usando `runner@...`.
3. **Limiti di Risorse su Container/VM**:
   Imposta limiti rigidi di CPU e RAM nel pannello di Proxmox/LXC per la macchina Sandbox, evitando che codice intensivo possa consumare tutte le risorse dell'host.
