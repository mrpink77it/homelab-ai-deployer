#!/usr/bin/env bash

# v3.1.0 - Gateway & Dashboard Cluster Modulare con Grafico a Linee (4 Variabili)

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
import subprocess
import requests
import psutil
from fastapi import FastAPI, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse

app = FastAPI(title="Open API Cluster Gateway & Telemetry")

TOPOLOGY_FILE = "/opt/gateway/cluster-topology.json"
STATIC_NODES_FILE = "/opt/gateway/cluster-static-nodes.json"
MODEL_DIR = "/opt/llama_models"

SYSTEM_LOGS = []
GLOBAL_REQUEST_LOGS = []

def log_event(msg, level="INFO"):
    timestamp = time.strftime("%H:%M:%S")
    SYSTEM_LOGS.append(f"[{timestamp}] [{level}] {msg}")
    if len(SYSTEM_LOGS) > 200:
        SYSTEM_LOGS.pop(0)

def scan_local_models():
    models = []
    if os.path.exists(MODEL_DIR):
        for f in os.listdir(MODEL_DIR):
            if f.endswith(".gguf"):
                path = os.path.join(MODEL_DIR, f)
                size_bytes = os.path.getsize(path)
                size_gb = round(size_bytes / (1024**3), 2)
                
                category = "Generale / Chat"
                if "coder" in f.lower():
                    category = "Sviluppo & Codice (Coding)"
                elif "medical" in f.lower() or "med" in f.lower():
                    category = "Medico & Specialistico"
                elif "embed" in f.lower():
                    category = "Embeddings / Vettori"
                elif size_gb < 3:
                    category = "Leggeri & Avvio Rapido (<3GB)"
                
                models.append({
                    "id": f,
                    "name": f,
                    "size_gb": size_gb,
                    "category": category
                })
    return models

def get_aggregated_nodes():
    nodes_dict = {}
    
    if os.path.exists(TOPOLOGY_FILE):
        try:
            with open(TOPOLOGY_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                for node in data.get("nodes", []):
                    nid = node.get("node_id")
                    nodes_dict[nid] = {
                        "node_id": nid,
                        "name": f"Nodo ({node.get('host')})",
                        "host": node.get("host"),
                        "backends": node.get("backends", [])
                    }
        except Exception:
            pass

    if os.path.exists(STATIC_NODES_FILE):
        try:
            with open(STATIC_NODES_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                for node in data.get("nodes", []):
                    nid = node.get("node_id")
                    if nid in nodes_dict:
                        existing_ports = [b["port"] for b in nodes_dict[nid]["backends"]]
                        for b in node.get("backends", []):
                            if b["port"] not in existing_ports:
                                nodes_dict[nid]["backends"].append(b)
                    else:
                        nodes_dict[nid] = {
                            "node_id": nid,
                            "name": f"Esterno ({node.get('host')})",
                            "host": node.get("host"),
                            "backends": node.get("backends", [])
                        }
        except Exception:
            pass

    if not nodes_dict:
        nodes_dict["local-default"] = {
            "node_id": "local-default",
            "name": "Server Locale",
            "host": "127.0.0.1",
            "backends": [{
                "port": 8080,
                "status": "OFFLINE",
                "models_loaded": ["Nessun modello"],
                "backend_type": "CPU / OpenBLAS",
                "hardware": {"cpu_util_pct": 0, "ram_used_gb": 0, "ram_total_gb": 0, "ram_util_pct": 0}
            }]
        }

    return list(nodes_dict.values())

@app.get("/api/telemetry")
def get_telemetry():
    mem = psutil.virtual_memory()
    cpu_percent = psutil.cpu_percent(interval=None)
    
    nvidia_info = {"temp": 0, "fan": 0, "vram_used": 0, "vram_total": 8192}
    try:
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

    nodes = get_aggregated_nodes()
    models = scan_local_models()

    return {
        "cpu_usage": cpu_percent,
        "ram_used_gb": round(mem.used / (1024**3), 2),
        "ram_total_gb": round(mem.total / (1024**3), 2),
        "nvidia": nvidia_info,
        "nodes": nodes,
        "available_models": models
    }

@app.post("/api/engine/control")
async def control_engine(req: Request):
    data = await req.json()
    action = data.get("action")
    port = data.get("port")
    
    service_map = {
        8080: "llama-cpp-vulkan.service",
        8200: "llama-cuda-0.service",
        8082: "llama-cpu.service"
    }
    
    service_name = service_map.get(int(port))
    if not service_name:
        return JSONResponse({"status": "error", "message": f"Servizio systemd non mappato per la porta {port}"}, status_code=400)
    
    try:
        if action == "restart":
            subprocess.run(["systemctl", "restart", service_name], check=True)
            log_event(f"Servizio {service_name} riavviato sulla porta {port}.")
        elif action == "stop":
            subprocess.run(["systemctl", "stop", service_name], check=True)
            log_event(f"Servizio {service_name} arrestato.")
        elif action == "start":
            subprocess.run(["systemctl", "start", service_name], check=True)
            log_event(f"Servizio {service_name} avviato.")
        elif action == "kill":
            PID = subprocess.getoutput(f"pgrep -f 'port {port}' | head -n 1")
            if PID:
                subprocess.run(["kill", "-9", PID])
                log_event(f"Processo PID {PID} terminato.", "WARN")
        return {"status": "ok", "message": f"Azione {action} eseguita con successo su {service_name}"}
    except Exception as e:
        return JSONResponse({"status": "error", "message": str(e)}, status_code=500)

@app.get("/api/logs")
def get_logs():
    return {"logs": SYSTEM_LOGS, "request_logs": GLOBAL_REQUEST_LOGS}

@app.post("/v1/chat/completions")
async def proxy_chat_completions(request: Request):
    body = await request.json()
    target_port = body.get("port", 8200)
    
    nodes = get_aggregated_nodes()
    target_host = "127.0.0.1"
    for n in nodes:
        for b in n.get("backends", []):
            if b.get("port") == int(target_port):
                target_host = n.get("host", "127.0.0.1")
                break
                
    start_time = time.time()
    try:
        resp = requests.post(
            f"http://{target_host}:{target_port}/v1/chat/completions",
            json=body,
            timeout=120
        )
        elapsed_ms = round((time.time() - start_time) * 1000, 2)
        
        messages = body.get("messages", [])
        prompt_snippet = messages[-1].get("content", "N/A")[:25] if messages else "N/A"
        req_type = "Chat / Completamento"
        
        routing_target = f"Motore LLM (Porta {target_port})"
        if "qdrant" in str(body).lower():
            routing_target = "Database Vettoriale Qdrant"
        elif "surreal" in str(body).lower():
            routing_target = "SurrealDB (Memoria)"

        log_entry = {
            "time": time.strftime("%H:%M:%S"),
            "node": f"{target_host}:{target_port}",
            "request": prompt_snippet + "...",
            "model": body.get("model", "unknown"),
            "type": req_type,
            "routing": routing_target,
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

echo "[*] Generazione del frontend con grafico a linee multi-variabile ($GATEWAY_DIR/index.html)..."
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
        .status-badge { background: rgba(34, 197, 94, 0.1); color: var(--accent-green); padding: 4px 12px; border-radius: 20px; font-weight: 600; font-size: 0.85rem; }

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
            margin-bottom: 30px;
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
        }
        @media(max-width: 900px) { .modular-container { grid-template-columns: 1fr; } }

        .node-details h2 { font-size: 1.3rem; margin-bottom: 10px; display: flex; justify-content: space-between; align-items: center; }
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

        .control-btns { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; margin-bottom: 15px; }
        .btn {
            background: var(--border-color);
            color: white;
            border: none;
            padding: 10px;
            border-radius: 6px;
            cursor: pointer;
            font-weight: 600;
            font-size: 0.9rem;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .btn:hover { opacity: 0.9; }
        .btn-start { background: #166534; color: #4ade80; }
        .btn-stop { background: #991b1b; color: #fca5a5; }
        .btn-restart { background: #1e40af; color: #93c5fd; }
        .btn-kill { background: #7f1d1d; color: #f87171; }

        .terminal-box {
            background: #090d16;
            border: 1px solid var(--border-color);
            border-radius: 6px;
            padding: 10px;
            font-family: monospace;
            font-size: 0.75rem;
            height: 90px;
            overflow-y: auto;
            color: #38bdf8;
        }

        .chart-side { display: flex; flex-direction: column; background: #0f172a; padding: 15px; border-radius: 8px; border: 1px solid var(--border-color); }
        .chart-side h3 { font-size: 0.95rem; margin-bottom: 10px; color: var(--text-muted); text-align: center; }
        .chart-container { flex-grow: 1; min-height: 200px; position: relative; }

        .global-logs { background: var(--card-bg); padding: 15px; border-radius: 8px; border: 1px solid var(--border-color); }
        .global-logs h3 { font-size: 1rem; margin-bottom: 10px; }
        .log-table { width: 100%; border-collapse: collapse; font-size: 0.8rem; }
        .log-table th, .log-table td { padding: 8px; text-align: left; border-bottom: 1px solid var(--border-color); }
        .log-table th { color: var(--text-muted); font-weight: 600; }
    </style>
</head>
<body>

    <header>
        <h1>Monitor Server Open API</h1>
        <div class="status-badge" id="cluster-status">SISTEMA ATTIVO</div>
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
            <span>GPU Temp / Ventola</span>
            <h2 id="gpu-temp-val">0°C / 0%</h2>
        </div>
    </div>

    <div class="cluster-nav" id="cluster-tabs"></div>

    <div class="modular-container" id="modular-view">
        <div style="text-align:center; color: var(--text-muted); grid-column: span 2;">Caricamento nodi cluster in corso...</div>
    </div>

    <div class="global-logs">
        <h3>Registro Richieste & Instradamento Cluster (Porta 9001)</h3>
        <table class="log-table">
            <thead>
                <tr>
                    <th>Ora</th>
                    <th>Nodo / Porta</th>
                    <th>Prompt / Richiesta</th>
                    <th>Modello Target</th>
                    <th>Tipologia</th>
                    <th>Instradamento Destinazione</th>
                    <th>Latenza</th>
                    <th>Stato</th>
                </tr>
            </thead>
            <tbody id="global-request-logs">
                <tr><td colspan="8" style="text-align: center; color: var(--text-muted);">In attesa di richieste API...</td></tr>
            </tbody>
        </table>
    </div>

    <script>
        let allBackends = [];
        let activeBackendKey = null;
        let engineChart = null;

        // Storico dati per il grafico live a 4 variabili
        const historyData = {
            labels: [],
            temp: [],
            fan: [],
            load: [],
            ram: []
        };

        async function fetchTelemetry() {
            try {
                const res = await fetch('/api/telemetry');
                const data = await res.json();

                document.getElementById('cpu-host-val').innerText = `${data.cpu_usage}%`;
                document.getElementById('ram-host-val').innerText = `${data.ram_used_gb} / ${data.ram_total_gb} GB`;
                document.getElementById('vram-val').innerText = `${data.nvidia.vram_used} / ${data.nvidia.vram_total} MB`;
                document.getElementById('gpu-temp-val').innerText = `${data.nvidia.temp}°C / ${data.nvidia.fan}%`;

                allBackends = [];
                data.nodes.forEach(node => {
                    node.backends.forEach(backend => {
                        allBackends.push({
                            node_id: node.node_id,
                            name: node.name,
                            host: node.host,
                            ...backend,
                            models_available: data.available_models
                        });
                    });
                });

                if (allBackends.length > 0 && !activeBackendKey) {
                    activeBackendKey = `${allBackends[0].host}:${allBackends[0].port}`;
                }

                // Aggiornamento storico grafico
                const now = new Date().toLocaleTimeString();
                if (historyData.labels.length > 15) {
                    historyData.labels.shift();
                    historyData.temp.shift();
                    historyData.fan.shift();
                    historyData.load.shift();
                    historyData.ram.shift();
                }

                const activeBackend = allBackends.find(b => `${b.host}:${b.port}` === activeBackendKey);
                const currentTemp = activeBackend?.hardware?.temp || data.nvidia.temp || 45;
                const currentFan = activeBackend?.hardware?.fan || data.nvidia.fan || 0;
                const currentLoad = activeBackend?.hardware?.cpu_util_pct || data.cpu_usage || 10;
                const currentRam = activeBackend?.hardware?.ram_used_gb || data.ram_used_gb || 4.0;

                historyData.labels.push(now);
                historyData.temp.push(currentTemp);
                historyData.fan.push(currentFan);
                historyData.load.push(currentLoad);
                historyData.ram.push(currentRam);

                renderClusterTabs();
                renderModularView();

            } catch (err) {
                console.error("Errore fetch telemetria:", err);
            }
        }

        function renderClusterTabs() {
            const tabsContainer = document.getElementById('cluster-tabs');
            tabsContainer.innerHTML = '';

            allBackends.forEach(b => {
                const key = `${b.host}:${b.port}`;
                const btn = document.createElement('button');
                btn.className = `tab-btn ${activeBackendKey === key ? 'active' : ''}`;
                btn.innerText = `${b.name} (${b.port})`;
                btn.onclick = () => {
                    activeBackendKey = key;
                    renderClusterTabs();
                    renderModularView();
                };
                tabsContainer.appendChild(btn);
            });
        }

        function renderModularView() {
            const container = document.getElementById('modular-view');
            const backend = allBackends.find(b => `${b.host}:${b.port}` === activeBackendKey);

            if (!backend) {
                container.innerHTML = `<div style="text-align:center; color: var(--text-muted); grid-column: span 2;">Nessun motore selezionato.</div>`;
                return;
            }

            const isOnline = backend.status === "ONLINE";
            const hw = backend.hardware || { cpu_util_pct: 0, ram_used_gb: 0, ram_total_gb: 0 };
            const loadedModel = (backend.models_loaded || ['N/D'])[0];

            const categories = {};
            (backend.models_available || []).forEach(m => {
                if (!categories[m.category]) categories[m.category] = [];
                categories[m.category].push(m);
            });

            let optionsHTML = '';
            for (const [cat, mods] of Object.entries(categories)) {
                optionsHTML += `<optgroup label="${cat}">`;
                mods.forEach(m => {
                    const selected = m.name === loadedModel ? 'selected' : '';
                    optionsHTML += `<option value="${m.name}" ${selected}>${m.name} (${m.size_gb} GB)</option>`;
                });
                optionsHTML += `</optgroup>`;
            }

            container.innerHTML = `
                <div class="node-details">
                    <h2>
                        <span>${backend.name}</span>
                        <span class="node-badge ${isOnline ? 'online' : 'offline'}">${backend.status}</span>
                    </h2>
                    <div class="node-info-grid">
                        <div><span>Host / Porta:</span> <strong>${backend.host}:${backend.port}</strong></div>
                        <div><span>Backend Hardware:</span> <strong style="color:var(--accent-blue)">${backend.backend_type || 'CPU / OpenBLAS'}</strong></div>
                        <div><span>CPU / RAM Nodo:</span> <strong>${hw.cpu_util_pct || 0}% / ${hw.ram_used_gb || 0} GB</strong></div>
                        <div><span>Modello In Uso:</span> <strong style="color:var(--accent-green)">${loadedModel}</strong></div>
                    </div>
                    <select class="model-select" id="select-${backend.port}">
                        ${optionsHTML}
                    </select>
                    <div class="control-btns">
                        <button class="btn btn-start" onclick="controlEngine(${backend.port}, 'start')" title="Avvia">▶</button>
                        <button class="btn btn-stop" onclick="controlEngine(${backend.port}, 'stop')" title="Arresta">⏹</button>
                        <button class="btn btn-restart" onclick="controlEngine(${backend.port}, 'restart')" title="Riavvia">🔄</button>
                        <button class="btn btn-kill" onclick="controlEngine(${backend.port}, 'kill')" title="Termina (Kill)">✕</button>
                    </div>
                    <div class="terminal-box" id="term-${backend.port}">
                        [LOG ${backend.node_id}] Porta ${backend.port} attiva - Backend ${backend.backend_type}.
                    </div>
                </div>
                <div class="chart-side">
                    <h3>Telemetria Live (RAM, Load, Fan, Temp)</h3>
                    <div class="chart-container">
                        <canvas id="engineLineChart"></canvas>
                    </div>
                </div>
            `;

            renderEngineLineChart();
        }

        function renderEngineLineChart() {
            const ctx = document.getElementById('engineLineChart').getContext('2d');
            if (engineChart) engineChart.destroy();

            engineChart = new Chart(ctx, {
                type: 'line',
                data: {
                    labels: historyData.labels,
                    datasets: [
                        { label: 'Temperatura (°C)', data: historyData.temp, borderColor: '#ef4444', backgroundColor: '#ef4444', tension: 0.3, yAxisID: 'y' },
                        { label: 'Ventola (%)', data: historyData.fan, borderColor: '#38bdf8', backgroundColor: '#38bdf8', tension: 0.3, yAxisID: 'y' },
                        { label: 'Carico (%)', data: historyData.load, borderColor: '#22c55e', backgroundColor: '#22c55e', tension: 0.3, yAxisID: 'y' },
                        { label: 'RAM Usata (GB)', data: historyData.ram, borderColor: '#f59e0b', backgroundColor: '#f59e0b', tension: 0.3, yAxisID: 'y1' }
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

        async function controlEngine(port, action) {
            const select = document.getElementById(`select-${port}`);
            const selectedModel = select ? select.value : '';
            
            try {
                const res = await fetch('/api/engine/control', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ port: port, action: action, model: selectedModel })
                });
                const result = await res.json();
                alert(result.message);
                fetchTelemetry();
            } catch (e) {
                alert("Errore invio comando: " + e);
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
                            <td>${log.type}</td>
                            <td style="color:var(--accent-blue)">${log.routing}</td>
                            <td>${log.latency_ms} ms</td>
                            <td style="color: ${log.status === 200 ? 'var(--accent-green)' : 'var(--accent-red)'}">${log.status}</td>
                        `;
                        tableBody.appendChild(tr);
                    });
                }
            } catch (e) {
                console.error("Errore recupero log:", e);
            }
        }

        setInterval(fetchTelemetry, 1000);
        setInterval(fetchLogs, 1000);
        fetchTelemetry();
        fetchLogs();
    </script>
</body>
</html>
EOF_HTML

echo "[*] Generazione del file systemd in $SERVICE_FILE..."
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
