#!/usr/bin/env bash

# v2.5.0 - Setup Completo Gateway & Dashboard Cluster Open API (Porta 9001)

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

GATEWAY_DIR="/opt/gateway"
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
SYSTEM_LOGS = []
GLOBAL_REQUEST_LOGS = []

def log_event(msg, level="INFO"):
    timestamp = time.strftime("%H:%M:%S")
    SYSTEM_LOGS.append(f"[{timestamp}] [{level}] {msg}")
    if len(SYSTEM_LOGS) > 200:
        SYSTEM_LOGS.pop(0)

def get_aggregated_nodes():
    nodes_dict = {}
    
    # 1. Caricamento nodi auto-scoperti dal demone di discovery
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
        except Exception as e:
            log_event(f"Errore lettura cluster-topology.json: {str(e)}", "ERROR")

    # 2. Caricamento nodi statici/esterni (gestiti da add_node.sh)
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
        except Exception as e:
            log_event(f"Errore lettura cluster-static-nodes.json: {str(e)}", "ERROR")

    if not nodes_dict:
        return [{
            "node_id": "node-127-0-0-1",
            "name": "Server Locale",
            "host": "127.0.0.1",
            "backends": [{
                "port": 8080,
                "status": "OFFLINE",
                "models_loaded": ["Nessun modello"],
                "backend_type": "CPU / OpenBLAS",
                "hardware": {"cpu_util_pct": 0, "ram_used_gb": 0, "ram_total_gb": 0, "ram_util_pct": 0}
            }]
        }]

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
    return {
        "cpu_usage": cpu_percent,
        "ram_used_gb": round(mem.used / (1024**3), 2),
        "ram_total_gb": round(mem.total / (1024**3), 2),
        "nvidia": nvidia_info,
        "nodes": nodes
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
                log_event(f"Processo PID {PID} forzatamente terminato (Kill -9).", "WARN")
        return {"status": "ok", "message": f"Azione {action} eseguita con successo su {service_name}"}
    except Exception as e:
        log_event(f"Errore controllo servizio {service_name}: {str(e)}", "ERROR")
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
        
        log_entry = {
            "time": time.strftime("%H:%M:%S"),
            "port": target_port,
            "status": resp.status_code,
            "latency_ms": elapsed_ms,
            "model": body.get("model", "unknown")
        }
        GLOBAL_REQUEST_LOGS.append(log_entry)
        if len(GLOBAL_REQUEST_LOGS) > 100:
            GLOBAL_REQUEST_LOGS.pop(0)

        return Response(content=resp.content, status_code=resp.status_code, media_type="application/json")
    except Exception as e:
        log_event(f"Errore Proxy Gateway su porta {target_port}: {str(e)}", "ERROR")
        return JSONResponse({"error": str(e)}, status_code=502)

@app.get("/", response_class=HTMLResponse)
def read_root():
    with open("index.html", "r", encoding="utf-8") as f:
        return f.read()
EOF_PYTHON

echo "[*] Generazione del frontend Dashboard ($GATEWAY_DIR/index.html)..."
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

        .carousel-section { margin-bottom: 30px; }
        .carousel-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
        .carousel-container { display: flex; gap: 15px; overflow-x: auto; scroll-behavior: smooth; padding-bottom: 10px; }
        .carousel-container::-webkit-scrollbar { height: 8px; }
        .carousel-container::-webkit-scrollbar-thumb { background: var(--border-color); border-radius: 4px; }

        .node-card {
            flex: 0 0 100%;
            background: var(--card-bg);
            border: 1px solid var(--border-color);
            border-radius: 10px;
            padding: 18px;
            min-width: 300px;
        }
        @media (min-width: 768px) { .node-card { flex: 0 0 calc(33.333% - 10px); } }
        @media (min-width: 1440px) { .node-card { flex: 0 0 calc(20% - 12px); } }

        .node-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
        .node-title { font-weight: 600; font-size: 1.05rem; }
        .node-badge { font-size: 0.75rem; padding: 2px 8px; border-radius: 4px; background: #334155; }
        .node-badge.online { background: rgba(34, 197, 94, 0.2); color: var(--accent-green); }
        .node-badge.offline { background: rgba(239, 68, 68, 0.2); color: var(--accent-red); }

        .node-info { font-size: 0.82rem; color: var(--text-muted); margin-bottom: 10px; }
        .node-info div { display: flex; justify-content: space-between; margin-bottom: 3px; }

        select.model-select {
            width: 100%;
            background: #0f172a;
            color: var(--text-main);
            border: 1px solid var(--border-color);
            padding: 8px;
            border-radius: 6px;
            font-size: 0.85rem;
            margin-bottom: 10px;
        }

        .control-btns { display: grid; grid-template-columns: repeat(4, 1fr); gap: 6px; margin-bottom: 10px; }
        .btn {
            background: var(--border-color);
            color: white;
            border: none;
            padding: 8px;
            border-radius: 6px;
            cursor: pointer;
            font-weight: 600;
            font-size: 0.85rem;
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
            padding: 8px;
            font-family: monospace;
            font-size: 0.72rem;
            height: 80px;
            overflow-y: auto;
            color: #38bdf8;
        }

        .charts-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 20px; margin-bottom: 30px; }
        .chart-card { background: var(--card-bg); padding: 15px; border-radius: 8px; border: 1px solid var(--border-color); }
        .chart-card h3 { font-size: 0.95rem; margin-bottom: 10px; color: var(--text-muted); }

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

    <div class="carousel-section">
        <div class="carousel-header">
            <h3>Navigazione Cluster (Auto-Discovery + Nodi Statici)</h3>
        </div>
        <div class="carousel-container" id="nodes-carousel"></div>
    </div>

    <div class="charts-grid">
        <div class="chart-card">
            <h3>Telemetria GPU NVIDIA (Temperatura & Ventole)</h3>
            <canvas id="tempChart" height="150"></canvas>
        </div>
        <div class="chart-card">
            <h3>Allocazione Memoria VRAM (MB)</h3>
            <canvas id="vramChart" height="150"></canvas>
        </div>
    </div>

    <div class="global-logs">
        <h3>Registro Richieste Gateway Open API (Porta 9001)</h3>
        <table class="log-table">
            <thead>
                <tr>
                    <th>Ora</th>
                    <th>Porta Destinazione</th>
                    <th>Modello Target</th>
                    <th>Latenza (ms)</th>
                    <th>Stato HTTP</th>
                </tr>
            </thead>
            <tbody id="global-request-logs">
                <tr><td colspan="5" style="text-align: center; color: var(--text-muted);">In attesa di richieste API...</td></tr>
            </tbody>
        </table>
    </div>

    <script>
        const ctxTemp = document.getElementById('tempChart').getContext('2d');
        const tempChart = new Chart(ctxTemp, {
            type: 'line',
            data: {
                labels: [],
                datasets: [
                    { label: 'Temp GPU (°C)', data: [], borderColor: '#ef4444', tension: 0.3 },
                    { label: 'Ventola (%)', data: [], borderColor: '#38bdf8', tension: 0.3 }
                ]
            },
            options: { responsive: true, scales: { y: { beginAtZero: true, max: 100 } } }
        });

        const ctxVram = document.getElementById('vramChart').getContext('2d');
        const vramChart = new Chart(ctxVram, {
            type: 'bar',
            data: {
                labels: ['RTX 3060 Ti'],
                datasets: [
                    { label: 'VRAM Usata (MB)', data: [0], backgroundColor: '#38bdf8' },
                    { label: 'VRAM Libera (MB)', data: [8192], backgroundColor: '#334155' }
                ]
            },
            options: { responsive: true, scales: { x: { stacked: true }, y: { stacked: true, max: 8192 } } }
        });

        const modelOptionsHTML = `
            <optgroup label="⚡ Leggeri & Avvio Rapido (RAM < 3GB)">
                <option value="Llama-3.2-3B-Instruct-Q4_K_M.gguf">Llama-3.2-3B-Instruct (1.9 GB) [CPU/GPU]</option>
                <option value="qwen2.5-1.5b-instruct-q8_0.gguf">Qwen2.5-1.5B-Instruct (1.8 GB) [CPU/GPU]</option>
            </optgroup>
            <optgroup label="💻 Sviluppo & Codice (Coding)">
                <option value="Qwen2.5-Coder-7B-Instruct-Q6_K.gguf">Qwen2.5-Coder-7B-Q6_K (5.9 GB) [CUDA Target]</option>
                <option value="Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf">Qwen2.5-Coder-14B-Q4_K_M (8.4 GB) [CUDA High VRAM]</option>
            </optgroup>
            <optgroup label="🧠 Ragionamento Generale & Istruzioni">
                <option value="Mistral-7B-Instruct-v0.3-Q6_K.gguf" selected>Mistral-7B-Instruct-v0.3 (5.6 GB) [Vulkan/CPU]</option>
                <option value="DeepSeek-V4-Pro-Qwen3.5-9B.Q4_K_M.gguf">DeepSeek-V4-Pro-9B (5.4 GB) [CUDA/Vulkan]</option>
            </optgroup>
        `;

        async function fetchTelemetry() {
            try {
                const res = await fetch('/api/telemetry');
                const data = await res.json();

                document.getElementById('cpu-host-val').innerText = `${data.cpu_usage}%`;
                document.getElementById('ram-host-val').innerText = `${data.ram_used_gb} / ${data.ram_total_gb} GB`;
                document.getElementById('vram-val').innerText = `${data.nvidia.vram_used} / ${data.nvidia.vram_total} MB`;
                document.getElementById('gpu-temp-val').innerText = `${data.nvidia.temp}°C / ${data.nvidia.fan}%`;

                const now = new Date().toLocaleTimeString();
                if (tempChart.data.labels.length > 10) {
                    tempChart.data.labels.shift();
                    tempChart.data.datasets[0].data.shift();
                    tempChart.data.datasets[1].data.shift();
                }
                tempChart.data.labels.push(now);
                tempChart.data.datasets[0].data.push(data.nvidia.temp);
                tempChart.data.datasets[1].data.push(data.nvidia.fan);
                tempChart.update();

                vramChart.data.datasets[0].data = [data.nvidia.vram_used];
                vramChart.data.datasets[1].data = [data.nvidia.vram_total - data.nvidia.vram_used];
                vramChart.update();

                const carousel = document.getElementById('nodes-carousel');
                carousel.innerHTML = '';

                data.nodes.forEach(node => {
                    node.backends.forEach(backend => {
                        const card = document.createElement('div');
                        card.className = 'node-card';
                        const isOnline = backend.status === "ONLINE";
                        const hw = backend.hardware || {};
                        card.innerHTML = `
                            <div class="node-header">
                                <span class="node-title">${node.name} (${backend.port})</span>
                                <span class="node-badge ${isOnline ? 'online' : 'offline'}">${backend.status}</span>
                            </div>
                            <div class="node-info">
                                <div><span>Host:</span> <strong>${node.host}</strong></div>
                                <div><span>Backend:</span> <strong>${backend.backend_type || 'N/A'}</strong></div>
                                <div><span>CPU / RAM Nodo:</span> <strong>${hw.cpu_util_pct || 0}% / ${hw.ram_used_gb || 0} GB</strong></div>
                                <div><span>Modello In Uso:</span> <strong style="color:var(--accent-blue)">${(backend.models_loaded || ['N/D'])[0]}</strong></div>
                            </div>
                            <select class="model-select" id="select-${backend.port}">
                                ${modelOptionsHTML}
                            </select>
                            <div class="control-btns">
                                <button class="btn btn-start" onclick="controlEngine(${backend.port}, 'start')" title="Avvia">▶</button>
                                <button class="btn btn-stop" onclick="controlEngine(${backend.port}, 'stop')" title="Arresta">⏹</button>
                                <button class="btn btn-restart" onclick="controlEngine(${backend.port}, 'restart')" title="Riavvia">🔄</button>
                                <button class="btn btn-kill" onclick="controlEngine(${backend.port}, 'kill')" title="Kill -9">✕</button>
                            </div>
                            <div class="terminal-box" id="term-${backend.port}">
                                [LOG ${node.node_id}] Backend attivo su porta ${backend.port}...
                            </div>
                        `;
                        carousel.appendChild(card);
                    });
                });

            } catch (err) {
                console.error("Errore fetch telemetria:", err);
            }
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
                            <td>${log.port}</td>
                            <td>${log.model}</td>
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

        setInterval(fetchTelemetry, 3000);
        setInterval(fetchLogs, 2000);
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
