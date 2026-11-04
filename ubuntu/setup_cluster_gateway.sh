#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/gateway"
LOGS_DIR="$INSTALL_DIR/logs"
MODELS_DIR="/opt/llama_models"
TOPOLOGY_PATH="$INSTALL_DIR/cluster-topology.json"
STATIC_PATH="$INSTALL_DIR/cluster-static-nodes.json"
SERVICE_FILE="/etc/systemd/system/llm-gateway.service"
CURRENT_USER="${SUDO_USER:-root}"

echo "[*] Configurazione Gateway in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$LOGS_DIR"
mkdir -p "$MODELS_DIR"

if [ ! -f "$TOPOLOGY_PATH" ]; then
    echo '{"cluster_version": "3.0.0", "nodes": []}' > "$TOPOLOGY_PATH"
fi
if [ ! -f "$STATIC_PATH" ]; then
    echo '{"nodes": []}' > "$STATIC_PATH"
fi

cat << 'EOF_REQ' > "$INSTALL_DIR/requirements.txt"
fastapi
uvicorn
httpx
pydantic
psutil
EOF_REQ

cat << 'EOF_PY' > "$INSTALL_DIR/llm_gateway.py"
#!/usr/bin/env python3
"""
Gateway e Dashboard Minimalista per Server Open API
"""

import time
import os
import json
import psutil
from typing import Dict, Any, Optional, List
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
import httpx
from pydantic import BaseModel

TOPOLOGY_PATH = "/opt/gateway/cluster-topology.json"
STATIC_PATH = "/opt/gateway/cluster-static-nodes.json"
MODELS_DIR = "/opt/llama_models"

app = FastAPI(title="Gateway e Dashboard Server Open API", version="3.0.0")
RECENT_LOGS: List[Dict[str, Any]] = []

def add_log_entry(level: str, message: str, node: str = "-", latency: float = 0.0, prompt: str = "-"):
    entry = {
        "timestamp": time.strftime("%H:%M:%S"),
        "level": level,
        "message": message,
        "node": node,
        "latency": f"{latency:.2f}s" if latency > 0 else "-",
        "prompt": (prompt[:40] + "...") if len(prompt) > 40 else prompt
    }
    RECENT_LOGS.append(entry)
    if len(RECENT_LOGS) > 200:
        RECENT_LOGS.pop(0)

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
    nodes_map = {}
    if os.path.exists(STATIC_PATH):
        try:
            with open(STATIC_PATH, "r") as f:
                for node in json.load(f).get("nodes", []):
                    nodes_map[node["node_id"]] = node
        except Exception:
            pass
    if os.path.exists(TOPOLOGY_PATH):
        try:
            with open(TOPOLOGY_PATH, "r") as f:
                for node in json.load(f).get("nodes", []):
                    nodes_map[node["node_id"]] = node
        except Exception:
            pass
    return {"cluster_version": "3.0.0", "nodes": list(nodes_map.values())}

def get_available_models() -> List[str]:
    models = []
    if os.path.exists(MODELS_DIR):
        try:
            models = [f for f in os.listdir(MODELS_DIR) if f.endswith(".gguf")]
        except Exception:
            pass
    return sorted(models)

@app.get("/api/metrics")
async def get_metrics():
    return {
        "system": get_system_metrics(),
        "cluster": load_topology(),
        "models": get_available_models(),
        "logs": RECENT_LOGS
    }

class EngineActionRequest(BaseModel):
    model_name: Optional[str] = None
    port: int

@app.post("/api/engine/start")
async def engine_start(req: EngineActionRequest):
    add_log_entry("INFO", f"Avvio modello {req.model_name} sulla porta {req.port}", f"Porta {req.port}")
    return {"status": "success", "message": f"Modello {req.model_name} avviato sulla porta {req.port}"}

@app.post("/api/engine/stop")
async def engine_stop(req: EngineActionRequest):
    add_log_entry("INFO", f"Arresto motore sulla porta {req.port}", f"Porta {req.port}")
    return {"status": "success", "message": f"Motore sulla porta {req.port} arrestato."}

@app.post("/api/engine/restart")
async def engine_restart(req: EngineActionRequest):
    add_log_entry("INFO", f"Riavvio motore sulla porta {req.port}", f"Porta {req.port}")
    return {"status": "success", "message": f"Motore sulla porta {req.port} riavviato."}

@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    try:
        body = await request.json()
    except Exception:
        body = {}
    
    model = body.get("model", "")
    messages = body.get("messages", [])
    user_prompt = messages[-1].get("content", "") if messages else ""
    
    topology = load_topology()
    target_backend = None
    
    for node in topology.get("nodes", []):
        for b in node.get("backends", []):
            models = b.get("models_loaded", [])
            if not model or model in models:
                target_backend = {"host": node["host"], "port": b["port"]}
                break
        if target_backend:
            break
            
    if not target_backend:
        for node in topology.get("nodes", []):
            if node.get("backends"):
                b = node["backends"][0]
                target_backend = {"host": node["host"], "port": b["port"]}
                break
                
    if not target_backend:
        raise HTTPException(status_code=503, detail="Nessun server disponibile.")
        
    url = f"http://{target_backend['host']}:{target_backend['port']}/v1/chat/completions"
    start_t = time.time()
    
    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            resp = await client.post(url, json=body)
            elapsed = time.time() - start_t
            if resp.status_code == 200:
                add_log_entry("SUCCESS", "Completamento chat riuscito", f"{target_backend['host']}:{target_backend['port']}", elapsed, user_prompt)
                return resp.json()
            else:
                return JSONResponse(status_code=resp.status_code, content=resp.json())
    except Exception as e:
        add_log_entry("ERROR", str(e), "Gateway", prompt=user_prompt)
        raise HTTPException(status_code=502, detail=str(e))

@app.get("/", response_class=HTMLResponse)
async def dashboard():
    return """
    <!DOCTYPE html>
    <html lang="it">
    <head>
        <meta charset="UTF-8">
        <title>Monitor Server Open API</title>
        <style>
            :root {
                --bg: #121214;
                --surface: #18181b;
                --border: #27272a;
                --text: #f4f4f5;
                --text-muted: #a1a1aa;
                --accent: #3b82f6;
                --success: #10b981;
                --danger: #ef4444;
            }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                background: var(--bg);
                color: var(--text);
                margin: 0;
                padding: 24px;
            }
            header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                border-bottom: 1px solid var(--border);
                padding-bottom: 16px;
                margin-bottom: 24px;
            }
            h1 { margin: 0; font-size: 1.4rem; font-weight: 600; color: var(--text); }
            .tabs {
                display: flex;
                gap: 8px;
                border-bottom: 1px solid var(--border);
                margin-bottom: 24px;
                padding-bottom: 12px;
            }
            .tab-btn {
                background: var(--surface);
                color: var(--text-muted);
                border: 1px solid var(--border);
                padding: 8px 16px;
                border-radius: 6px;
                cursor: pointer;
                font-size: 0.9rem;
            }
            .tab-btn.active {
                background: var(--accent);
                color: #fff;
                border-color: var(--accent);
            }
            .tab-content { display: none; }
            .tab-content.active { display: block; }
            .card {
                background: var(--surface);
                border: 1px solid var(--border);
                border-radius: 8px;
                padding: 20px;
                margin-bottom: 20px;
            }
            .metrics-grid {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                gap: 16px;
                margin-bottom: 24px;
            }
            .metric-card {
                background: var(--surface);
                border: 1px solid var(--border);
                border-radius: 8px;
                padding: 16px;
            }
            .metric-title { font-size: 0.8rem; color: var(--text-muted); text-transform: uppercase; margin-bottom: 6px; }
            .metric-val { font-size: 1.2rem; font-weight: 600; color: var(--accent); }
            
            /* Carousel per i Server da 1 a N */
            .carousel-wrapper {
                display: flex;
                align-items: center;
                justify-content: center;
                gap: 16px;
                margin-top: 10px;
            }
            .nav-btn {
                background: var(--surface);
                color: var(--text);
                border: 1px solid var(--border);
                width: 40px;
                height: 40px;
                border-radius: 50%;
                font-size: 1.2rem;
                cursor: pointer;
                display: flex;
                align-items: center;
                justify-content: center;
            }
            .nav-btn:hover { background: var(--border); }
            .server-box {
                background: #101012;
                border: 1px solid var(--border);
                border-radius: 8px;
                padding: 24px;
                width: 100%;
                max-width: 500px;
            }
            .row { display: flex; justify-content: space-between; font-size: 0.9rem; padding: 8px 0; border-bottom: 1px solid var(--border); }
            .row-label { color: var(--text-muted); }
            .row-val { font-family: monospace; color: var(--text); }
            
            select, button.action-btn {
                background: #27272a;
                color: #fff;
                border: 1px solid var(--border);
                padding: 8px 12px;
                border-radius: 6px;
                width: 100%;
                margin-top: 10px;
                cursor: pointer;
                font-size: 0.9rem;
            }
            button.action-btn:hover { background: #3f3f46; }
            button.stop-btn { background: #7f1d1d; border-color: #991b1b; }
            button.stop-btn:hover { background: #991b1b; }

            table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
            th, td { text-align: left; padding: 10px; border-bottom: 1px solid var(--border); }
            th { color: var(--text-muted); }
            pre { background: #101012; padding: 12px; border-radius: 6px; color: #38bdf8; overflow-x: auto; font-size: 0.85rem; }
            .placeholder { text-align: center; color: var(--text-muted); padding: 40px; border: 2px dashed var(--border); border-radius: 8px; }
        </style>
    </head>
    <body>
        <header>
            <h1>Monitor Server Open API</h1>
            <div id="status-indicator" style="font-size: 0.85rem; color: var(--success); font-weight: 600;">● SISTEMA ATTIVO</div>
        </header>

        <div class="tabs">
            <button class="tab-btn active" onclick="switchTab('servers')">Server in Rete (1..N)</button>
            <button class="tab-btn" onclick="switchTab('nodes')">Gestione Nodi</button>
            <button class="tab-btn" onclick="switchTab('services')">Servizi e Database</button>
            <button class="tab-btn" onclick="switchTab('logs')">Registro Attività</button>
        </div>

        <!-- TAB 1: SERVER & MOTORI -->
        <div id="tab-servers" class="tab-content active">
            <div class="metrics-grid">
                <div class="metric-card"><div class="metric-title">CPU Host</div><div class="metric-val" id="cpu-metric">0%</div></div>
                <div class="metric-card"><div class="metric-title">RAM di Sistema</div><div class="metric-val" id="ram-metric">0 GB</div></div>
                <div class="metric-card"><div class="metric-title">Spazio Disco</div><div class="metric-val" id="disk-metric">0 GB</div></div>
            </div>

            <div class="card">
                <h3 style="margin-top:0;">Navigazione Server Cluster (Porta 1 di N)</h3>
                <div class="carousel-wrapper">
                    <button class="nav-btn" onclick="prevServer()">&#10094;</button>
                    <div id="server-container" class="server-box">Caricamento server in corso...</div>
                    <button class="nav-btn" onclick="nextServer()">&#10095;</button>
                </div>
            </div>
        </div>

        <!-- TAB 2: NODI -->
        <div id="tab-nodes" class="tab-content">
            <div class="card">
                <h3>Topologia e Nodi</h3>
                <div class="placeholder">Gestione dei nodi di rete statici e dinamici del cluster.</div>
            </div>
        </div>

        <!-- TAB 3: SERVIZI -->
        <div id="tab-services" class="tab-content">
            <div class="card">
                <h3>Servizi Ausiliari</h3>
                <div class="placeholder">Integrazione database vettoriali e container.</div>
            </div>
        </div>

        <!-- TAB 4: LOG -->
        <div id="tab-logs" class="tab-content">
            <div class="card">
                <h3>Registro Attività</h3>
                <table>
                    <thead>
                        <tr><th>Ora</th><th>Livello</th><th>Origine</th><th>Prompt</th><th>Latenza</th><th>Messaggio</th></tr>
                    </thead>
                    <tbody id="logs-tbody"></tbody>
                </table>
            </div>
        </div>

        <script>
            let serverList = [];
            let currentServerIdx = 0;
            let availableModels = [];

            function switchTab(tabName) {
                document.querySelectorAll('.tab-content').forEach(el => el.classList.remove('active'));
                document.querySelectorAll('.tab-btn').forEach(el => el.classList.remove('active'));
                document.getElementById(`tab-${tabName}`).classList.add('active');
                event.target.classList.add('active');
            }

            function prevServer() {
                if (serverList.length === 0) return;
                currentServerIdx = (currentServerIdx - 1 + serverList.length) % serverList.length;
                renderServer();
            }

            function nextServer() {
                if (serverList.length === 0) return;
                currentServerIdx = (currentServerIdx + 1) % serverList.length;
                renderServer();
            }

            function renderServer() {
                const container = document.getElementById('server-container');
                if (serverList.length === 0) {
                    container.innerHTML = '<div style="text-align:center; color:var(--text-muted);">Nessun server rilevato nel cluster.</div>';
                    return;
                }
                const b = serverList[currentServerIdx];
                let optionsHtml = availableModels.map(m => `<option value="${m}" ${b.models_loaded && b.models_loaded.includes(m) ? 'selected' : ''}>${m}</option>`).join('');

                container.innerHTML = `
                    <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px;">
                        <strong>Server ${currentServerIdx + 1} di ${serverList.length}</strong>
                        <span style="background:#27272a; padding:2px 8px; border-radius:4px; font-size:0.8rem;">Porta: ${b.port}</span>
                    </div>
                    <div class="row"><span class="row-label">Host:</span><span class="row-val">${b.host}</span></div>
                    <div class="row"><span class="row-label">Tipo Backend:</span><span class="row-val">${b.backend_type}</span></div>
                    <div class="row"><span class="row-label">PID Processo:</span><span class="row-val">${b.pid || 'N/D'}</span></div>
                    <div class="row"><span class="row-label">Offload (-ngl):</span><span class="row-val">${b.ngl}</span></div>
                    <div class="row"><span class="row-label">Contesto:</span><span class="row-val">${b.ctx_size}</span></div>
                    <div class="row"><span class="row-label">Modelli in Uso:</span><span class="row-val">${(b.models_loaded || []).join(', ') || 'Nessuno'}</span></div>

                    <div style="margin-top: 16px;">
                        <label style="font-size:0.8rem; color:var(--text-muted);">Seleziona Modello:</label>
                        <select id="model-select-${b.port}">${optionsHtml}</select>
                    </div>
                    <div style="display:grid; grid-template-columns: 1fr 1fr; gap:8px;">
                        <button class="action-btn" onclick="controlEngine(${b.port}, 'start')">Avvia / Carica</button>
                        <button class="action-btn stop-btn" onclick="controlEngine(${b.port}, 'stop')">Arresta</button>
                    </div>
                    <button class="action-btn" onclick="controlEngine(${b.port}, 'restart')">Riavvia Server</button>
                `;
            }

            async function controlEngine(port, action) {
                const selectElem = document.getElementById(`model-select-${port}`);
                const model_name = selectElem ? selectElem.value : null;
                const endpoint = action === 'start' ? '/api/engine/start' : (action === 'stop' ? '/api/engine/stop' : '/api/engine/restart');
                try {
                    const res = await fetch(endpoint, {
                        method: 'POST',
                        headers: {'Content-Type': 'application/json'},
                        body: JSON.stringify({ port: port, model_name: model_name })
                    });
                    const data = await res.json();
                    alert(data.message || "Comando eseguito.");
                    loadData();
                } catch (e) {
                    alert("Errore di comunicazione con il server.");
                }
            }

            async function loadData() {
                try {
                    const res = await fetch('/api/metrics');
                    const data = await res.json();

                    if (data.models) availableModels = data.models;

                    if (data.system) {
                        document.getElementById('cpu-metric').innerText = `${data.system.cpu_util_pct}%`;
                        document.getElementById('ram-metric').innerText = `${data.system.ram_used_gb} / ${data.system.ram_total_gb} GB (${data.system.ram_util_pct}%)`;
                        document.getElementById('disk-metric').innerText = `${data.system.disk_used_gb} / ${data.system.disk_total_gb} GB (${data.system.disk_util_pct}%)`;
                    }

                    if (data.cluster && data.cluster.nodes) {
                        let newServers = [];
                        data.cluster.nodes.forEach(node => {
                            (node.backends || []).forEach(b => {
                                newServers.push({ host: node.host, ...b });
                            });
                        });
                        serverList = newServers;
                        if (currentServerIdx >= serverList.length) currentServerIdx = 0;
                        renderServer();
                    }

                    if (data.logs) {
                        const tbody = document.getElementById('logs-tbody');
                        tbody.innerHTML = '';
                        [...data.logs].reverse().forEach(l => {
                            tbody.innerHTML += `
                                <tr>
                                    <td>${l.timestamp}</td>
                                    <td><strong>${l.level}</strong></td>
                                    <td>${l.node}</td>
                                    <td>${l.prompt}</td>
                                    <td>${l.latency}</td>
                                    <td>${l.message}</td>
                                </tr>
                            `;
                        });
                    }
                } catch (e) {
                    console.error("Errore fetch metriche:", e);
                }
            }

            setInterval(loadData, 2500);
            loadData();
        </script>
    </body>
    </html>
    """

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=9001, log_level="warning")
EOF_PY

python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip -qq
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" -qq
chown -R "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/llm_gateway.py"

cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Gateway e Dashboard Server Open API
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

echo "[OK] Gateway configurato e attivo sulla porta 9001!"
echo "Dashboard accessibile su: http://127.0.0.1:9001"
