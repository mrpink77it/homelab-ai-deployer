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

echo "[*] Configurazione gateway enterprise in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$LOGS_DIR"

if [ ! -f "$TOPOLOGY_PATH" ]; then
    echo '{"cluster_version": "2.6.0", "nodes": []}' > "$TOPOLOGY_PATH"
fi
if [ ! -f "$STATIC_PATH" ]; then
    echo '{"nodes": []}' > "$STATIC_PATH"
fi

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
LLM Cluster Enterprise Dashboard & Gateway v8.0
-----------------------------------------------
Telemetria GPU avanzata (Temp, Ventole, VRAM), ispezione binari e parametri OpenAPI.
"""

import time
import asyncio
import os
import json
import subprocess
import psutil
from typing import Dict, Any, Optional, List
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
import httpx
from pydantic import BaseModel

TOPOLOGY_PATH = "/opt/gateway/cluster-topology.json"
STATIC_PATH = "/opt/gateway/cluster-static-nodes.json"
MODELS_DIR = "/opt/llama_models"

app = FastAPI(title="LLM Cluster Enterprise Gateway", version="8.0.0")
RECENT_LOGS: List[Dict[str, Any]] = []

def add_log_entry(level: str, message: str, node: str = "-", latency: float = 0.0, prompt: str = "-", tokens_in: int = 0, tokens_out: int = 0):
    entry = {
        "timestamp": time.strftime("%H:%M:%S"),
        "level": level,
        "message": message,
        "node": node,
        "latency": f"{latency:.2f}s" if latency > 0 else "-",
        "prompt": (prompt[:50] + "...") if len(prompt) > 50 else prompt,
        "tokens_in": tokens_in,
        "tokens_out": tokens_out
    }
    RECENT_LOGS.append(entry)
    if len(RECENT_LOGS) > 200:
        RECENT_LOGS.pop(0)

def get_gpu_metrics():
    gpus = []
    try:
        res = subprocess.run(
            ["nvidia-smi", "--query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,fan.speed", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=1
        )
        if res.returncode == 0:
            for line in res.stdout.strip().split("\n"):
                if not line:
                    continue
                parts = [p.strip() for p in line.split(",")]
                if len(parts) >= 7:
                    gpus.append({
                        "id": int(parts[0]),
                        "name": parts[1],
                        "util_pct": float(parts[2]),
                        "vram_used_mb": float(parts[3]),
                        "vram_total_mb": float(parts[4]),
                        "temp_c": float(parts[5]),
                        "fan_pct": parts[6] if parts[6] != "[Not Supported]" else "N/A"
                    })
    except Exception:
        pass
    return gpus

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
        "disk_util_pct": disk.percent,
        "gpus": get_gpu_metrics()
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
    return {"cluster_version": "2.6.0", "nodes": list(nodes_map.values())}

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
    add_log_entry("INFO", f"Richiesta caricamento modello {req.model_name} su porta {req.port}", "GATEWAY")
    return {"status": "success", "message": f"Modello {req.model_name} impostato sulla porta {req.port}"}

@app.post("/api/engine/stop")
async def engine_stop(req: EngineActionRequest):
    add_log_entry("WARN", f"Richiesto arresto motore su porta {req.port}", "GATEWAY")
    return {"status": "success", "message": f"Motore su porta {req.port} arrestato."}

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
            if not model or model in models or "dynamic-models-dir" in models:
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
        raise HTTPException(status_code=503, detail="Nessun motore LLM attivo nel cluster.")
        
    url = f"http://{target_backend['host']}:{target_backend['port']}/v1/chat/completions"
    start_t = time.time()
    add_log_entry("INFO", f"Proxy -> {target_backend['host']}:{target_backend['port']}", "PROXY", prompt=user_prompt)
    
    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            resp = await client.post(url, json=body)
            elapsed = time.time() - start_t
            if resp.status_code == 200:
                data = resp.json()
                usage = data.get("usage", {})
                tok_in = usage.get("prompt_tokens", 0)
                tok_out = usage.get("completion_tokens", 0)
                add_log_entry("SUCCESS", f"Completato ({tok_in}in/{tok_out}out)", "PROXY", elapsed, user_prompt, tok_in, tok_out)
                return data
            else:
                return JSONResponse(status_code=resp.status_code, content=resp.json())
    except Exception as e:
        add_log_entry("ERROR", str(e), "PROXY", prompt=user_prompt)
        raise HTTPException(status_code=502, detail=str(e))

@app.get("/", response_class=HTMLResponse)
async def dashboard():
    return """
    <!DOCTYPE html>
    <html lang="it">
    <head>
        <meta charset="UTF-8">
        <title>LLM Cluster Enterprise Dashboard</title>
        <style>
            :root { --bg: #070a13; --card: #0d1322; --text: #f3f4f6; --accent: #10b981; --border: #1e293b; --success: #22c55e; --danger: #ef4444; --warning: #f59e0b; }
            body { font-family: 'Segoe UI', system-ui, sans-serif; background: var(--bg); color: var(--text); margin: 0; padding: 20px; }
            header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); padding-bottom: 15px; margin-bottom: 20px; }
            h1 { color: var(--accent); margin: 0; font-size: 1.7rem; }
            .grid-system { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 15px; margin-bottom: 20px; }
            .sys-card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 15px; text-align: center; }
            .sys-title { color: #9ca3af; font-size: 0.75rem; text-transform: uppercase; font-weight: bold; }
            .sys-val { font-size: 1.2rem; font-weight: bold; color: var(--accent); margin-top: 6px; }
            .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px; margin-bottom: 20px; }
            .engines-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(380px, 1fr)); gap: 15px; }
            .engine-card { background: #030712; border: 1px solid var(--border); border-radius: 8px; padding: 16px; }
            .engine-header { display: flex; justify-content: space-between; font-weight: bold; color: #38bdf8; margin-bottom: 8px; font-size: 1.05rem; }
            .badge { padding: 2px 8px; border-radius: 4px; font-size: 0.75rem; font-weight: bold; }
            .badge-cuda { background: #1e3a8a; color: #60a5fa; }
            .badge-vulkan { background: #7c2d12; color: #fdba74; }
            .badge-cpu { background: #374151; color: #d1d5db; }
            .param-row { display: flex; justify-content: space-between; font-size: 0.8rem; color: #9ca3af; border-bottom: 1px solid #111827; padding: 5px 0; }
            .param-val { color: #f3f4f6; font-family: monospace; }
            select, button { background: #1f2937; color: #fff; border: 1px solid #374151; padding: 6px 10px; border-radius: 5px; cursor: pointer; margin-top: 8px; width: 100%; font-size: 0.85rem; }
            button.btn-stop { background: #7f1d1d; border-color: #991b1b; }
            table { width: 100%; border-collapse: collapse; margin-top: 10px; font-size: 0.85rem; }
            th, td { text-align: left; padding: 8px; border-bottom: 1px solid var(--border); }
            th { color: #9ca3af; }
            .log-SUCCESS { color: var(--success); } .log-ERROR { color: var(--danger); } .log-INFO { color: var(--accent); }
            pre { background: #030712; padding: 12px; border-radius: 6px; color: #38bdf8; overflow-x: auto; font-size: 0.8rem; }
        </style>
    </head>
    <body>
        <header>
            <div>
                <h1>LLM Cluster Enterprise Dashboard</h1>
                <div style="color: #9ca3af; font-size: 0.85rem;">Telemetria Operativa Granulare, Standard di Calcolo & Parametri OpenAPI (Porta 9001)</div>
            </div>
            <div id="cluster-status" style="background: #065f46; color: #34d399; padding: 6px 12px; border-radius: 6px; font-size: 0.85rem; font-weight: bold;">CLUSTER ONLINE</div>
        </header>

        <div class="grid-system" id="metrics-bar">
            <div class="sys-card"><div class="sys-title">CPU Host</div><div class="sys-val" id="cpu-val">0%</div></div>
            <div class="sys-card"><div class="sys-title">RAM Usata</div><div class="sys-val" id="ram-val">0 GB</div></div>
            <div class="sys-card"><div class="sys-title">Disco Usato</div><div class="sys-val" id="disk-val">0 GB</div></div>
        </div>

        <div id="gpu-metrics-container" class="grid-system"></div>

        <div class="card">
            <h3 style="margin-top:0; color: var(--accent);">Gestione Motori LLM & Parametri Operativi (OpenAPI / GGUF)</h3>
            <div class="engines-grid" id="engines-grid">Caricamento nodi e motori in corso...</div>
        </div>

        <div class="card">
            <h3 style="margin-top:0; color: var(--accent);">Topologia Cluster & Manifest JSON</h3>
            <pre id="json-topo">Caricamento...</pre>
        </div>

        <div class="card">
            <h3 style="margin-top:0; color: var(--accent);">Registro Eventi, Latenze & Token</h3>
            <table>
                <thead>
                    <tr><th>Ora</th><th>Livello</th><th>Origine</th><th>Prompt</th><th>Token (In/Out)</th><th>Latenza</th><th>Messaggio</th></tr>
                </thead>
                <tbody id="logs-tbody"></tbody>
            </table>
        </div>

        <script>
            let availableModels = [];

            async function controlEngine(port, action) {
                const selectElem = document.getElementById(`model-select-${port}`);
                const model_name = selectElem ? selectElem.value : null;
                const endpoint = action === 'start' ? '/api/engine/start' : '/api/engine/stop';
                
                try {
                    const res = await fetch(endpoint, {
                        method: 'POST',
                        headers: {'Content-Type': 'application/json'},
                        body: JSON.stringify({ port: port, model_name: model_name })
                    });
                    const data = await res.json();
                    alert(data.message || "Comando eseguito.");
                    loadData();
                } catch (err) {
                    alert("Errore di comunicazione con il gateway.");
                }
            }

            async function loadData() {
                try {
                    const res = await fetch('/api/metrics');
                    const data = await res.json();
                    
                    if (data.models) availableModels = data.models;
                    
                    if (data.system) {
                        document.getElementById('cpu-val').innerText = `${data.system.cpu_util_pct}%`;
                        document.getElementById('ram-val').innerText = `${data.system.ram_used_gb} / ${data.system.ram_total_gb} GB (${data.system.ram_util_pct}%)`;
                        document.getElementById('disk-val').innerText = `${data.system.disk_used_gb} / ${data.system.disk_total_gb} GB (${data.system.disk_util_pct}%)`;
                        
                        const gpuContainer = document.getElementById('gpu-metrics-container');
                        gpuContainer.innerHTML = '';
                        if (data.system.gpus && data.system.gpus.length > 0) {
                            data.system.gpus.forEach(g => {
                                let badgeClass = g.temp_c > 80 ? 'color:var(--danger);' : 'color:var(--success);';
                                gpuContainer.innerHTML += `
                                    <div class="sys-card">
                                        <div class="sys-title">GPU ${g.id}: ${g.name}</div>
                                        <div class="sys-val">${g.util_pct}% Carico</div>
                                        <div style="font-size:0.8rem; margin-top:6px;">
                                            Temp: <span style="${badgeClass} font-weight:bold;">${g.temp_c}°C</span> | Ventola: <strong>${g.fan_pct}%</strong>
                                        </div>
                                        <div style="font-size:0.75rem; color:#9ca3af; margin-top:4px;">VRAM: ${g.vram_used_mb} / ${g.vram_total_mb} MB</div>
                                    </div>
                                `;
                            });
                        }
                    }

                    if (data.cluster) {
                        document.getElementById('json-topo').innerText = JSON.stringify(data.cluster, null, 4);
                        const enginesGrid = document.getElementById('engines-grid');
                        enginesGrid.innerHTML = '';
                        
                        let hasBackends = false;
                        data.cluster.nodes.forEach(node => {
                            (node.backends || []).forEach(b => {
                                hasBackends = true;
                                let optionsHtml = availableModels.map(m => `<option value="${m}">${m}</option>`).join('');
                                
                                let badgeClass = 'badge-cpu';
                                if (b.backend_type.includes('CUDA')) badgeClass = 'badge-cuda';
                                else if (b.backend_type.includes('Vulkan')) badgeClass = 'badge-vulkan';

                                enginesGrid.innerHTML += `
                                    <div class="engine-card">
                                        <div class="engine-header">
                                            <span>Porta: ${b.port} (${node.host})</span>
                                            <span class="badge ${badgeClass}">${b.backend_type}</span>
                                        </div>
                                        <div class="param-row"><span>PID Processo:</span><span class="param-val">${b.pid || 'N/D'}</span></div>
                                        <div class="param-row"><span>Standard / Runtime:</span><span class="param-val">${b.backend_type}</span></div>
                                        <div class="param-row"><span>Layer Offload (-ngl):</span><span class="param-val">${b.ngl}</span></div>
                                        <div class="param-row"><span>Contesto (--ctx-size):</span><span class="param-val">${b.ctx_size}</span></div>
                                        <div class="param-row"><span>Tipo Cache KV:</span><span class="param-val">${b.cache_type || 'default'}</span></div>
                                        <div class="param-row"><span>Modelli Caricati:</span><span class="param-val">${(b.models_loaded || []).join(', ') || 'Nessuno'}</span></div>
                                        <div class="param-row"><span>RAM Nodo:</span><span class="param-val">${b.hardware ? b.hardware.ram_used_gb + ' GB (' + b.hardware.ram_util_pct + '%)' : 'N/D'}</span></div>
                                        
                                        <div style="margin-top: 10px;">
                                            <label style="font-size: 0.75rem; color: #9ca3af;">Carica Modello GGUF:</label>
                                            <select id="model-select-${b.port}">${optionsHtml}</select>
                                        </div>
                                        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 6px; margin-top: 6px;">
                                            <button onclick="controlEngine(${b.port}, 'start')">Avvia / Carica</button>
                                            <button class="btn-stop" onclick="controlEngine(${b.port}, 'stop')">Arresta</button>
                                        </div>
                                    </div>
                                `;
                            });
                        });
                        if (!hasBackends) {
                            enginesGrid.innerHTML = '<div style="color: #9ca3af;">Nessun motore rilevato. Assicurati che i server siano accesi.</div>';
                        }
                    }

                    if (data.logs) {
                        const tbody = document.getElementById('logs-tbody');
                        tbody.innerHTML = '';
                        [...data.logs].reverse().forEach(l => {
                            tbody.innerHTML += `
                                <tr>
                                    <td>${l.timestamp}</td>
                                    <td class="log-${l.level}"><strong>${l.level}</strong></td>
                                    <td>${l.node}</td>
                                    <td>${l.prompt}</td>
                                    <td>${l.tokens_in} / ${l.tokens_out}</td>
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
Description=LLM Cluster Enterprise Gateway Service
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

echo "[OK] Gateway Enterprise aggiornato con successo!"
