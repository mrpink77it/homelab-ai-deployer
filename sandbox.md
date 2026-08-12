# 🧪 Guida Operativa & Architettura Sandbox (Unsloth Suite)

Questo documento descrive l'architettura, la configurazione e le modalità di test per l'esecuzione sicura del codice generato dall'AI tramite l'ambiente **Sandbox** e il servizio **Code Runner API** (Porta 9000).

---

## 1. Architettura di Sistema

L'architettura separa nettamente il nodo di controllo (dove risiedono i modelli LLM e le interfacce) dai nodi di esecuzione del codice (Sandbox):


+---------------------------------+             SSH             +---------------------------------+
|         CONTROLLER AI           |---------------------------->|          SANDBOX LXC/VM         |
|  - Unsloth Studio (Porta 8888)  |   Exec: python3 -c "..."    |  - Python 3                     |
|  - OpenCode AI   (Porta 8000)   |                             |  - Ambiente isolato             |
|  - Code Runner   (Porta 9000)   |<----------------------------|  - Nessun accesso a risorse GPU  |
+---------------------------------+        stdout / stderr      +---------------------------------+

### Componenti Principali:
1. **Controller AI (Host Principale):**
   - Gestisce i modelli di linguaggio e l'addestramento (Unsloth / OpenCode).
   - Espone l'API di automazione **Code Runner** su `http://<CONTROLLER_IP>:9000`.
2. **Sandbox (Container LXC o VM Dediata):**
   - Ambiente Linux isolato (es. container Proxmox unprivileged o VM).
   - Riceve ed esegue il codice Python inviato dal Controller tramite SSH.

---

## 2. Requisiti della Sandbox

Sulla macchina/container Sandbox devono essere presenti:
- **OS:** Debian 12 / Ubuntu 22.04+ (o qualsiasi distro Linux standard).
- **SSH Server:** `openssh-server` attivo e raggiungibile sulla porta 22.
- **Python 3:** `python3` installato.
- **Connettività:** Raggiungibile via IP locale dal Controller.

---

## 3. Configurazione Passaggio-Passaggio

### Passaggio 1: Generazione e Scambio delle Chiavi SSH
Per permettere al Controller di inviare ed eseguire comandi sulla Sandbox senza inserire la password ogni volta:

1. **Sul Controller**, genera una chiave SSH (se non già presente):
   ```bash
   ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519

Copia la chiave pubblica sulla Sandbox (sostituisci <IP_SANDBOX> con l'IP reale della Sandbox):

Bash
ssh-copy-id -i /root/.ssh/id_ed25519.pub root@<IP_SANDBOX>
Verifica il funzionamento dal Controller:

Bash
ssh -o StrictHostKeyChecking=no root@<IP_SANDBOX> "python3 --version"
Se il comando restituisce la versione di Python senza chiedere la password, la connessione è configurata correttamente.

4. Test dell'API Code Runner (Porta 9000)
L'API gestisce le richieste HTTP ed esegue il codice inviato tramite SSH.

Test 1: Chiamata via curl
Dal Controller (o da un qualsiasi client in rete), invia una richiesta POST all'endpoint /execute:

Bash
curl -X POST http://localhost:9000/execute \
  -H "Content-Type: application/json" \
  -d '{
    "code": "import sys; print(f\"Hello from Sandbox! Python version: {sys.version}\")",
    "sandbox_ip": "<IP_SANDBOX>"
  }'
Risposta JSON attesa:

JSON
{
  "stdout": "Hello from Sandbox! Python version: 3.11.x ...\n",
  "stderr": "",
  "exit_code": 0
}
Test 2: Chiamata Programmatica in Python (es. da Jupyter/Unsloth)
Puoi testare l'esecuzione remota direttamente da un notebook Jupyter o uno script Python:

Python
import requests

API_URL = "http://localhost:9000/execute"
SANDBOX_IP = "<IP_SANDBOX>"

code_payload = """
import os
print("Directory corrente sulla Sandbox:", os.getcwd())
data = [x**2 for x in range(10)]
print("Calcolo eseguito in Sandbox:", data)
"""

response = requests.post(
    API_URL,
    json={"code": code_payload, "sandbox_ip": SANDBOX_IP}
)

result = response.json()
print("--- STDOUT ---")
print(result["stdout"])
print("--- EXIT CODE ---")
print(result["exit_code"])
5. Gestione del Servizio Code Runner
Il servizio code-runner è gestito via systemd:

Verificare lo stato:

Bash
systemctl status code-runner.service
Riavviare il servizio:

Bash
systemctl restart code-runner.service
Leggere i log in tempo reale:

Bash
journalctl -u code-runner.service -f
6. Raccomandazioni per la Sicurezza
Isolamento di rete: Configura regole firewall (es. Proxmox Datacenter/Node Firewall) per permettere alla Sandbox di comunicare unicamente con il Controller sulla porta SSH (22).

Utente non-root (Opzionale): Per la massima sicurezza, crea un utente runner non-root sulla Sandbox con permessi limitati e modifica la stringa di connessione in code_runner_api.py da root@... a runner@....

Timeout di Esecuzione: L'API applica automaticamente un timeout di 30 secondi ad ogni esecuzione per prevenire loop infiniti o saturazione delle risorse.


---

### Per salvare il file direttamente sul tuo server:
Puoi creare il file al volo eseguendo questo comando dal terminale del tuo Controller:

```bash
cat << 'EOF' > /root/sandbox.md
# Incolla qui il contenuto sopra se necessario
EOF
