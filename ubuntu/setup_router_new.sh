#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/gateway"
LOGS_DIR="$INSTALL_DIR/logs"
CONFIG_FILE="$INSTALL_DIR/cluster-topology.json"
SERVICE_FILE="/etc/systemd/system/llm-gateway.service"
CURRENT_USER="${SUDO_USER:-root}"

echo "[*] Aggiornamento directory di installazione e log in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$LOGS_DIR"

cat << 'EOF_REQ' > "$INSTALL_DIR/requirements.txt"
fastapi
uvicorn
httpx
rich
pydantic
psutil
EOF_REQ

cat << 'EOF_PY' > "$INSTALL_DIR/llm_gateway.py"
#!/usr/bin/env python3
"""
LLM Cluster Dashboard & Distributed Gateway
-------------------------------------------
Gestione centralizzata della rete di calcolo eterogenea, auto-discovery dei nodi,
metriche locali e di cluster, e routing OpenAPI unificato.
"""

import time
import asyncio
import subprocess
import os
import json
import psutil
from typing import Dict, Any, Optional, List
from fastapi import FastAPI, HTTPException, Request, Header
from fastapi.responses import HTMLResponse, JSONResponse
import httpx
from pydantic import BaseModel
from rich.console import Console
from rich.logging import RichHandler
import logging

console = Console()
logging.basicConfig(
    level="INFO",
    format="%(message)s",
    datefmt="[%X]",
    handlers=[RichHandler(console=console, rich_tracebacks=True)]
)
logger = logging.getLogger("LLMClusterGateway")

file_handler = logging.FileHandler(os.path.join("/opt/gateway/logs", "gateway.log"))
file_handler.setFormatter(logging.Formatter("[%(asctime)s] [%(levelname)s] %(name)s: %(message)s"))
logger.addHandler(file_handler)

MANIFEST_PATH = "/opt/gateway/cluster-topology.json"
RECENT_LOGS: List[Dict[str, Any]] = []

app = FastAPI(title="LLM Cluster Dashboard & Distributed Gateway", version="6.2.0")

def add_log_entry(level: str, message: str, node: str = "-", latency: float = 0.0, prompt: str = "-", tokens_in: int = 0, tokens_out: int = 0):
    entry = {
        "timestamp": time.strftime("%H:%M:%S"),
        "level": level,
        "message": message,
        "node": node,
        "latency": f"{latency:.2f}s" if latency > 0 else "-",
        "prompt": (prompt[:60] + "...") if len(prompt) > 60 else prompt,
        "tokens_in": tokens_in,
        "tokens_out": tokens_out
    }
    RECENT_LOGS.append(entry)
    if len(RECENT_LOGS) > 100:
        RECENT_LOGS.pop(0)
    logger.info(f"[{node}] {level}: {message} | Prompt: {prompt}")

def get_system_metrics():
    cpu_util = psutil.cpu_percent(interval=None)
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    return {
        "cpu_util_pct": cpu_util,
        "ram_used_gb": round(mem.used / (1024**3), 2),
        "ram_total_gb": round(mem.total / (1024**3), 2),
        "ram_util_pct": mem.percent,
        "disk_used_gb": round(disk.used / (1024**3), 2),
        "disk_total_gb": round(disk.total / (1024**3), 2),
        "disk_util_pct": disk.percent
    }

def load_topology() -> Dict[str, Any]:
    if os.path.exists(MANIFEST_PATH):
        try:
            with open(MANIFEST_PATH, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return {"cluster_version": "2.1.0", "nodes": []}

@app.on_event("startup")
async def startup_event():
    logger.info("Avvio LLM Cluster Dashboard & Gateway sulla porta 9001...")
    add_log_entry("INFO", "Gateway avviato correttamente su 0.0.0.0:9001.")

class GatewayChatRequest(BaseModel):
    model: Optional[str] = None
    messages: List[Dict[str, str]]
    temperature: Optional[float] = 0.2
    stream: Optional[bool] = False

@app.get("/api/metrics")
async def get_metrics():
    topology = load_topology()
    return {
        "system": get_system_metrics(),
        "cluster": topology,
        "logs": RECENT_LOGS
    }

@app.post("/v1/chat/completions")
async def chat_completions(req: GatewayChatRequest):
    topology = load_topology()
    nodes = topology.get("nodes", [])
    
    target_backend = None
    user_prompt = req.messages[-1].get("content", "") if req.messages else ""

    # Ricerca backend nel cluster dinamico che possiede il modello richiesto
    for node in nodes:
        for backend in node.get("backends", []):
            if not req.model or req.model in backend.get("models_loaded", []):
                target_backend = {
                    "host": node["host"],
                    "port": backend["port"]
                }
                break
        if target_backend:
            break
            
    # Fallback sul primo backend disponibile se non trovato match esatto
    if not target_backend:
        for node in nodes:
            if node.get("backends"):
                b = node["backends"][0]
                target_backend = {"host": node["host"], "port": b["port"]}
                break

    if not target_backend:
        raise HTTPException(status_code=503, detail="Nessun nodo di calcolo attivo disponibile nella rete distribuita.")

    url = f"http://{target_backend['host']}:{target_backend['port']}/v1/chat/completions"
    payload = {
        "model": req.model,
        "messages": req.messages,
        "temperature": req.temperature,
        "stream": req.stream
    }
    
    start_time = time.time()
    add_log_entry("INFO", f"Inoltro richiesta a {target_backend['host']}:{target_backend['port']}", "CLUSTER", prompt=user_prompt)

    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            resp = await client.post(url, json=payload)
            elapsed = time.time() - start_time
            if resp.status_code == 200:
                resp_data = resp.json()
                usage = resp_data.get("usage", {})
                tok_in = usage.get("prompt_tokens", 0)
                tok_out = usage.get("completion_tokens", 0)
                add_log_entry("SUCCESS", f"Completato ({tok_in}in / {tok_out}out)", "CLUSTER", elapsed, user_prompt, tok_in, tok_out)
                return resp_data
            else:
                return JSONResponse(status_code=resp.status_code, content=resp.json())
    except Exception as e:
        add_log_entry("ERROR", f"Errore di comunicazione upstream: {str(e)}", "CLUSTER", prompt=user_prompt)
        raise HTTPException(status_code=502, detail=f"Errore di rete con il nodo di calcolo: {str(e)}")

@app.get("/", response_class=HTMLResponse)
@app.get("/dashboard", response_class=HTMLResponse)
async def serve_dashboard():
    html_content = """
    <!DOCTYPE html>
    <html lang="it">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>LLM Cluster Dashboard</title>
        <style>
            :root {
                --bg: #090d16;
                --card-bg: #111827;
                --text: #f3f4f6;
                --accent: #10b981;
                --black-card: #030712;
                --success: #22c55e;
                --danger: #ef4444;
                --warning: #f59e0b;
                --border: #1f2937;
            }
            body {
                font-family: 'Segoe UI', system-ui, sans-serif;
                background-color: var(--bg);
                color: var(--text);
                margin: 0;
                padding: 20px;
            }
            header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 20px;
                border-bottom: 1px solid var(--border);
                padding-bottom: 15px;
            }
            h1 { color: var(--accent); margin: 0; font-size: 1.8rem; }
            .subtitle { color: #9ca3af; font-size: 0.85em; }
            .system-bar {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                gap: 15px;
                margin-bottom: 20px;
            }
            .sys-card {
                background-color: var(--black-card);
                border: 1px solid var(--border);
                border-radius: 8px;
                padding: 12px;
                text-align: center;
            }
            .sys-title { color: #9ca3af; font-size: 0.8em; text-transform: uppercase; }
            .sys-val { font-size: 1.2rem; font-weight: bold; color: var(--accent); margin-top: 4px; }
            .card {
                background-color: var(--card-bg);
                border-radius: 10px;
                padding: 18px;
                box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.5);
                border: 1px solid var(--border);
                margin-bottom: 20px;
            }
            .log-container {
                background-color: var(--card-bg);
                border-radius: 10px;
                padding: 18px;
                border: 1px solid var(--border);
                overflow-x: auto;
            }
            table { width: 100%; border-collapse: collapse; margin-top: 10px; }
            th, td { text-align: left; padding: 8px; border-bottom: 1px solid var(--border); font-size: 0.85em; }
            th { color: #9ca3af; }
            .log-SUCCESS { color: var(--success); }
            .log-ERROR { color: var(--danger); }
            .log-WARN { color: var(--warning); }
            .log-INFO { color: var(--accent); }
            pre { background: #030712; padding: 12px; border-radius: 6px; color: #38bdf8; overflow-x: auto; font-size: 0.85em; }
        </style>
    </head>
    <body>
        <header>
            <div>
                <h1>LLM Cluster Dashboard</h1>
                <div class="subtitle">Orchestratore Distribuito & Rete di Calcolo Autonoma (Porta 9001)</div>
            </div>
        </header>

        <div class="system-bar">
            <div class="sys-card">
                <div class="sys-title">CPU Host Locale</div>
                <div class="sys-val" id="sys-cpu-util">0%</div>
            </div>
            <div class="sys-card">
                <div class="sys-title">RAM Locale Usata</div>
                <div class="sys-val" id="sys-ram-val">0 / 0 GB</div>
            </div>
            <div class="sys-card">
                <div class="sys-title">Disco Locale Usato</div>
                <div class="sys-val" id="sys-disk-val">0 / 0 GB</div>
            </div>
        </div>

        <div class="card">
            <h3 style="margin-top:0; color: var(--accent);">Topologia del Cluster & Nodi Rilevati (cluster-topology.json)</h3>
            <pre id="cluster-topology-view">Scansione rete in corso...</pre>
        </div>

        <div class="log-container">
            <h3 style="margin: 0; color: var(--accent);">Registro Eventi & Richieste Gateway</h3>
            <table>
                <thead>
                    <tr>
                        <th>Ora</th>
                        <th>Livello</th>
                        <th>Nodo</th>
                        <th>Prompt Inviato</th>
                        <th>Token (In / Out)</th>
                        <th>Latenza</th>
                        <th>Dettagli Operazione</th>
                    </tr>
                </thead>
                <tbody id="logs-body">
                </tbody>
            </table>
        </div>

        <script>
            async function updateDashboard() {
                try {
                    const res = await fetch('/api/metrics');
                    const data = await res.json();
                    
                    if (data.system) {
                        document.getElementById('sys-cpu-util').innerText = `${data.system.cpu_util_pct}%`;
                        document.getElementById('sys-ram-val').innerText = `${data.system.ram_used_gb} / ${data.system.ram_total_gb} GB (${data.system.ram_util_pct}%)`;
                        document.getElementById('sys-disk-val').innerText = `${data.system.disk_used_gb} / ${data.system.disk_total_gb} GB (${data.system.disk_util_pct}%)`;
                    }

                    if (data.cluster) {
                        document.getElementById('cluster-topology-view').innerText = JSON.stringify(data.cluster, null, 4);
                    }

                    const logsBody = document.getElementById('logs-body');
                    logsBody.innerHTML = '';
                    [...data.logs].reverse().forEach(log => {
                        logsBody.innerHTML += `
                            <tr>
                                <td>${log.timestamp}</td>
                                <td class="log-${log.level}"><strong>${log.level}</strong></td>
                                <td>${log.node}</td>
                                <td>${log.prompt || '-'}</td>
                                <td>${log.tokens_in || 0} / ${log.tokens_out || 0}</td>
                                <td>${log.latency}</td>
                                <td>${log.message}</td>
                            </tr>
                        `;
                    });
                } catch (err) {
                    console.error("Errore aggiornamento dashboard:", err);
                }
            }

            setInterval(updateDashboard, 2000);
            updateDashboard();
        </script>
    </body>
    </html>
    """
    return HTMLResponse(content=html_content, status_code=200)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=9001, log_level="warning")
EOF_PY

python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"
chown -R "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/llm_gateway.py"

cat << EOF > "$SERVICE_FILE"
[Unit]
Description=LLM Cluster Dashboard Gateway Service
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/llm_gateway.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable llm-gateway.service
systemctl restart llm-gateway.service

echo ""
echo "[OK] LLM Cluster Dashboard configurato e avviato sulla porta 9001!"
echo "----------------------------------------------------------------------"
echo " Dashboard Web attiva su: http://127.0.0.1:9001"
echo " Legge la topologia da:  $CONFIG_FILE"
echo "----------------------------------------------------------------------"
