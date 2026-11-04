#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/cyberpunk-monitor"
SERVICE_FILE="/etc/systemd/system/cyberpunk-monitor.service"
CURRENT_USER="${SUDO_USER:-root}"

echo "[*] Installazione Cyberpunk Open API Monitor in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

cat << 'EOF_REQ' > "$INSTALL_DIR/requirements.txt"
fastapi
uvicorn
httpx
psutil
EOF_REQ

cat << 'EOF_PY' > "$INSTALL_DIR/minimal_monitor.py"
#!/usr/bin/env python3
import time
import psutil
import httpx
from fastapi import FastAPI
from fastapi.responses import HTMLResponse

app = FastAPI(title="Open API Server Monitor", version="1.0.0")

TARGET_API = "http://127.0.0.1:8080"

@app.get("/api/status")
async def get_status():
    cpu = psutil.cpu_percent()
    ram = psutil.virtual_memory().percent
    
    server_status = "OFFLINE"
    model_name = "N/D"
    
    try:
        async with httpx.AsyncClient(timeout=1.0) as client:
            resp = await client.get(f"{TARGET_API}/health")
            if resp.status_code == 200:
                server_status = "ONLINE"
            
            m_resp = await client.get(f"{TARGET_API}/v1/models")
            if m_resp.status_code == 200:
                data = m_resp.json()
                models = data.get("data", [])
                if models:
                    model_name = models[0].get("id", "N/D")
    except Exception:
        pass

    return {
        "server_status": server_status,
        "model": model_name,
        "cpu": cpu,
        "ram": ram,
        "endpoint": TARGET_API
    }

@app.get("/", response_class=HTMLResponse)
async def cyberpunk_dashboard():
    return '''
    <!DOCTYPE html>
    <html lang="it">
    <head>
        <meta charset="UTF-8">
        <title>OPEN API // MONITOR</title>
        <style>
            @import url('https://fonts.googleapis.com/css2?family=Share+Tech+Mono&display=swap');
            :root {
                --bg: #030305;
                --panel: #0a0a0f;
                --neon-green: #00ff66;
                --neon-cyan: #00f0ff;
                --neon-pink: #ff0055;
                --text: #c0c0d0;
                --dim: #404050;
            }
            body {
                background-color: var(--bg);
                color: var(--text);
                font-family: 'Share Tech Mono', monospace;
                margin: 0;
                padding: 30px;
                overflow-x: hidden;
            }
            header {
                border-bottom: 1px solid var(--neon-cyan);
                padding-bottom: 15px;
                margin-bottom: 30px;
                display: flex;
                justify-content: space-between;
                align-items: center;
                text-shadow: 0 0 8px rgba(0,240,255,0.4);
            }
            h1 {
                margin: 0;
                font-size: 1.8rem;
                color: var(--neon-cyan);
                letter-spacing: 2px;
            }
            .status-badge {
                padding: 6px 12px;
                font-weight: bold;
                border: 1px solid var(--neon-green);
                color: var(--neon-green);
                background: rgba(0,255,102,0.05);
                box-shadow: 0 0 10px rgba(0,255,102,0.2);
            }
            .status-badge.offline {
                border-color: var(--neon-pink);
                color: var(--neon-pink);
                box-shadow: 0 0 10px rgba(255,0,85,0.2);
            }
            .grid {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
                gap: 20px;
            }
            .panel {
                background: var(--panel);
                border: 1px solid var(--dim);
                padding: 20px;
                position: relative;
            }
            .panel::before {
                content: '';
                position: absolute;
                top: 0; left: 0; width: 4px; height: 100%;
                background: var(--neon-cyan);
            }
            .panel.green::before { background: var(--neon-green); }
            .label {
                font-size: 0.8rem;
                color: var(--dim);
                text-transform: uppercase;
                letter-spacing: 1px;
                margin-bottom: 8px;
            }
            .value {
                font-size: 1.4rem;
                color: var(--text);
            }
            .value.highlight {
                color: var(--neon-green);
                text-shadow: 0 0 6px rgba(0,255,102,0.3);
            }
            .console-box {
                margin-top: 30px;
                background: #010103;
                border: 1px solid var(--dim);
                padding: 15px;
                font-size: 0.85rem;
                color: var(--neon-cyan);
                height: 120px;
                overflow-y: auto;
            }
        </style>
    </head>
    <body>
        <header>
            <div>
                <h1>OPEN API // MONITOR</h1>
                <div style="font-size: 0.8rem; color: var(--dim); margin-top: 4px;">TARGET: http://127.0.0.1:8080 // PROTOCOL: REST</div>
            </div>
            <div id="badge-status" class="status-badge offline">OFFLINE</div>
        </header>

        <div class="grid">
            <div class="panel green">
                <div class="label">Stato Engine</div>
                <div class="value" id="val-status">Rilevamento...</div>
            </div>
            <div class="panel">
                <div class="label">Modello in Esecuzione</div>
                <div class="value highlight" id="val-model">N/D</div>
            </div>
            <div class="panel">
                <div class="label">Carico CPU Host</div>
                <div class="value" id="val-cpu">0%</div>
            </div>
            <div class="panel">
                <div class="label">RAM Utilizzata</div>
                <div class="value" id="val-ram">0%</div>
            </div>
        </div>

        <div class="console-box" id="console-logs">
            > Inizializzazione feed di telemetria...<br>
            > Connessione al server Open API in corso...
        </div>

        <script>
            async function updateMetrics() {
                try {
                    const res = await fetch('/api/status');
                    const data = await res.json();
                    
                    const badge = document.getElementById('badge-status');
                    const statusVal = document.getElementById('val-status');
                    const modelVal = document.getElementById('val-model');
                    const cpuVal = document.getElementById('val-cpu');
                    const ramVal = document.getElementById('val-ram');
                    const logs = document.getElementById('console-logs');

                    statusVal.innerText = data.server_status;
                    modelVal.innerText = data.model;
                    cpuVal.innerText = data.cpu + '%';
                    ramVal.innerText = data.ram + '%';

                    if (data.server_status === 'ONLINE') {
                        badge.innerText = 'ONLINE';
                        badge.classList.remove('offline');
                    } else {
                        badge.innerText = 'OFFLINE';
                        badge.classList.add('offline');
                    }

                    const timeStr = new Date().toLocaleTimeString();
                    if (Math.random() < 0.25) {
                        logs.innerHTML += `<br>[${timeStr}] PING OK // CPU: ${data.cpu}% | RAM: ${data.ram}%`;
                        logs.scrollTop = logs.scrollHeight;
                    }
                } catch (e) {
                    console.error("Errore di rete:", e);
                }
            }

            setInterval(updateMetrics, 2000);
            updateMetrics();
        </script>
    </body>
    </html>
    '''

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=9001, log_level="warning")
EOF_PY

echo "[*] Creazione del Virtual Environment Python e installazione dipendenze..."
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip -qq
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" -qq

chown -R "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/minimal_monitor.py"

echo "[*] Configurazione del servizio systemd..."
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Cyberpunk Open API Monitor Service
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/minimal_monitor.py
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cyberpunk-monitor.service
systemctl restart cyberpunk-monitor.service

echo "=========================================================================="
echo "[OK] Cyberpunk Open API Monitor configurato ed attivo sulla porta 9001!"
echo "Apri il browser su: http://127.0.0.1:9001"
echo "=========================================================================="
