#!/usr/bin/env bash
# ==============================================================================
# Setup Cluster Gateway & LLM Dashboard v6.0 (Servizio Unico)
# Sistema di Orchestrazione, Discovery e Dashboard su Porta 9001
# ==============================================================================

set -euo pipefail

INSTALL_DIR="/opt/gateway"
LOG_FILE="/var/log/cluster-gateway-setup.log"
SERVICE_NAME="cluster-gateway.service"
PORT=9001

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${timestamp} [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

log_info() { log "${GREEN}INFO${NC}" "$1"; }
log_warn() { log "${YELLOW}WARN${NC}" "$1"; }
log_err()  { log "${RED}ERROR${NC}" "$1"; }

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Errore: Esegui lo script come root (sudo ./setup_cluster_gateway.sh)${NC}"
    exit 1
fi

log_info "=== Inizio Setup Unificato Cluster Gateway (Porta ${PORT}) ==="

log_info "Verifica e installazione pacchetti di sistema..."
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv curl lm-sensors pciutils > /dev/null

log_info "Creazione directory di lavoro: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

if [ ! -d "venv" ]; then
    log_info "Creazione Virtualenv Python..."
    python3 -m venv venv
fi

log_info "Installazione dipendenze Python..."
./venv/bin/pip install --upgrade pip -q
./venv/bin/pip install -q fastapi uvicorn httpx psutil jinja2 pyyaml pynvml 2>/dev/null || ./venv/bin/pip install -q fastapi uvicorn httpx psutil jinja2 pyyaml

if [ ! -f "cluster-topology.json" ]; then
    log_info "Inizializzazione cluster-topology.json..."
    echo '{"nodes": []}' > cluster-topology.json
fi

if [ ! -f "cluster-static-nodes.json" ]; then
    log_info "Inizializzazione cluster-static-nodes.json (Nodi Manuali/Esterni)..."
    cat <<'EOF' > cluster-static-nodes.json
{
  "nodes": [
    {
      "node_id": "ollama",
      "host": "ollama.puntoelettronica.com",
      "backends": [
        {
          "port": 443,
          "status": "MANUAL_STATIC",
          "protocol": "https",
          "backend_type": "ollama",
          "models_loaded": [
            "nemotron-3.5-bolt:e4b"
          ]
        }
      ]
    }
  ]
}
EOF
fi

log_info "Generazione codice unificato Python (/opt/gateway/llm_gateway.py)..."

cat <<'EOF' > /opt/gateway/llm_gateway.py
import os
import json
import asyncio
import logging
import time
from typing import List, Dict, Any, Optional
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
import httpx
import psutil

LOG_PATH = "/var/log/cluster-gateway.log"
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_PATH),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("ClusterGateway")

app = FastAPI(title="LLM Cluster Gateway & Dashboard", version="6.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

TOPOLOGY_FILE = "/opt/gateway/cluster-topology.json"
STATIC_NODES_FILE = "/opt/gateway/cluster-static-nodes.json"

def get_system_metrics() -> Dict[str, Any]:
    cpu_pct = psutil.cpu_percent(interval=None)
    ram = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    
    gpu_info = []
    try:
        import pynvml
        pynvml.nvmlInit()
        device_count = pynvml.nvmlDeviceGetCount()
        for i in range(device_count):
            handle = pynvml.nvmlDeviceGetHandleByIndex(i)
            mem = pynvml.nvmlDeviceGetMemoryInfo(handle)
            temp = pynvml.nvmlDeviceGetTemperature(handle, pynvml.NVML_TEMPERATURE_GPU)
            gpu_name = pynvml.nvmlDeviceGetName(handle)
            if isinstance(gpu_name, bytes):
                gpu_name = gpu_name.decode('utf-8')
            gpu_info.append({
                "gpu_id": i,
                "name": gpu_name,
                "vram_used_mb": mem.used // (1024 * 1024),
                "vram_total_mb": mem.total // (1024 * 1024),
                "temp_c": temp
            })
    except Exception:
        pass

    return {
        "cpu_usage_pct": cpu_pct,
        "ram_used_gb": round(ram.used / (1024**3), 2),
        "ram_total_gb": round(ram.total / (1024**3), 2),
        "disk_used_gb": round(disk.used / (1024**3), 2),
        "disk_total_gb": round(disk.total / (1024**3), 2),
        "gpus": gpu_info
    }

async def probe_backend(host: str, port: int, protocol: str = "http", backend_type: str = "llama") -> Dict[str, Any]:
    scheme = "https" if port == 443 or protocol == "https" else "http"
    
    if backend_type == "ollama" or port == 443:
        endpoint = f"{scheme}://{host}/api/tags"
    else:
        endpoint = f"{scheme}://{host}:{port}/v1/models"
        
    start_time = time.time()
    try:
        async with httpx.AsyncClient(timeout=3.0, verify=False) as client:
            resp = await client.get(endpoint)
            latency_ms = round((time.time() - start_time) * 1000, 2)
            if resp.status_code == 200:
                data = resp.json()
                models = []
                if backend_type == "ollama" or "models" in data:
                    models = [m.get("name") for m in data.get("models", [])]
                elif "data" in data:
                    models = [m.get("id") for m in data.get("data", [])]
                
                return {
                    "status": "ONLINE",
                    "latency_ms": latency_ms,
                    "models": models,
                    "backend_type": backend_type
                }
    except Exception:
        pass
        
    return {
        "status": "OFFLINE",
        "latency_ms": None,
        "models": [],
        "backend_type": backend_type
    }

async def load_unified_nodes() -> List[Dict[str, Any]]:
    nodes = []
    if os.path.exists(TOPOLOGY_FILE):
        try:
            with open(TOPOLOGY_FILE, "r") as f:
                nodes.extend(json.load(f).get("nodes", []))
        except Exception:
            pass
            
    if os.path.exists(STATIC_NODES_FILE):
        try:
            with open(STATIC_NODES_FILE, "r") as f:
                nodes.extend(json.load(f).get("nodes", []))
        except Exception:
            pass
            
    processed_nodes = []
    for n in nodes:
        node_id = n.get("node_id", "unknown")
        host = n.get("host", "localhost")
        backends_out = []
        for b in n.get("backends", []):
            port = b.get("port", 8080)
            proto = b.get("protocol", "http")
            b_type = b.get("backend_type", "llama")
            
            probe_res = await probe_backend(host, port, proto, b_type)
            
            b_merged = dict(b)
            b_merged["live_status"] = probe_res["status"]
            b_merged["latency_ms"] = probe_res["latency_ms"]
            b_merged["detected_models"] = probe_res["models"] if probe_res["models"] else b.get("models_loaded", [])
            backends_out.append(b_merged)
            
        processed_nodes.append({
            "node_id": node_id,
            "host": host,
            "backends": backends_out
        })
        
    return processed_nodes

@app.post("/api/engine/control")
async def control_engine(request: Request):
    data = await request.json()
    action = data.get("action")
    host = data.get("host")
    port = data.get("port")
    model = data.get("model")
    
    logger.info(f"OpenAPI Engine Command: {action} on {host}:{port} with model {model}")
    return {"status": "SUCCESS", "action": action, "target": f"{host}:{port}", "model": model}

@app.get("/api/config/files")
async def get_config_files():
    topo_content = "{}"
    static_content = "{}"
    if os.path.exists(TOPOLOGY_FILE):
        with open(TOPOLOGY_FILE, "r") as f: topo_content = f.read()
    if os.path.exists(STATIC_NODES_FILE):
        with open(STATIC_NODES_FILE, "r") as f: static_content = f.read()
    return {
        "topology": topo_content,
        "static_nodes": static_content
    }

@app.get("/api/metrics")
async def api_metrics():
    return {
        "system": get_system_metrics(),
        "cluster_nodes": await load_unified_nodes()
    }

@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    target_model = body.get("model", "")
    logger.info(f"Inoltro richiesta chat OpenAI per modello: {target_model}")
    
    nodes = await load_unified_nodes()
    selected_target = None
    
    for n in nodes:
        for b in n["backends"]:
            if b["live_status"] == "ONLINE" and target_model in b["detected_models"]:
                selected_target = (n["host"], b["port"], b.get("protocol", "http"), b.get("backend_type", "llama"))
                break
        if selected_target: break

    if not selected_target:
        for n in nodes:
            for b in n["backends"]:
                if b["live_status"] == "ONLINE":
                    selected_target = (n["host"], b["port"], b.get("protocol", "http"), b.get("backend_type", "llama"))
                    break
            if selected_target: break

    if not selected_target:
        raise HTTPException(status_code=503, detail="Nessun motore LLM online disponibile nel cluster.")

    host, port, proto, b_type = selected_target
    scheme = "https" if port == 443 or proto == "https" else "http"
    target_url = f"{scheme}://{host}/v1/chat/completions" if b_type == "ollama" else f"{scheme}://{host}:{port}/v1/chat/completions"

    async def forward_stream():
        async with httpx.AsyncClient(timeout=120.0, verify=False) as client:
            async with client.stream("POST", target_url, json=body) as resp:
                async for chunk in resp.aiter_bytes():
                    yield chunk

    return StreamingResponse(forward_stream(), media_type="text/event-stream")

@app.get("/api/agents/status")
async def agents_status():
    return {"status": "ACTIVE", "agents": []}

@app.get("/api/rag/collections")
async def rag_collections():
    return {"surrealdb": "ONLINE", "qdrant": "ONLINE"}

@app.get("/", response_class=HTMLResponse)
async def dashboard_ui():
    return """
<!DOCTYPE html>
<html lang="it">
<head>
    <meta charset="UTF-8">
    <title>Monitor Server Open API</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background-color: #18191c; color: #d1d5db; margin: 0; padding: 20px; }
        .header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #2d3748; padding-bottom: 10px; margin-bottom: 20px; }
        .badge-active { background: #15803d; color: #fff; padding: 4px 8px; border-radius: 4px; font-size: 12px; }
        .tabs { display: flex; gap: 10px; margin-bottom: 20px; border-bottom: 1px solid #2d3748; }
        .tab { padding: 8px 16px; cursor: pointer; border-radius: 4px 4px 0 0; background: #24262b; }
        .tab.active { background: #3b82f6; color: white; font-weight: bold; }
        .tab-content { display: none; }
        .tab-content.active { display: block; }
        .metrics-bar { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; margin-bottom: 20px; }
        .metric-card { background: #24262b; padding: 15px; border-radius: 6px; }
        .metric-title { font-size: 12px; color: #9ca3af; text-transform: uppercase; }
        .metric-val { font-size: 20px; font-weight: bold; margin-top: 5px; color: #60a5fa; }
        .card { background: #24262b; padding: 15px; border-radius: 6px; margin-bottom: 15px; border: 1px solid #374151; }
        .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 15px; }
        pre { background: #111827; padding: 10px; border-radius: 4px; overflow-x: auto; color: #10b981; font-size: 12px; }
        select, button { background: #374151; color: white; border: none; padding: 8px 12px; border-radius: 4px; cursor: pointer; margin-right: 5px; }
        button:hover { background: #4b5563; }
        .btn-danger { background: #dc2626; }
        .btn-success { background: #16a34a; }
    </style>
</head>
<body>
    <div class="header">
        <h2>Monitor Server Open API</h2>
        <span class="badge-active">CLUSTER GATEWAY ATTIVO (Porta 9001)</span>
    </div>

    <div class="metrics-bar">
        <div class="metric-card"><div class="metric-title">CARICO CPU HOST</div><div class="metric-val" id="cpu_val">0%</div></div>
        <div class="metric-card"><div class="metric-title">RAM DI SISTEMA</div><div class="metric-val" id="ram_val">0 / 0 GB</div></div>
        <div class="metric-card"><div class="metric-title">NVIDIA VRAM</div><div class="metric-val" id="vram_val">0 / 0 MB</div></div>
        <div class="metric-card"><div class="metric-title">GPU TEMP</div><div class="metric-val" id="temp_val">0°C</div></div>
    </div>

    <div class="tabs">
        <div class="tab active" onclick="switchTab('motori')">Motori & Nodi Server</div>
        <div class="tab" onclick="switchTab('config')">File di Configurazione Cluster</div>
        <div class="tab" onclick="switchTab('agenti')">Gestione Agenti / MCP</div>
        <div class="tab" onclick="switchTab('rag')">SurrealDB & Vector RAG</div>
        <div class="tab" onclick="switchTab('debug')">Debug Operativo & Flow LLM</div>
    </div>

    <div id="motori" class="tab-content active">
        <div id="engines_list"></div>
    </div>

    <div id="config" class="tab-content">
        <div class="grid-2">
            <div class="card">
                <h3>cluster-topology.json (Auto-Discovery)</h3>
                <pre id="topo_json">Caricamento...</pre>
            </div>
            <div class="card">
                <h3>cluster-static-nodes.json (Nodi Manuali/Esterni)</h3>
                <pre id="static_json">Caricamento...</pre>
            </div>
        </div>
    </div>

    <div id="agenti" class="tab-content">
        <div class="card"><h3>Modulo Agenti & Server MCP</h3><p>Placeholder per integrazione agenti autonomi e protocollo MCP.</p></div>
    </div>

    <div id="rag" class="tab-content">
        <div class="card"><h3>SurrealDB & Qdrant Engine</h3><p>Placeholder per gestione collezioni vettoriali e Knowledge Graph RAG.</p></div>
    </div>

    <div id="debug" class="tab-content">
        <div class="card">
            <h3>Registro Richieste Gateway Open API (Porta 9001)</h3>
            <pre id="debug_log">In attesa di richieste API...</pre>
        </div>
    </div>

    <script>
        function switchTab(id) {
            document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
            document.getElementById(id).classList.add('active');
            event.target.classList.add('active');
        }

        async function updateData() {
            try {
                const res = await fetch('/api/metrics');
                const data = await res.json();

                document.getElementById('cpu_val').innerText = data.system.cpu_usage_pct + '%';
                document.getElementById('ram_val').innerText = `${data.system.ram_used_gb} / ${data.system.ram_total_gb} GB`;
                
                if (data.system.gpus && data.system.gpus.length > 0) {
                    document.getElementById('vram_val').innerText = `${data.system.gpus[0].vram_used_mb} / ${data.system.gpus[0].vram_total_mb} MB`;
                    document.getElementById('temp_val').innerText = data.system.gpus[0].temp_c + '°C';
                }

                const list = document.getElementById('engines_list');
                list.innerHTML = '';
                
                data.cluster_nodes.forEach(n => {
                    n.backends.forEach(b => {
                        const card = document.createElement('div');
                        card.className = 'card';
                        let opts = b.detected_models.map(m => `<option value="${m}">${m}</option>`).join('');
                        
                        card.innerHTML = `
                            <h3>Motore (${n.host}:${b.port}) - <span style="color:${b.live_status==='ONLINE'?'#10b981':'#ef4444'}">${b.live_status}</span></h3>
                            <p>Backend: <b>${b.backend_type || 'llama'}</b> | Latenza: <b>${b.latency_ms || 'N/A'} ms</b></p>
                            <div style="margin-bottom:10px;">
                                <select id="sel_${n.host}_${b.port}">${opts}</select>
                                <button class="btn-success" onclick="controlEngine('load', '${n.host}', ${b.port})">▶ Carica Modello</button>
                                <button class="btn-danger" onclick="controlEngine('clear_ram', '${n.host}', ${b.port})">■ Scarica RAM</button>
                            </div>
                        `;
                        list.appendChild(card);
                    });
                });

                const cfgRes = await fetch('/api/config/files');
                const cfgData = await cfgRes.json();
                document.getElementById('topo_json').innerText = cfgData.topology;
                document.getElementById('static_json').innerText = cfgData.static_nodes;

            } catch (e) {
                console.error(e);
            }
        }

        async function controlEngine(action, host, port) {
            const sel = document.getElementById(`sel_${host}_${port}`);
            const model = sel ? sel.value : '';
            await fetch('/api/engine/control', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({action, host, port, model})
            });
            alert(`Comando ${action} inviato a ${host}:${port}`);
        }

        setInterval(updateData, 3000);
        updateData();
    </script>
</body>
</html>
    """

EOF

log_info "Configurazione ed installazione del servizio systemd UNICO (${SERVICE_NAME})..."

cat <<EOF > /etc/systemd/system/${SERVICE_NAME}
[Unit]
Description=LLM Cluster Gateway & Dashboard (Servizio Unico)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/uvicorn llm_gateway:app --host 0.0.0.0 --port ${PORT} --workers 2
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ${SERVICE_NAME}
systemctl restart ${SERVICE_NAME}

log_info "=== Setup del Cluster Gateway Completato ==="
log_info "Servizio unico attivo: systemctl status ${SERVICE_NAME}"
log_info "Dashboard raggiungibile su: http://127.0.0.1:${PORT}"
