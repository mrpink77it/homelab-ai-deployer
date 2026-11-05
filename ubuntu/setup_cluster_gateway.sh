#!/usr/bin/env bash
# ==============================================================================
# Setup Cluster Gateway & LLM Dashboard v6.0
# Sistema di Orchestrazione, Discovery e Dashboard su Porta 9001
# ==============================================================================

set -euo pipefail

# --- Configurazione Percorsi e Variabili ---
INSTALL_DIR="/opt/gateway"
LOG_FILE="/var/log/cluster-gateway-setup.log"
SERVICE_NAME="cluster-gateway.service"
PORT=9001

# --- Colori per Debug a Video ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

log_info "=== Inizio Configurazione LLM Cluster Gateway & Dashboard (Porta ${PORT}) ==="

# --- 1. Preparazione Ambiente e Dipendenze System ---
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

log_info "Installazione dipendenze Python (FastAPI, Uvicorn, httpx, psutil, jinja2)..."
./venv/bin/pip install --upgrade pip -q
./venv/bin/pip install -q fastapi uvicorn httpx psutil jinja2 pyyaml pynvml 2>/dev/null || ./venv/bin/pip install -q fastapi uvicorn httpx psutil jinja2 pyyaml

# --- 2. Inizializzazione File di Topologia (Se non presenti) ---
if [ ! -f "cluster-topology.json" ]; then
    log_info "Inizializzazione file topologia dinamica (cluster-topology.json)..."
    echo '{"nodes": []}' > cluster-topology.json
fi

if [ ! -f "cluster-static-nodes.json" ]; then
    log_info "Inizializzazione file nodi statici/esterni (cluster-static-nodes.json)..."
    cat <<'EOF' > cluster-static-nodes.json
{
  "nodes": [
    {
      "node_id": "ollama-external",
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

# --- 3. Scrittura del Codice Principale Python (llm_gateway.py) ---
log_info "Generazione codice principale Gateway Python (/opt/gateway/llm_gateway.py)..."

cat <<'EOF' > /opt/gateway/llm_gateway.py
import os
import json
import asyncio
import logging
import time
from typing import List, Dict, Any, Optional
from fastapi import FastAPI, Request, HTTPException, BackgroundTasks
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
import httpx
import psutil

# Configuration & Logging
LOG_PATH = "/var/log/cluster-gateway.log"
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_PATH),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("LLM-Gateway")

app = FastAPI(title="LLM Cluster Gateway & Orchestrator", version="6.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

TOPOLOGY_FILE = "/opt/gateway/cluster-topology.json"
STATIC_NODES_FILE = "/opt/gateway/cluster-static-nodes.json"

# Hardware Metrics Collector
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
            gpu_info.append({
                "gpu_id": i,
                "name": pynvml.nvmlDeviceGetName(handle),
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

# Probe Single Backend (Generic / Llama.cpp / Ollama)
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
    except Exception as e:
        logger.debug(f"Probe failed for {host}:{port} -> {str(e)}")
        
    return {
        "status": "OFFLINE",
        "latency_ms": None,
        "models": [],
        "backend_type": backend_type
    }

# Unified Topology Resolver
async def load_unified_nodes() -> List[Dict[str, Any]]:
    nodes = []
    
    # 1. Load Dynamic Topology
    if os.path.exists(TOPOLOGY_FILE):
        try:
            with open(TOPOLOGY_FILE, "r") as f:
                ddata = json.load(f)
                nodes.extend(ddata.get("nodes", []))
        except Exception as e:
            logger.error(f"Error reading dynamic topology: {e}")
            
    # 2. Load Static Nodes
    if os.path.exists(STATIC_NODES_FILE):
        try:
            with open(STATIC_NODES_FILE, "r") as f:
                sdata = json.load(f)
                nodes.extend(sdata.get("nodes", []))
        except Exception as e:
            logger.error(f"Error reading static nodes: {e}")
            
    # Probe Nodes Health
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
            # Fallback to config models if offline or list empty
            b_merged["detected_models"] = probe_res["models"] if probe_res["models"] else b.get("models_loaded", [])
            backends_out.append(b_merged)
            
        processed_nodes.append({
            "node_id": node_id,
            "host": host,
            "backends": backends_out
        })
        
    return processed_nodes

# API Routes
@app.get("/api/metrics")
async def api_metrics():
    sys_m = get_system_metrics()
    nodes = await load_unified_nodes()
    return {
        "system": sys_m,
        "cluster_nodes": nodes
    }

# Forwarding Proxy placeholder for OpenAI / Ollama compatible calls
@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    target_model = body.get("model", "")
    logger.info(f"Incoming Chat Request for model: {target_model}")
    
    nodes = await load_unified_nodes()
    selected_target = None
    
    # Routing Logic
    for n in nodes:
        for b in n["backends"]:
            if b["live_status"] == "ONLINE" and target_model in b["detected_models"]:
                selected_target = (n["host"], b["port"], b.get("protocol", "http"), b.get("backend_type", "llama"))
                break
        if selected_target:
            break

    if not selected_target:
        # Fallback to first active backend
        for n in nodes:
            for b in n["backends"]:
                if b["live_status"] == "ONLINE":
                    selected_target = (n["host"], b["port"], b.get("protocol", "http"), b.get("backend_type", "llama"))
                    break
            if selected_target:
                break

    if not selected_target:
        raise HTTPException(status_code=503, detail="No online LLM engine available in cluster.")

    host, port, proto, b_type = selected_target
    scheme = "https" if port == 443 or proto == "https" else "http"
    
    if b_type == "ollama":
        target_url = f"{scheme}://{host}/v1/chat/completions"
    else:
        target_url = f"{scheme}://{host}:{port}/v1/chat/completions"

    async def forward_stream():
        async with httpx.AsyncClient(timeout=120.0, verify=False) as client:
            async with client.stream("POST", target_url, json=body) as resp:
                async for chunk in resp.aiter_bytes():
                    yield chunk

    return StreamingResponse(forward_stream(), media_type="text/event-stream")

# --- PLACEHOLDERS PER AGENTI, RAG, SURREALDB E INCUS ---
@app.get("/api/agents/status")
async def agents_status():
    return {"status": "ACTIVE", "framework": "MCP/Aider Direct Protocol", "active_agents": []}

@app.get("/api/rag/collections")
async def rag_collections():
    return {"surrealdb": "ONLINE", "qdrant": "ONLINE", "collections": ["documentation", "codebase_indexes"]}

@app.get("/api/incus/containers")
async def incus_containers():
    return {"containers": [], "status": "READY"}

# Frontend Dashboard Single-Page HTML
@app.get("/", response_class=HTMLResponse)
async def dashboard_ui():
    return """
<!DOCTYPE html>
<html lang="it">
<head>
    <meta charset="UTF-8">
    <title>LLM Cluster Gateway Dashboard</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #121212; color: #e0e0e0; margin: 0; padding: 20px; }
        h1, h2 { color: #4caf50; }
        .tabs { display: flex; border-bottom: 2px solid #333; margin-bottom: 20px; }
        .tab { padding: 12px 24px; cursor: pointer; background: #1e1e1e; margin-right: 4px; border-radius: 6px 6px 0 0; }
        .tab.active { background: #333; color: #4caf50; font-weight: bold; border-bottom: 2px solid #4caf50; }
        .tab-content { display: none; }
        .tab-content.active { display: block; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 15px; }
        .card { background: #1e1e1e; padding: 20px; border-radius: 8px; border: 1px solid #2a2a2a; }
        .badge { padding: 4px 8px; border-radius: 4px; font-size: 12px; font-weight: bold; }
        .badge-online { background: #1b5e20; color: #81c784; }
        .badge-offline { background: #b71c1c; color: #ef9a9a; }
        pre { background: #000; padding: 10px; border-radius: 4px; overflow-x: auto; color: #00ff00; }
    </style>
</head>
<body>
    <h1>LLM Cluster Gateway Dashboard (Porta 9001)</h1>
    
    <div class="tabs">
        <div class="tab active" onclick="switchTab('dashboard')">Dashboard Motori & Hardware</div>
        <div class="tab" onclick="switchTab('agents')">Agenti & MCP</div>
        <div class="tab" onclick="switchTab('rag')">RAG & Vector DB</div>
        <div class="tab" onclick="switchTab('incus')">Incus Container</div>
        <div class="tab" onclick="switchTab('logs')">Log & Telemetria</div>
    </div>

    <!-- TAB DASHBOARD -->
    <div id="dashboard" class="tab-content active">
        <h2>Risorse di Sistema Locale</h2>
        <div class="grid">
            <div class="card">
                <h3>CPU & RAM</h3>
                <p>CPU Usato: <span id="cpu_val">0</span>%</p>
                <p>RAM Usata: <span id="ram_val">0 / 0</span> GB</p>
            </div>
            <div class="card">
                <h3>Archiviazione</h3>
                <p>Disco Usato: <span id="disk_val">0 / 0</span> GB</p>
            </div>
        </div>

        <h2>Motori del Cluster Rilevati</h2>
        <div id="nodes_container" class="grid"></div>
    </div>

    <!-- TAB AGENTI -->
    <div id="agents" class="tab-content">
        <h2>Gestione Agenti Autonomi & MCP</h2>
        <div class="card">
            <p>Stato Framework: <span class="badge badge-online">PRONTO</span></p>
            <p>Server MCP Collegati: <b>Aider Code Scanner, Python Inspector</b></p>
        </div>
    </div>

    <!-- TAB RAG -->
    <div id="rag" class="tab-content">
        <h2>Integrazione RAG & Database Vettoriali</h2>
        <div class="grid">
            <div class="card">
                <h3>SurrealDB</h3>
                <p>Stato: <span class="badge badge-online">ONLINE</span> (Porta 8000)</p>
            </div>
            <div class="card">
                <h3>Qdrant Vector DB</h3>
                <p>Stato: <span class="badge badge-online">ONLINE</span> (Porta 6333)</p>
            </div>
        </div>
    </div>

    <!-- TAB INCUS -->
    <div id="incus" class="tab-content">
        <h2>Orchestratore Incus Node</h2>
        <div class="card">
            <p>Ambiente Baremetal / Container Incus attivo.</p>
        </div>
    </div>

    <!-- TAB LOGS -->
    <div id="logs" class="tab-content">
        <h2>Log del Gateway in Tempo Reale</h2>
        <pre>/var/log/cluster-gateway.log caricato in ascolto continuo...</pre>
    </div>

    <script>
        function switchTab(tabId) {
            document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
            document.getElementById(tabId).classList.add('active');
            event.target.classList.add('active');
        }

        async function updateMetrics() {
            try {
                const res = await fetch('/api/metrics');
                const data = await res.json();
                
                document.getElementById('cpu_val').innerText = data.system.cpu_usage_pct;
                document.getElementById('ram_val').innerText = `${data.system.ram_used_gb} / ${data.system.ram_total_gb}`;
                document.getElementById('disk_val').innerText = `${data.system.disk_used_gb} / ${data.system.disk_total_gb}`;

                const container = document.getElementById('nodes_container');
                container.innerHTML = '';

                data.cluster_nodes.forEach(n => {
                    n.backends.forEach(b => {
                        const card = document.createElement('div');
                        card.className = 'card';
                        const statusClass = b.live_status === 'ONLINE' ? 'badge-online' : 'badge-offline';
                        
                        let modelsList = b.detected_models.map(m => `<li>${m}</li>`).join('');
                        
                        card.innerHTML = `
                            <h3>${n.node_id} (${n.host}:${b.port})</h3>
                            <p>Tipo: <b>${b.backend_type || 'llama'}</b></p>
                            <p>Stato: <span class="badge ${statusClass}">${b.live_status}</span> (${b.latency_ms || 'N/A'} ms)</p>
                            <p>Modelli Rilevati:</p>
                            <ul>${modelsList || '<li>Nessun modello</li>'}</ul>
                        `;
                        container.appendChild(card);
                    });
                });
            } catch (e) {
                console.error("Errore aggiornamento metriche", e);
            }
        }

        setInterval(updateMetrics, 3000);
        updateMetrics();
    </script>
</body>
</html>
    """

EOF

# --- 4. Configurazione Servizio Systemd ---
log_info "Configurazione ed installazione del servizio Systemd (${SERVICE_NAME})..."

cat <<EOF > /etc/systemd/system/${SERVICE_NAME}
[Unit]
Description=LLM Cluster Gateway & Dashboard
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

log_info "=== Installation completed successfully! ==="
log_info "Dashboard attiva e disponibile su: http://127.0.0.1:${PORT}"
log_info "Log di runtime in ascolto su: /var/log/cluster-gateway.log"
