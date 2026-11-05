#!/usr/bin/env bash

# v4.1.0 - Gateway & Dashboard Cluster Corretta (Zero-Refresh, Synoptic Linear Sync, Status Colors)

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

GATEWAY_DIR="/opt/gateway"
MODEL_DIR="/opt/llama_models"
SERVICE_FILE="/etc/systemd/system/llm-gateway.service"
PORT=9001

echo "[*] Installazione dipendenze Python per il Gateway..."
apt-get update
apt-get install -y python3 python3-pip python3-venv lm-sensors

echo "[*] Creazione ambiente di lavoro in $GATEWAY_DIR..."
mkdir -p "$GATEWAY_DIR"
cd "$GATEWAY_DIR"

if [ ! -d "venv" ]; then
    python3 -m venv venv
fi

./venv/bin/pip install --upgrade pip
./venv/bin/pip install fastapi uvicorn requests psutil pynvml

echo "[*] Generazione del backend FastAPI ($GATEWAY_DIR/main.py)..."
cat << 'EOF_PYTHON' > "$GATEWAY_DIR/main.py"
import json
import os
import time
import requests
import psutil
from fastapi import FastAPI, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse

app = FastAPI(title="Open API Cluster Gateway & Synoptic Telemetry")

TOPOLOGY_FILE = "/opt/gateway/cluster-topology.json"
STATIC_NODES_FILE = "/opt/gateway/cluster-static-nodes.json"
MODEL_DIR = "/opt/llama_models"

SYSTEM_LOGS = []
GLOBAL_REQUEST_LOGS = []

def log_debug(msg, origin="GATEWAY", level="DEBUG"):
    timestamp = time.strftime("%H:%M:%S")
    entry = f"[{timestamp}] [{origin}] [{level}] {msg}"
    SYSTEM_LOGS.append(entry)
    if len(SYSTEM_LOGS) > 300:
        SYSTEM_LOGS.pop(0)

def scan_local_models():
    models = []
    if os.path.exists(MODEL_DIR):
        for f in os.listdir(MODEL_DIR):
            if f.endswith(".gguf"):
                path = os.path.join(MODEL_DIR, f)
                size_gb = round(os.path.getsize(path) / (1024**3), 2)
                
                cat = "Generale / Chat"
                if "coder" in f.lower():
                    cat = "Sviluppo & Codice (Coding)"
                elif "med" in f.lower():
                    cat = "Medico & Specialistico"
                elif "embed" in f.lower():
                    cat = "Embeddings / Vettori"
                elif size_gb < 3:
                    cat = "Leggeri & Avvio Rapido (<3GB)"
                
                models.append({
                    "id": f,
                    "filename": f,
                    "size_gb": size_gb,
                    "category": cat
                })
    return models

def get_aggregated_topology():
    topology_data = {"nodes": []}
    static_data = {"nodes": []}
    
    if os.path.exists(TOPOLOGY_FILE):
        try:
            with open(TOPOLOGY_FILE, "r", encoding="utf-8") as f:
                topology_data = json.load(f)
        except Exception:
            pass

    if os.path.exists(STATIC_NODES_FILE):
        try:
            with open(STATIC_NODES_FILE, "r", encoding="utf-8") as f:
                static_data = json.load(f)
        except Exception:
            pass

    nodes_map = {}
    for n in topology_data.get("nodes", []):
        nid = n.get("node_id")
        nodes_map[nid] = n

    for n in static_data.get("nodes", []):
        nid = n.get("node_id")
        if nid in nodes_map:
            existing_ports = [b["port"] for b in nodes_map[nid].get("backends", [])]
            for b in n.get("backends", []):
                if b["port"] not in existing_ports:
                    nodes_map[nid]["backends"].append(b)
        else:
            nodes_map[nid] = n

    return {
        "merged_nodes": list(nodes_map.values()),
        "raw_topology": topology_data,
        "raw_static": static_data
    }

@app.get("/api/telemetry")
def get_telemetry():
    mem = psutil.virtual_memory()
    cpu_percent = psutil.cpu_percent(interval=None)
    
    nvidia_info = {"temp": 0, "fan": 0, "vram_used": 0, "vram_total": 8192}
    try:
        import subprocess
        res = subprocess.run(
            ["nvidia-smi", "--query-gpu=temperature.gpu,fan.speed,memory.used,memory.total", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=1
        )
        if res.returncode == 0:
            parts = res.stdout.strip().split(',')
            if len(parts) == 4:
                nvidia_info["temp"] = int(parts[0].strip())
                nvidia_info["fan"] = int(parts[1].strip())
                nvidia_info["vram_used"] = int(parts[2].strip())
                nvidia_info["vram_total"] = int(parts[3].strip())
    except Exception:
        pass

    topo = get_aggregated_topology()

    return {
        "cpu_usage": cpu_percent,
        "ram_used_gb": round(mem.used / (1024**3), 2),
        "ram_total_gb": round(mem.total / (1024**3), 2),
        "nvidia": nvidia_info,
        "nodes": topo["merged_nodes"],
        "raw_topology": topo["raw_topology"],
        "raw_static": topo["raw_static"],
        "available_models": scan_local_models()
    }

@app.post("/api/engine/native-control")
async def native_control(req: Request):
    data = await req.json()
    host = data.get("host", "127.0.0.1")
    port = data.get("port")
    action = data.get("action")
    model = data.get("model")

    endpoint_base = f"http://{host}:{port}"

    try:
        if action == "load":
            payload = {"model": model}
            log_debug(f"Invio LOAD a {endpoint_base}/v1/models/load -> {model}", origin="ENGINE_API")
            r = requests.post(f"{endpoint_base}/v1/models/load", json=payload, timeout=30)
            return {"status": "ok", "message": f"Modello {model} caricato in memoria."}

        elif action == "unload":
            log_debug(f"Invio UNLOAD a {endpoint_base}/v1/models/unload", origin="ENGINE_API")
            r = requests.post(f"{endpoint_base}/v1/models/unload", json={}, timeout=10)
            return {"status": "ok", "message": "Modello scaricato dalla RAM con successo."}

        elif action == "slot_clear":
            log_debug(f"Reset slot su {endpoint_base}/slots/0?action=release", origin="ENGINE_API")
            r = requests.get(f"{endpoint_base}/slots/0?action=release", timeout=5)
            return {"status": "ok", "message": "Contesto e slot azzerati."}

        return JSONResponse({"error": "Azione non supportata"}, status_code=400)
    except Exception as e:
        log_debug(f"Errore OpenAPI {endpoint_base}: {str(e)}", origin="ENGINE_API", level="ERROR")
        return JSONResponse({"status": "error", "message": f"Errore connessione motore: {str(e)}"}, status_code=502)

@app.get("/api/logs")
def get_logs():
    return {"debug_logs": SYSTEM_LOGS, "request_logs": GLOBAL_REQUEST_LOGS}

@app.post("/v1/chat/completions")
async def proxy_chat_completions(request: Request):
    body = await request.json()
    target_port = body.get("port", 8200)
    
    topo = get_aggregated_topology()
    target_host = "127.0.0.1"
    for n in topo["merged_nodes"]:
        for b in n.get("backends", []):
            if b.get("port") == int(target_port):
                target_host = n.get("host", "127.0.0.1")
                break
                
    start_time = time.time()
    try:
        resp = requests.post(f"http://{target_host}:{target_port}/v1/chat/completions", json=body, timeout=120)
        elapsed_ms = round((time.time() - start_time) * 1000, 2)
        
        messages = body.get("messages", [])
        prompt_snippet = messages[-1].get("content", "N/A")[:30] if messages else "N/A"
        
        log_entry = {
            "time": time.strftime("%H:%M:%S"),
            "node": f"{target_host}:{target_port}",
            "request": prompt_snippet + "...",
            "model": body.get("model", "auto"),
            "type": "Chat/Completion",
            "routing": f"Llama Engine ({target_host}:{target_port})",
            "latency_ms": elapsed_ms,
            "status": resp.status_code
        }
        GLOBAL_REQUEST_LOGS.append(log_entry)
        if len(GLOBAL_REQUEST_LOGS) > 100:
            GLOBAL_REQUEST_LOGS.pop(0)

        return Response(content=resp.content, status_code=resp.status_code, media_type="application/json")
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=502)

@app.get("/", response_class=HTMLResponse)
def read_root():
    with open("index.html", "r", encoding="utf-8") as f:
        return f.read()
EOF_PYTHON

echo "[*] Generazione del frontend con sinottico pulito e indicatori di stato dedicati ($GATEWAY_DIR/index.html)..."
cat << 'EOF_HTML' > "$GATEWAY_DIR/index.html"
<!DOCTYPE html>
<html lang="it">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Monitor Server Open API - Cluster Gateway</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        :root {
            --bg-dark: #0f172a;
            --card-bg: #1e293b;
            --border-color: #334155;
            --accent-blue: #38bdf8;
            --accent-green: #22c55e;
            --accent-red: #ef4444;
            --accent-yellow: #f59e0b;
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
        }

        * { box-sizing: border-box; margin: 0; padding: 0; font-family: system-ui, -apple-system, sans-serif; }
        body { background: var(--bg-dark); color: var(--text-main); padding: 20px; line-height: 1.5; }

        header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; padding-bottom: 10px; border-bottom: 1px solid var(--border-color); }
        h1 { font-size: 1.5rem; font-weight: 700; }
        .status-badge { padding: 4px 12px; border-radius: 20px; font-weight: 600; font-size: 0.85rem; display: inline-flex; align-items: center; gap: 6px; }
        .status-online { background: rgba(34, 197, 94, 0.15); color: var(--accent-green); border: 1px solid rgba(34, 197, 94, 0.3); }
        .status-offline { background: rgba(239, 68, 68, 0.15); color: var(--accent-red); border: 1px solid rgba(239, 68, 68, 0.3); }
        .status-loading { background: rgba(245, 158, 11, 0.15); color: var(--accent-yellow); border: 1px solid rgba(245, 158, 11, 0.3); }

        .metrics-bar { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin-bottom: 25px; }
        .metric-card { background: var(--card-bg); padding: 15px; border-radius: 8px; border: 1px solid var(--border-color); }
        .metric-card span { display: block; color: var(--text-muted); font-size: 0.8rem; text-transform: uppercase; }
        .metric-card h2 { font-size: 1.4rem; color: var(--accent-blue); margin-top: 5px; }

        .cluster-nav { display: flex; gap: 10px; margin-bottom: 15px; overflow-x: auto; padding-bottom: 5px; }
        .tab-btn {
            background: var(--card-bg);
            color: var(--text-muted);
            border: 1px solid var(--border-color);
            padding: 10px 20px;
            border-radius: 8px;
            cursor: pointer;
            font-weight: 600;
            font-size: 0.9rem;
            white-space: nowrap;
        }
        .tab-btn.active { background: var(--accent-blue); color: var(--bg-dark); border-color: var(--accent-blue); }

        .modular-container {
            background: var(--card-bg);
            border: 1px solid var(--border-color);
            border-radius: 10px;
            padding: 20px;
            margin-bottom: 25px;
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
        }
        @media(max-width: 900px) { .modular-container { grid-template-columns: 1fr; } }

        .node-details h2 { font-size: 1.3rem; margin-bottom: 15px; display: flex; justify-content: space-between; align-items: center; }
        .node-info-grid { font-size: 0.88rem; color: var(--text-muted); margin-bottom: 15px; }
        .node-info-grid div { display: flex; justify-content: space-between; margin-bottom: 6px; }

        select.model-select {
            width: 100%;
            background: #0f172a;
            color: var(--text-main);
            border: 1px solid var(--border-color);
            padding: 10px;
            border-radius: 6px;
            font-size: 0.9rem;
            margin-bottom: 15px;
        }

        .control-btns { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin-bottom: 15px; }
        .btn {
            background: var(--border-color);
            color: white;
            border: none;
            padding: 10px;
            border-radius: 6px;
            cursor: pointer;
            font-weight: 600;
            font-size: 0.85rem;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 5px;
        }
        .btn:hover { opacity: 0.9; }
        .btn-load { background: #166534; color: #4ade80; }
        .btn-unload { background: #991b1b; color: #fca5a5; }
        .btn-clear { background: #1e40af; color: #93c5fd; }

        .chart-side { display: flex; flex-direction: column; background: #0f172a; padding: 15px; border-radius: 8px; border: 1px solid var(--border-color); }
        .chart-side h3 { font-size: 0.95rem; margin-bottom: 10px; color: var(--text-muted); text-align: center; }
        .chart-container { flex-grow: 1; min-height: 220px; position: relative; }

        .config-section { margin-bottom: 25px; background: var(--card-bg); padding: 15px; border-radius: 8px; border: 1px solid var(--border-color); }
        .config-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 15px; margin-top: 10px; }
        @media(max-width: 800px) { .config-grid { grid-template-columns: 1fr; } }
        .config-box { background: #090d16; border: 1px solid var(--border-color); padding: 10px; border-radius: 6px; font-family: monospace; font-size: 0.75rem; height: 160px; overflow-y: auto; color: #a7f3d0; }

        .debug-console { background: #030712; border: 1px solid var(--border-color); padding: 15px; border-radius: 8px; margin-bottom: 25px; }
        .debug-console h3 { font-size: 0.95rem; margin-bottom: 10px; color: var(--accent-yellow); }
        .debug-box { font-family: monospace; font-size: 0.78rem; height: 140px; overflow-y: auto; color: #38bdf8; display: flex; flex-direction: column-reverse; }

        .global-logs { background: var(--card-bg); padding: 15px; border-radius: 8px; border: 1px solid var(--border-color); margin-bottom: 25px; }
        .log-table { width: 100%; border-collapse: collapse; font-size: 0.8rem; }
        .log-table th, .log-table td { padding: 8px; text-align: left; border-bottom: 1px solid var(--border-color); }
        .log-table th { color: var(--text-muted); font-weight: 600; }
    </style>
</head>
<body>

    <header>
        <h1>Monitor Server Open API</h1>
        <div class="status-badge status-online">CLUSTER GATEWAY ATTIVO</div>
    </header>

    <div class="metrics-bar">
        <div class="metric-card">
            <span>Carico CPU Host</span>
            <h2 id="cpu-host-val">0.0%</h2>
        </div>
        <div class="metric-card">
            <span>RAM di Sistema</span>
            <h2 id="ram-host-val">0.0 / 0.0 GB</h2>
        </div>
        <div class="metric-card">
            <span>NVIDIA VRAM (RTX 3060 Ti)</span>
            <h2 id="vram-val">0 / 8192 MB</h2>
        </div>
        <div class="metric-card">
            <span>GPU Temp</span>
            <h2 id="gpu-temp-val">0°C</h2>
        </div>
    </div>

    <!-- Tab dei Nodi / Motori -->
    <div class="cluster-nav" id="cluster-tabs"></div>

    <!-- Scheda Modulare del Motore Selezionato -->
    <div class="modular-container">
        <div class="node-details">
            <h2>
                <span id="mod-engine-name">Seleziona Motore</span>
                <span id="mod-engine-status" class="status-badge status-offline">OFFLINE</span>
            </h2>
            <div class="node-info-grid">
                <div><span>Host / Porta:</span> <strong id="mod-engine-endpoint">-</strong></div>
                <div><span>Backend Hardware:</span> <strong id="mod-engine-backend" style="color:var(--accent-blue)">-</strong></div>
                <div><span>CPU / RAM Nodo:</span> <strong id="mod-engine-cpuram">-</strong></div>
                <div><span>Modello in Memoria:</span> <strong id="mod-engine-loaded" style="color:var(--accent-green)">-</strong></div>
            </div>

            <select class="model-select" id="mod-model-select">
                <option value="">Caricamento modelli...</option>
            </select>

            <div class="control-btns">
                <button class="btn btn-load" onclick="executeNativeAction('load')">▶ Carica Modello</button>
                <button class="btn btn-unload" onclick="executeNativeAction('unload')">⏹ Scarica RAM</button>
                <button class="btn btn-clear" onclick="executeNativeAction('slot_clear')">🔄 Reset Contesto</button>
            </div>
        </div>

        <div class="chart-side">
            <h3>Telemetria Live (Load % & RAM GB)</h3>
            <div class="chart-container">
                <canvas id="engineLineChart"></canvas>
            </div>
        </div>
    </div>

    <!-- File di Configurazione -->
    <div class="config-section">
        <h3>File di Configurazione Cluster & Nodi Statici</h3>
        <div class="config-grid">
            <div>
                <span style="font-size:0.8rem; color:var(--text-muted)">cluster-topology.json (Auto-Discovery)</span>
                <div class="config-box" id="cfg-topology-box">Caricamento...</div>
            </div>
            <div>
                <span style="font-size:0.8rem; color:var(--text-muted)">cluster-static-nodes.json (Nodi Manuali/Esterni)</span>
                <div class="config-box" id="cfg-static-box">Caricamento...</div>
            </div>
        </div>
    </div>

    <!-- Registro Richieste -->
    <div class="global-logs">
        <h3>Registro Richieste Gateway Open API (Porta 9001)</h3>
        <table class="log-table">
            <thead>
                <tr>
                    <th>Ora</th>
                    <th>Nodo / Porta</th>
                    <th>Prompt / Richiesta</th>
                    <th>Modello Target</th>
                    <th>Instradamento Destinazione</th>
                    <th>Latenza</th>
                    <th>Stato</th>
                </tr>
            </thead>
            <tbody id="global-request-logs">
                <tr><td colspan="7" style="text-align: center; color: var(--text-muted);">In attesa di richieste API...</td></tr>
            </tbody>
        </table>
    </div>

    <!-- Console Debug -->
    <div class="debug-console">
        <h3>Debug Operativo & Flow LLM</h3>
        <div class="debug-box" id="debug-log-box"></div>
    </div>

    <script>
        let allBackends = [];
        let activeBackendKey = null;
        let engineChart = null;

        const historyData = {
            labels: [], load: [], ram: []
        };

        function initChart() {
            const ctx = document.getElementById('engineLineChart').getContext('2d');
            engineChart = new Chart(ctx, {
                type: 'line',
                data: {
                    labels: historyData.labels,
                    datasets: [
                        { label: 'Load Nodo (%)', data: historyData.load, borderColor: '#22c55e', backgroundColor: '#22c55e', tension: 0.3, yAxisID: 'y' },
                        { label: 'RAM Nodo (GB)', data: historyData.ram, borderColor: '#f59e0b', backgroundColor: '#f59e0b', tension: 0.3, yAxisID: 'y1' }
                    ]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {
                        y: { type: 'linear', display: true, position: 'left', min: 0, max: 100, grid: { color: '#334155' } },
                        y1: { type: 'linear', display: true, position: 'right', min: 0, max: 64, grid: { drawOnChartArea: false } },
                        x: { grid: { display: false } }
                    }
                }
            });
        }

        async function fetchTelemetry() {
            try {
                const res = await fetch('/api/telemetry');
                const data = await res.json();

                document.getElementById('cpu-host-val').innerText = `${data.cpu_usage}%`;
                document.getElementById('ram-host-val').innerText = `${data.ram_used_gb} / ${data.ram_total_gb} GB`;
                document.getElementById('vram-val').innerText = `${data.nvidia.vram_used} / ${data.nvidia.vram_total} MB`;
                document.getElementById('gpu-temp-val').innerText = `${data.nvidia.temp}°C`;

                document.getElementById('cfg-topology-box').innerText = JSON.stringify(data.raw_topology, null, 2);
                document.getElementById('cfg-static-box').innerText = JSON.stringify(data.raw_static, null, 2);

                allBackends = [];
                (data.nodes || []).forEach(node => {
                    (node.backends || []).forEach(b => {
                        allBackends.push({
                            node_id: node.node_id,
                            node_name: node.node_id || 'Nodo',
                            host: node.host,
                            ...b,
                            available_models: data.available_models
                        });
                    });
                });

                if (allBackends.length > 0 && !activeBackendKey) {
                    activeBackendKey = `${allBackends[0].host}:${allBackends[0].port}`;
                    populateModelDropdown(allBackends[0]);
                }

                updateTabsUI();
                updateActiveEngineUI(data);

            } catch (err) {
                console.error("Errore fetch telemetria:", err);
            }
        }

        function updateTabsUI() {
            const tabsContainer = document.getElementById('cluster-tabs');
            
            if (tabsContainer.children.length !== allBackends.length) {
                tabsContainer.innerHTML = '';
                allBackends.forEach(b => {
                    const key = `${b.host}:${b.port}`;
                    const btn = document.createElement('button');
                    btn.className = `tab-btn ${activeBackendKey === key ? 'active' : ''}`;
                    btn.id = `tab-${b.host}-${b.port}`;
                    btn.innerText = `${b.host}:${b.port} (${b.backend_type || 'Motore'})`;
                    btn.onclick = () => {
                        activeBackendKey = key;
                        updateTabsUI();
                        const targetBackend = allBackends.find(item => `${item.host}:${item.port}` === activeBackendKey);
                        if (targetBackend) populateModelDropdown(targetBackend);
                    };
                    tabsContainer.appendChild(btn);
                });
            } else {
                allBackends.forEach(b => {
                    const key = `${b.host}:${b.port}`;
                    const btn = document.getElementById(`tab-${b.host}-${b.port}`);
                    if (btn) {
                        btn.className = `tab-btn ${activeBackendKey === key ? 'active' : ''}`;
                    }
                });
            }
        }

        function populateModelDropdown(backend) {
            const select = document.getElementById('mod-model-select');
            // Memorizziamo la selezione corrente se esiste
            const currentSelected = select.value;
            select.innerHTML = '';

            const categories = {};
            (backend.available_models || []).forEach(m => {
                if (!categories[m.category]) categories[m.category] = [];
                categories[m.category].push(m);
            });

            for (const [cat, mods] of Object.entries(categories)) {
                const optgroup = document.createElement('optgroup');
                optgroup.label = cat;
                mods.forEach(m => {
                    const option = document.createElement('option');
                    option.value = m.filename;
                    option.innerText = `${m.filename} (${m.size_gb} GB)`;
                    if (m.filename === currentSelected) option.selected = true;
                    optgroup.appendChild(option);
                });
                select.appendChild(optgroup);
            }
        }

        function updateActiveEngineUI(telemetryData) {
            const backend = allBackends.find(b => `${b.host}:${b.port}` === activeBackendKey);
            if (!backend) return;

            document.getElementById('mod-engine-name').innerText = `Motore (${backend.host}:${backend.port})`;
            document.getElementById('mod-engine-endpoint').innerText = `${backend.host}:${backend.port}`;
            document.getElementById('mod-engine-backend').innerText = backend.backend_type || 'CPU / OpenBLAS';
            
            const hw = backend.hardware || {};
            document.getElementById('mod-engine-cpuram').innerText = `${hw.cpu_util_pct || 0}% / ${hw.ram_used_gb || 0} GB`;
            
            const loadedModels = backend.models_loaded || ['Nessuno'];
            document.getElementById('mod-engine-loaded').innerText = Array.isArray(loadedModels) ? loadedModels.join(', ') : loadedModels;

            // Gestione indicatori di stato (Verde = Online, Rosso = Offline, Giallo = In avvio/Caricamento)
            const statusEl = document.getElementById('mod-engine-status');
            if (backend.status === "ONLINE") {
                statusEl.className = "status-badge status-online";
                statusEl.innerText = "ONLINE";
            } else if (backend.status === "STARTING" || backend.status === "LOADING") {
                statusEl.className = "status-badge status-loading";
                statusEl.innerText = "IN AVVIO";
            } else {
                statusEl.className = "status-badge status-offline";
                statusEl.innerText = "OFFLINE";
            }

            // Update Chart Data in continuo
            const now = new Date().toLocaleTimeString();
            if (historyData.labels.length > 15) {
                historyData.labels.shift();
                historyData.load.shift();
                historyData.ram.shift();
            }

            historyData.labels.push(now);
            historyData.load.push(hw.cpu_util_pct || telemetryData.cpu_usage || 10);
            historyData.ram.push(hw.ram_used_gb || telemetryData.ram_used_gb || 4);

            if (engineChart) engineChart.update();
        }

        async function executeNativeAction(action) {
            const backend = allBackends.find(b => `${b.host}:${b.port}` === activeBackendKey);
            if (!backend) return;

            const select = document.getElementById('mod-model-select');
            const selectedModel = select ? select.value : '';

            try {
                const res = await fetch('/api/engine/native-control', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        host: backend.host,
                        port: backend.port,
                        action: action,
                        model: selectedModel
                    })
                });
                const data = await res.json();
                alert(data.message || "Comando eseguito via Open-API!");
                fetchTelemetry();
            } catch (e) {
                alert("Errore chiamata Open-API: " + e);
            }
        }

        async function fetchLogs() {
            try {
                const res = await fetch('/api/logs');
                const data = await res.json();

                const tableBody = document.getElementById('global-request-logs');
                if (data.request_logs.length > 0) {
                    tableBody.innerHTML = '';
                    data.request_logs.slice().reverse().forEach(log => {
                        const tr = document.createElement('tr');
                        tr.innerHTML = `
                            <td>${log.time}</td>
                            <td>${log.node}</td>
                            <td>${log.request}</td>
                            <td>${log.model}</td>
                            <td style="color:var(--accent-blue)">${log.routing}</td>
                            <td>${log.latency_ms} ms</td>
                            <td style="color: ${log.status === 200 ? 'var(--accent-green)' : 'var(--accent-red)'}">${log.status}</td>
                        `;
                        tableBody.appendChild(tr);
                    });
                }

                const debugBox = document.getElementById('debug-log-box');
                debugBox.innerHTML = data.debug_logs.slice().reverse().map(l => `<div>${l}</div>`).join('');

            } catch (e) {
                console.error("Errore recupero log:", e);
            }
        }

        window.onload = () => {
            initChart();
            fetchTelemetry();
            fetchLogs();
            setInterval(fetchTelemetry, 1000);
            setInterval(fetchLogs, 1000);
        };
    </script>
</body>
</html>
EOF_HTML

echo "[*] Generazione del file systemd ($SERVICE_FILE)..."
cat << EOF_SERVICE > "$SERVICE_FILE"
[Unit]
Description=Llama Open API Cluster Gateway & Dashboard (Port $PORT)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$GATEWAY_DIR
ExecStart=$GATEWAY_DIR/venv/bin/uvicorn main:app --host 0.0.0.0 --port $PORT
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE

echo "[*] Ricarico systemd, abilito e avvio il Gateway sulla porta $PORT..."
systemctl daemon-reload
systemctl enable llm-gateway.service
systemctl restart llm-gateway.service

echo "================================================================="
echo "[OK] Setup Cluster Gateway completato con successo!"
echo " Interfaccia Dashboard Web disponibile su: http://127.0.0.1:$PORT"
echo "================================================================="
