#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/gateway"
SERVICE_FILE="/etc/systemd/system/llm-gateway.service"
CURRENT_USER="${SUDO_USER:-root}"

echo "[*] Configurazione directory gateway in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/logs"

cat << 'EOF' > "$INSTALL_DIR/llm_gateway.py"
#!/usr/bin/env python3
import time
import asyncio
import os
import json
import psutil
from typing import Dict, Any, Optional, List
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
import httpx
from pydantic import BaseModel

app = FastAPI(title="LLM Cluster Dashboard", version="6.2.0")
TOPOLOGY_PATH = "/opt/gateway/cluster-topology.json"
STATIC_PATH = "/opt/gateway/cluster-static-nodes.json"

def load_topology() -> Dict[str, Any]:
    nodes_map = {}
    
    # 1. Carica i nodi statici manuali/esterni
    if os.path.exists(STATIC_PATH):
        try:
            with open(STATIC_PATH, "r") as f:
                static_data = json.load(f)
                for node in static_data.get("nodes", []):
                    nodes_map[node["node_id"]] = node
        except Exception:
            pass

    # 2. Carica i nodi scoperti automaticamente sulla subnet
    if os.path.exists(TOPOLOGY_PATH):
        try:
            with open(TOPOLOGY_PATH, "r") as f:
                auto_data = json.load(f)
                for node in auto_data.get("nodes", []):
                    nodes_map[node["node_id"]] = node
        except Exception:
            pass
            
    return {
        "cluster_version": "2.2.0",
        "nodes": list(nodes_map.values())
    }

def get_local_metrics() -> Dict[str, Any]:
    cpu_percent = psutil.cpu_percent(interval=None)
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    return {
        "cpu_util_pct": cpu_percent,
        "ram_used_gb": round(mem.used / (1024**3), 2),
        "ram_total_gb": round(mem.total / (1024**3), 2),
        "ram_util_pct": mem.percent,
        "disk_used_gb": round(disk.used / (1024**3), 2),
        "disk_total_gb": round(disk.total / (1024**3), 2),
        "disk_util_pct": disk.percent
    }

class GatewayChatRequest(BaseModel):
    model: Optional[str] = None
    messages: List[Dict[str, str]]
    temperature: Optional[float] = 0.2
    stream: Optional[bool] = False

@app.get("/api/metrics")
async def api_metrics():
    return {
        "local_machine": get_local_metrics(),
        "cluster_topology": load_topology()
    }

@app.post("/v1/chat/completions")
async def proxy_chat(req: GatewayChatRequest):
    topology = load_topology()
    nodes = topology.get("nodes", [])
    
    target_backend = None
    for node in nodes:
        for backend in node.get("backends", []):
            models = backend.get("models_loaded", [])
            if not req.model or (models and req.model in models):
                target_backend = {"host": node["host"], "port": backend["port"]}
                break
        if target_backend:
            break
            
    if not target_backend:
        for node in nodes:
            if node.get("backends"):
                b = node["backends"][0]
                target_backend = {"host": node["host"], "port": b["port"]}
                break
                
    if not target_backend:
        raise HTTPException(status_code=503, detail="Nessun nodo di calcolo disponibile nella rete distribuita.")
        
    url = f"http://{target_backend['host']}:{target_backend['port']}/v1/chat/completions"
    async with httpx.AsyncClient(timeout=120.0) as client:
        try:
            resp = await client.post(url, json=req.dict())
            return JSONResponse(status_code=resp.status_code, content=resp.json())
        except Exception as e:
            raise HTTPException(status_code=502, detail=f"Upstream error: {str(e)}")

@app.get("/", response_class=HTMLResponse)
async def dashboard():
    html_content = """
    <!DOCTYPE html>
    <html lang="it">
    <head>
        <meta charset="UTF-8">
        <title>LLM Cluster Dashboard</title>
        <style>
            body { font-family: 'Segoe UI', system-ui, sans-serif; background: #090d16; color: #f3f4f6; margin: 0; padding: 20px; }
            h1 { color: #10b981; }
            .card { background: #111827; border: 1px solid #1f2937; border-radius: 8px; padding: 15px; margin-bottom: 20px; }
            pre { background: #030712; padding: 12px; border-radius: 6px; color: #38bdf8; overflow-x: auto; }
            .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 15px; }
            .metric-val { font-size: 1.4rem; font-weight: bold; color: #10b981; margin-top: 5px; }
        </style>
    </head>
    <body>
        <h1>LLM Cluster Dashboard & Gateway</h1>
        <p>Orchestratore distribuito attivo sulla porta <strong>9001</strong>.</p>
        
        <div class="grid">
            <div class="card">
                <h3>CPU Locale</h3>
                <div class="metric-val" id="local-cpu">--%</div>
            </div>
            <div class="card">
                <h3>RAM Locale</h3>
                <div class="metric-val" id="local-ram">-- / -- GB</div>
            </div>
            <div class="card">
                <h3>Disco Locale</h3>
                <div class="metric-val" id="local-disk">-- / -- GB</div>
            </div>
        </div>

        <div class="card">
            <h3>Topologia Cluster Unificata (Auto + Statici)</h3>
            <pre id="cluster-json">Caricamento in corso...</pre>
        </div>

        <script>
            async function fetchMetrics() {
                try {
                    const res = await fetch('/api/metrics');
                    const data = await res.json();
                    
                    document.getElementById('local-cpu').innerText = data.local_machine.cpu_util_pct + '%';
                    document.getElementById('local-ram').innerText = data.local_machine.ram_used_gb + ' / ' + data.local_machine.ram_total_gb + ' GB (' + data.local_machine.ram_util_pct + '%)';
                    document.getElementById('local-disk').innerText = data.local_machine.disk_used_gb + ' / ' + data.local_machine.disk_total_gb + ' GB (' + data.local_machine.disk_util_pct + '%)';
                    
                    document.getElementById('cluster-json').innerText = JSON.stringify(data.cluster_topology, null, 4);
                } catch(e) {
                    console.error("Errore fetch metriche:", e);
                }
            }
            setInterval(fetchMetrics, 2000);
            fetchMetrics();
        </script>
    </body>
    </html>
    """
    return HTMLResponse(content=html_content, status_code=200)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=9001)
EOF

python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install fastapi uvicorn httpx pydantic psutil

chown -R "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/llm_gateway.py"

cat << EOF > "$SERVICE_FILE"
[Unit]
Description=LLM Cluster Dashboard Gateway
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/llm_gateway.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable llm-gateway.service
systemctl restart llm-gateway.service

echo "[OK] LLM Cluster Dashboard & Gateway configurato e avviato sulla porta 9001!"
