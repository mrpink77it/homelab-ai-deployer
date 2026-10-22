#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/gateway"
SERVICE_FILE="/etc/systemd/system/llm-gateway.service"
CURRENT_USER="${SUDO_USER:-root}"

echo "[*] Aggiornamento directory di installazione $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

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
Dual GPU Router & Orchestrator (AMD Vulkan + NVIDIA CUDA)
"""

import time
import asyncio
import subprocess
import os
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
logger = logging.getLogger("DualGPURouter")

NODES = {
    "AMD_VULKAN": {
        "name": "AMD RX 5700 XT (Vulkan - Porta 8080)",
        "base_url": "http://127.0.0.1:8080",
        "auth_header": None,
        "status": "OFFLINE",
        "loaded_models": [],
        "active_model": None,
        "last_check": 0,
        "total_requests": 0,
        "last_latency": 0.0,
        "vram_used_mb": 0,
        "vram_total_mb": 8192
    },
    "NVIDIA_CUDA": {
        "name": "NVIDIA RTX 3060 Ti (CUDA - Porta 8888)",
        "base_url": "http://127.0.0.1:8888",
        "auth_header": "Bearer sk-unsloth-a763cc00f56f57e9edb1441e01533a7c",
        "status": "OFFLINE",
        "loaded_models": [],
        "active_model": None,
        "last_check": 0,
        "total_requests": 0,
        "last_latency": 0.0,
        "vram_used_mb": 0,
        "vram_total_mb": 8192
    }
}

RECENT_LOGS: List[Dict[str, Any]] = []

app = FastAPI(title="Dual GPU Router", version="2.6.1")

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
    if len(RECENT_LOGS) > 50:
        RECENT_LOGS.pop(0)

def get_nvidia_vram():
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=memory.used,memory.total", "--format=csv,noheader,nounits"],
            stderr=subprocess.DEVNULL
        ).decode("utf-8").strip()
        used, total = out.split("\n")[0].split(",")
        return int(used.strip()), int(total.strip())
    except Exception:
        return 0, 8192

def get_amd_vulkan_vram():
    try:
        for card in range(4):
            vram_used_path = f"/sys/class/drm/card{card}/device/mem_info_vram_used"
            vram_total_path = f"/sys/class/drm/card{card}/device/mem_info_vram_total"
            if os.path.exists(vram_used_path) and os.path.exists(vram_total_path):
                with open(vram_used_path, "r") as f:
                    used = int(f.read().strip()) // (1024 * 1024)
                with open(vram_total_path, "r") as f:
                    total = int(f.read().strip()) // (1024 * 1024)
                if total > 2000:
                    return used, total
    except Exception:
        pass
    return 0, 8192

async def inspect_node(node_key: str, config: Dict[str, Any]):
    headers = {}
    if config["auth_header"]:
        headers["Authorization"] = config["auth_header"]
        
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(f"{config['base_url']}/v1/models", headers=headers)
            if resp.status_code == 200:
                data = resp.json()
                models = [m.get("id") for m in data.get("data", [])]
                config["status"] = "ONLINE"
                config["loaded_models"] = models
                if not config["active_model"] and models:
                    config["active_model"] = models[0]
            else:
                config["status"] = f"ERROR ({resp.status_code})"
                config["loaded_models"] = []
    except Exception:
        config["status"] = "OFFLINE"
        config["loaded_models"] = []
    
    if node_key == "NVIDIA_CUDA":
        u, t = get_nvidia_vram()
        config["vram_used_mb"] = u
        config["vram_total_mb"] = t
    elif node_key == "AMD_VULKAN":
        u, t = get_amd_vulkan_vram()
        config["vram_used_mb"] = u
        config["vram_total_mb"] = t

    config["last_check"] = time.time()

async def discovery_loop():
    while True:
        for key, conf in NODES.items():
            await inspect_node(key, conf)
        await asyncio.sleep(4)

@app.on_event("startup")
async def startup_event():
    logger.info("Avvio Dual GPU Router (Vulkan + CUDA)...")
    add_log_entry("INFO", "Dual GPU Router avviato sulla porta 9000.")
    asyncio.create_task(discovery_loop())

class SwitchModelReq(BaseModel):
    node_key: str
    model_name: str

@app.post("/api/switch-model")
async def switch_model(req: SwitchModelReq):
    if req.node_key in NODES:
        if req.model_name in NODES[req.node_key]["loaded_models"]:
            NODES[req.node_key]["active_model"] = req.model_name
            add_log_entry("INFO", f"Modello attivo impostato su: {req.model_name}", req.node_key)
            return {"status": "ok", "active_model": req.model_name}
    raise HTTPException(status_code=400, detail="Nodo o modello non valido.")

class GatewayChatRequest(BaseModel):
    model: Optional[str] = None
    messages: List[Dict[str, str]]
    task_type: Optional[str] = None
    temperature: Optional[float] = 0.2
    stream: Optional[bool] = False

def select_target_node(request: GatewayChatRequest) -> str:
    if request.task_type == "coding":
        return "NVIDIA_CUDA"
    if request.task_type == "service":
        return "AMD_VULKAN"
        
    prompt_text = " ".join([m.get("content", "") for m in request.messages]).lower()
    coding_keywords = ["def ", "class ", "import ", "function", "bug", "refactor", "python", "javascript", "code", "c++"]
    
    if any(kw in prompt_text for kw in coding_keywords):
        return "NVIDIA_CUDA"
    
    return "AMD_VULKAN"

@app.post("/v1/chat/completions")
async def chat_completions(req: GatewayChatRequest, request: Request, authorization: Optional[str] = Header(None)):
    target_node_key = select_target_node(req)
    target_node = NODES[target_node_key]
    
    user_prompt = req.messages[-1].get("content", "") if req.messages else ""

    if target_node["status"] != "ONLINE":
        add_log_entry("WARN", f"Nodo {target_node['name']} non pronto. Fallback...", target_node_key, prompt=user_prompt)
        fallback_key = "NVIDIA_CUDA" if target_node_key == "AMD_VULKAN" else "AMD_VULKAN"
        if NODES[fallback_key]["status"] == "ONLINE":
            target_node_key = fallback_key
            target_node = NODES[target_node_key]
            add_log_entry("INFO", f"Fallback attivo su {target_node['name']}", target_node_key, prompt=user_prompt)
        else:
            add_log_entry("ERROR", "Tutti i nodi OFFLINE.", target_node_key, prompt=user_prompt)
            raise HTTPException(status_code=503, detail="Tutti i worker locali sono OFFLINE.")
            
    chosen_model = req.model or target_node["active_model"] or (target_node["loaded_models"][0] if target_node["loaded_models"] else "default-model")

    url = f"{target_node['base_url']}/v1/chat/completions"
    headers = {"Content-Type": "application/json"}
    if target_node["auth_header"]:
        headers["Authorization"] = target_node["auth_header"]
        
    payload = {
        "model": chosen_model,
        "messages": req.messages,
        "temperature": req.temperature,
        "stream": req.stream
    }
    
    start_time = time.time()
    add_log_entry("INFO", f"Inoltro -> {chosen_model}", target_node_key, prompt=user_prompt)

    async with httpx.AsyncClient(timeout=120.0) as client:
        try:
            resp = await client.post(url, json=payload, headers=headers)
            elapsed = time.time() - start_time
            
            target_node["total_requests"] += 1
            target_node["last_latency"] = elapsed
            
            if resp.status_code == 200:
                resp_data = resp.json()
                usage = resp_data.get("usage", {})
                tok_in = usage.get("prompt_tokens", 0)
                tok_out = usage.get("completion_tokens", 0)
                add_log_entry("SUCCESS", f"Completato ({tok_in}in / {tok_out}out)", target_node_key, elapsed, user_prompt, tok_in, tok_out)
                return resp_data
            else:
                add_log_entry("ERROR", f"Status {resp.status_code}", target_node_key, elapsed, user_prompt)
                return JSONResponse(status_code=resp.status_code, content=resp.json())
        except Exception as e:
            add_log_entry("ERROR", f"Errore rete: {str(e)}", target_node_key, prompt=user_prompt)
            raise HTTPException(status_code=502, detail=f"Errore comunicazione nodo: {str(e)}")

@app.get("/api/metrics")
async def get_metrics():
    return {
        "nodes": NODES,
        "logs": RECENT_LOGS
    }

@app.get("/", response_class=HTMLResponse)
@app.get("/dashboard", response_class=HTMLResponse)
async def serve_dashboard():
    html_content = """
    <!DOCTYPE html>
    <html lang="it">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Dual GPU Router</title>
        <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
        <style>
            :root {
                --bg: #0f172a;
                --card-bg: #1e293b;
                --text: #f8fafc;
                --accent: #38bdf8;
                --success: #22c55e;
                --danger: #ef4444;
                --warning: #f59e0b;
            }
            body {
                font-family: 'Segoe UI', system-ui, sans-serif;
                background-color: var(--bg);
                color: var(--text);
                margin: 0;
                padding: 20px;
            }
            h1 { color: var(--accent); margin-bottom: 2px; font-size: 1.8rem; }
            .subtitle { color: #94a3b8; font-size: 0.85em; margin-bottom: 20px; }
            .grid {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
                gap: 20px;
                margin-bottom: 25px;
            }
            .card {
                background-color: var(--card-bg);
                border-radius: 10px;
                padding: 18px;
                box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.3);
                border: 1px solid #334155;
            }
            .card-header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                border-bottom: 1px solid #334155;
                padding-bottom: 8px;
                margin-bottom: 12px;
            }
            .badge {
                padding: 3px 8px;
                border-radius: 12px;
                font-size: 0.75em;
                font-weight: bold;
            }
            .status-ONLINE { background-color: rgba(34, 197, 94, 0.2); color: var(--success); border: 1px solid var(--success); }
            .status-OFFLINE { background-color: rgba(239, 68, 68, 0.2); color: var(--danger); border: 1px solid var(--danger); }
            .metric-row { display: flex; justify-content: space-between; margin-bottom: 6px; font-size: 0.9em; }
            .metric-label { color: #94a3b8; }
            .metric-value { font-weight: bold; }
            select {
                background: #0f172a;
                color: var(--accent);
                border: 1px solid #334155;
                padding: 6px;
                border-radius: 6px;
                width: 100%;
                font-size: 0.88em;
                margin-top: 4px;
            }
            .chart-container {
                position: relative;
                height: 140px;
                margin-top: 10px;
            }
            .log-container {
                background-color: var(--card-bg);
                border-radius: 10px;
                padding: 18px;
                border: 1px solid #334155;
                overflow-x: auto;
            }
            table { width: 100%; border-collapse: collapse; margin-top: 10px; }
            th, td { text-align: left; padding: 8px; border-bottom: 1px solid #334155; font-size: 0.85em; }
            th { color: #94a3b8; }
            .log-SUCCESS { color: var(--success); }
            .log-ERROR { color: var(--danger); }
            .log-WARN { color: var(--warning); }
            .log-INFO { color: var(--accent); }
            .prompt-cell { max-width: 280px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #cbd5e1; }
        </style>
    </head>
    <body>
        <h1>Dual GPU Router</h1>
        <div class="subtitle">AMD RX 5700 XT (Vulkan) + NVIDIA RTX 3060 Ti (CUDA) - Real-Time VRAM & Request Monitor</div>

        <div class="grid">
            <div class="card" id="card-AMD_VULKAN">
                <div class="card-header">
                    <strong id="title-AMD_VULKAN">AMD RX 5700 XT (Vulkan)</strong>
                    <span id="badge-AMD_VULKAN" class="badge status-OFFLINE">OFFLINE</span>
                </div>
                <div class="metric-row"><span class="metric-label">Endpoint:</span><span class="metric-value">http://127.0.0.1:8080</span></div>
                <div class="metric-row"><span class="metric-label">Richieste:</span><span class="metric-value" id="req-AMD_VULKAN">0</span></div>
                <div class="metric-row"><span class="metric-label">Latenza:</span><span class="metric-value" id="lat-AMD_VULKAN">-</span></div>
                <div style="margin-top: 10px;">
                    <label class="metric-label">Modello Attivo:</label>
                    <select id="select-AMD_VULKAN" onchange="switchModel('AMD_VULKAN', this.value)"></select>
                </div>
                <div class="chart-container">
                    <canvas id="chart-AMD_VULKAN"></canvas>
                </div>
            </div>

            <div class="card" id="card-NVIDIA_CUDA">
                <div class="card-header">
                    <strong id="title-NVIDIA_CUDA">NVIDIA RTX 3060 Ti (CUDA)</strong>
                    <span id="badge-NVIDIA_CUDA" class="badge status-OFFLINE">OFFLINE</span>
                </div>
                <div class="metric-row"><span class="metric-label">Endpoint:</span><span class="metric-value">http://127.0.0.1:8888</span></div>
                <div class="metric-row"><span class="metric-label">Richieste:</span><span class="metric-value" id="req-NVIDIA_CUDA">0</span></div>
                <div class="metric-row"><span class="metric-label">Latenza:</span><span class="metric-value" id="lat-NVIDIA_CUDA">-</span></div>
                <div style="margin-top: 10px;">
                    <label class="metric-label">Modello Attivo:</label>
                    <select id="select-NVIDIA_CUDA" onchange="switchModel('NVIDIA_CUDA', this.value)"></select>
                </div>
                <div class="chart-container">
                    <canvas id="chart-NVIDIA_CUDA"></canvas>
                </div>
            </div>
        </div>

        <div class="log-container">
            <h3 style="margin: 0; color: var(--accent);">Registro Eventi, Prompt & Token</h3>
            <table>
                <thead>
                    <tr>
                        <th>Ora</th>
                        <th>Stato</th>
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
            const charts = {};

            function createGaugeChart(canvasId, label) {
                const ctx = document.getElementById(canvasId).getContext('2d');
                return new Chart(ctx, {
                    type: 'doughnut',
                    data: {
                        labels: ['VRAM Usata (MB)', 'VRAM Libera (MB)'],
                        datasets: [{
                            data: [0, 8192],
                            backgroundColor: ['#38bdf8', '#334155'],
                            borderWidth: 0
                        }]
                    },
                    options: {
                        responsive: true,
                        maintainAspectRatio: false,
                        plugins: {
                            legend: { position: 'right', labels: { color: '#94a3b8', font: { size: 10 } } },
                            title: { display: true, text: label, color: '#f8fafc', font: { size: 11 } }
                        },
                        cutout: '70%'
                    }
                });
            }

            charts['AMD_VULKAN'] = createGaugeChart('chart-AMD_VULKAN', 'AMD VRAM (MB)');
            charts['NVIDIA_CUDA'] = createGaugeChart('chart-NVIDIA_CUDA', 'NVIDIA VRAM (MB)');

            async function switchModel(nodeKey, modelName) {
                try {
                    await fetch('/api/switch-model', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ node_key: nodeKey, model_name: modelName })
                    });
                } catch(e) { console.error("Errore switch:", e); }
            }

            async function updateDashboard() {
                try {
                    const res = await fetch('/api/metrics');
                    const data = await res.json();
                    
                    for (const [key, node] of Object.entries(data.nodes)) {
                        document.getElementById(`badge-${key}`).className = `badge status-${node.status.startsWith('ONLINE') ? 'ONLINE' : 'OFFLINE'}`;
                        document.getElementById(`badge-${key}`).innerText = node.status;
                        document.getElementById(`req-${key}`).innerText = node.total_requests;
                        document.getElementById(`lat-${key}`).innerText = node.last_latency > 0 ? node.last_latency.toFixed(2) + 's' : '-';

                        const sel = document.getElementById(`select-${key}`);
                        if (node.loaded_models.length > 0) {
                            sel.innerHTML = node.loaded_models.map(m => 
                                `<option value="${m}" ${m === node.active_model ? 'selected' : ''}>${m}</option>`
                            ).join('');
                        } else {
                            sel.innerHTML = '<option>Nessun modello caricato</option>';
                        }

                        if (charts[key]) {
                            const free = Math.max(0, node.vram_total_mb - node.vram_used_mb);
                            charts[key].data.datasets[0].data = [node.vram_used_mb, free];
                            charts[key].options.plugins.title.text = `VRAM: ${node.vram_used_mb} MB / ${node.vram_total_mb} MB`;
                            charts[key].update();
                        }
                    }

                    const logsBody = document.getElementById('logs-body');
                    logsBody.innerHTML = '';
                    [...data.logs].reverse().forEach(log => {
                        logsBody.innerHTML += `
                            <tr>
                                <td>${log.timestamp}</td>
                                <td class="log-${log.level}"><strong>${log.level}</strong></td>
                                <td>${log.node}</td>
                                <td class="prompt-cell" title="${log.prompt || ''}">${log.prompt || '-'}</td>
                                <td>${log.tokens_in || 0} / ${log.tokens_out || 0}</td>
                                <td>${log.latency}</td>
                                <td>${log.message}</td>
                            </tr>
                        `;
                    });

                } catch (err) {
                    console.error("Errore aggiornamento:", err);
                }
            }

            setInterval(updateDashboard, 2500);
            updateDashboard();
        </script>
    </body>
    </html>
    """
    return HTMLResponse(content=html_content, status_code=200)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=9000, log_level="warning")
EOF_PY

python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"
chown -R "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/llm_gateway.py"

cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Dual GPU Router Service
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
systemctl restart llm-gateway.service
echo "[OK] Dual GPU Router aggiornato ed avviato con successo."

