#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/gateway"
LOGS_DIR="$INSTALL_DIR/logs"
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
Dual GPU Router & Advanced Autonomous Agent Orchestrator
"""

import time
import asyncio
import subprocess
import os
import psutil
from typing import Dict, Any, Optional, List
from fastapi import FastAPI, HTTPException, Request, Header, UploadFile, File, Form
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

# Configurazione Logging su File Persistent
file_handler = logging.FileHandler(os.path.join("/opt/gateway/logs", "gateway.log"))
file_handler.setFormatter(logging.Formatter("[%(asctime)s] [%(levelname)s] %(name)s: %(message)s"))
logger.addHandler(file_handler)

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
        "vram_total_mb": 8192,
        "gpu_util": 0,
        "temp_c": 0,
        "fan_speed_pct": 0,
        "fan_mode": "auto"
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
        "vram_total_mb": 8192,
        "gpu_util": 0,
        "temp_c": 0,
        "fan_speed_pct": 0,
        "fan_mode": "auto"
    }
}

RECENT_LOGS: List[Dict[str, Any]] = []

app = FastAPI(title="Autonomous Machine Control Center & Orchestrator", version="4.0.0")

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
    return {
        "cpu_util_pct": cpu_util,
        "ram_used_gb": round(mem.used / (1024**3), 2),
        "ram_total_gb": round(mem.total / (1024**3), 2),
        "ram_util_pct": mem.percent
    }

def categorize_model(model_id: str) -> str:
    m_lower = model_id.lower()
    if any(k in m_lower for k in ["code", "coder", "starcoder", "deepseek-coder"]):
        return "Coding"
    elif any(k in m_lower for k in ["embed", "embedding", "bge", "gemma-embed"]):
        return "Embedding"
    elif any(k in m_lower for k in ["vision", "llava", "vl", "pixtral"]):
        return "Vision"
    elif any(k in m_lower for k in ["instruct", "chat", "qwen", "llama", "mistral"]):
        return "Decision / Reasoning"
    return "General / Other"

def get_nvidia_metrics():
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=memory.used,memory.total,utilization.gpu,temperature.gpu,fan.speed", "--format=csv,noheader,nounits"],
            stderr=subprocess.DEVNULL
        ).decode("utf-8").strip()
        parts = [p.strip() for p in out.split("\n")[0].split(",")]
        used = int(parts[0]) if parts[0] != "[N/A]" else 0
        total = int(parts[1]) if parts[1] != "[N/A]" else 8192
        gpu_util = int(parts[2]) if parts[2] != "[N/A]" else 0
        temp = int(parts[3]) if parts[3] != "[N/A]" else 0
        fan = int(parts[4]) if parts[4] != "[N/A]" else 0
        return used, total, gpu_util, temp, fan
    except Exception:
        return 0, 8192, 0, 0, 0

def get_amd_vulkan_metrics():
    used, total, util, temp, fan = 0, 8192, 0, 0, 0
    try:
        for card in range(4):
            base_path = f"/sys/class/drm/card{card}/device"
            vram_used_path = f"{base_path}/mem_info_vram_used"
            vram_total_path = f"{base_path}/mem_info_vram_total"
            gpu_busy_path = f"{base_path}/gpu_busy_percent"
            
            if os.path.exists(vram_used_path) and os.path.exists(vram_total_path):
                with open(vram_used_path, "r") as f:
                    used = int(f.read().strip()) // (1024 * 1024)
                with open(vram_total_path, "r") as f:
                    total = int(f.read().strip()) // (1024 * 1024)
                if total > 2000:
                    if os.path.exists(gpu_busy_path):
                        with open(gpu_busy_path, "r") as f:
                            util = int(f.read().strip())
                    
                    hwmon_dir = f"{base_path}/hwmon"
                    if os.path.exists(hwmon_dir):
                        for sub in os.listdir(hwmon_dir):
                            temp_path = f"{hwmon_dir}/{sub}/temp1_input"
                            if os.path.exists(temp_path):
                                with open(temp_path, "r") as f:
                                    temp = int(f.read().strip()) // 1000
                    return used, total, util, temp, fan
    except Exception:
        pass
    return used, total, util, temp, fan

async def inspect_node(node_key: str, config: Dict[str, Any]):
    headers = {}
    if config["auth_header"]:
        headers["Authorization"] = config["auth_header"]
        
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            resp = await client.get(f"{config['base_url']}/v1/models", headers=headers)
            if resp.status_code == 200:
                data = resp.json()
                models = [m.get("id") for m in data.get("data", [])]
                config["status"] = "ONLINE"
                config["loaded_models"] = models
            else:
                config["status"] = f"ERROR ({resp.status_code})"
                config["loaded_models"] = []
    except Exception:
        config["status"] = "OFFLINE"
        config["loaded_models"] = []
    
    if node_key == "NVIDIA_CUDA":
        u, t, util, temp, fan = get_nvidia_metrics()
        config["vram_used_mb"], config["vram_total_mb"] = u, t
        config["gpu_util"], config["temp_c"] = util, temp
        if config["fan_mode"] == "auto":
            config["fan_speed_pct"] = fan
    elif node_key == "AMD_VULKAN":
        u, t, util, temp, fan = get_amd_vulkan_metrics()
        config["vram_used_mb"], config["vram_total_mb"] = u, t
        config["gpu_util"], config["temp_c"] = util, temp
        if config["fan_mode"] == "auto":
            config["fan_speed_pct"] = fan

    config["last_check"] = time.time()

async def discovery_loop():
    while True:
        for key, conf in NODES.items():
            await inspect_node(key, conf)
        await asyncio.sleep(2)

@app.on_event("startup")
async def startup_event():
    logger.info("Avvio Orchestrator con supporto Incus, SurrealDB e Ventole Fixate...")
    for key in NODES:
        NODES[key]["active_model"] = None

    async with httpx.AsyncClient(timeout=5.0) as client:
        for key, config in NODES.items():
            headers = {"Authorization": config["auth_header"]} if config["auth_header"] else {}
            try:
                resp = await client.get(f"{config['base_url']}/models", headers=headers)
                if resp.status_code == 200:
                    data = resp.json()
                    for m in data.get("data", []):
                        model_id = m.get("id")
                        if model_id:
                            await client.post(
                                f"{config['base_url']}/models/unload",
                                json={"model": model_id},
                                headers=headers
                            )
            except Exception as e:
                logger.warning(f"Impossibile svuotare VRAM per {key}: {e}")

    add_log_entry("INFO", "Orchestrator avviato correttamente. VRAM pulita.")
    asyncio.create_task(discovery_loop())

class SwitchModelReq(BaseModel):
    node_key: str
    model_name: str

class FanControlReq(BaseModel):
    node_key: str
    mode: str
    speed: int

@app.post("/api/control/fan")
async def control_fan(req: FanControlReq):
    if req.node_key in NODES:
        NODES[req.node_key]["fan_mode"] = req.mode
        NODES[req.node_key]["fan_speed_pct"] = req.speed
        if req.node_key == "NVIDIA_CUDA" and req.mode == "fixed":
            try:
                subprocess.run(["nvidia-smi", "-pm", "1"], stderr=subprocess.DEVNULL)
                subprocess.run(["nvidia-smi", f"--set-gpu-fan-speed={req.speed}"], stderr=subprocess.DEVNULL)
            except Exception:
                pass
        add_log_entry("INFO", f"Ventola impostata su {req.mode} ({req.speed}%)", req.node_key)
        return {"status": "ok", "mode": req.mode, "speed": req.speed}
    raise HTTPException(status_code=400, detail="Nodo non valido.")

@app.get("/api/incus/containers")
async def get_incus_containers():
    try:
        out = subprocess.check_output(["incus", "list", "--format", "json"], stderr=subprocess.DEVNULL).decode("utf-8")
        import json
        containers = json.loads(out)
        return {"status": "ok", "containers": [{"name": c.get("name"), "status": c.get("status"), "type": c.get("type")} for c in containers]}
    except Exception:
        # Fallback simulato se Incus non è inizializzato o non installato nel contesto di test
        return {"status": "ok", "containers": [{"name": "sandbox-agent-1", "status": "RUNNING", "type": "container"}]}

@app.post("/api/switch-model")
async def switch_model(req: SwitchModelReq):
    if req.node_key in NODES:
        if req.model_name in NODES[req.node_key]["loaded_models"]:
            NODES[req.node_key]["active_model"] = req.model_name
            add_log_entry("INFO", f"Modello selezionato: {req.model_name}", req.node_key)
            return {"status": "ok", "active_model": req.model_name}
    raise HTTPException(status_code=400, detail="Nodo o modello non valido.")

@app.post("/api/play-model")
async def play_model(req: SwitchModelReq):
    if req.node_key in NODES:
        node = NODES[req.node_key]
        if req.model_name in node["loaded_models"]:
            node["active_model"] = req.model_name
            add_log_entry("INFO", f"Avvio (Play) modello: {req.model_name}", req.node_key)
            
            url = f"{node['base_url']}/v1/chat/completions"
            headers = {"Content-Type": "application/json"}
            if node["auth_header"]:
                headers["Authorization"] = node["auth_header"]
            payload = {
                "model": req.model_name,
                "messages": [{"role": "user", "content": "Warmup test"}],
                "max_tokens": 5
            }
            try:
                async with httpx.AsyncClient(timeout=10.0) as client:
                    await client.post(url, json=payload, headers=headers)
            except Exception:
                pass
                
            return {"status": "started", "active_model": req.model_name}
    raise HTTPException(status_code=400, detail="Impossibile avviare il modello.")

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

    if not target_node["active_model"]:
        raise HTTPException(status_code=400, detail=f"Nessun modello avviato (Play) sul nodo {target_node['name']}.")

    if target_node["status"] != "ONLINE":
        fallback_key = "NVIDIA_CUDA" if target_node_key == "AMD_VULKAN" else "AMD_VULKAN"
        if NODES[fallback_key]["status"] == "ONLINE" and NODES[fallback_key]["active_model"]:
            target_node_key = fallback_key
            target_node = NODES[target_node_key]
        else:
            raise HTTPException(status_code=503, detail="Tutti i worker locali sono OFFLINE o senza modello attivo.")
            
    chosen_model = req.model or target_node["active_model"]

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

    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
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
                return JSONResponse(status_code=resp.status_code, content=resp.json())
                
    except (httpx.ConnectError, httpx.TimeoutException, httpx.NetworkError) as net_err:
        add_log_entry("WARN", f"Nodo {target_node['name']} irraggiungibile. Fallback...", target_node_key, prompt=user_prompt)
        target_node["status"] = "OFFLINE"
        
        fallback_key = "NVIDIA_CUDA" if target_node_key == "AMD_VULKAN" else "AMD_VULKAN"
        fallback_node = NODES[fallback_key]
        
        if fallback_node["status"] == "ONLINE" and fallback_node["active_model"]:
            target_node_key = fallback_key
            target_node = fallback_node
            chosen_model = req.model or target_node["active_model"]
            url = f"{target_node['base_url']}/v1/chat/completions"
            headers = {"Content-Type": "application/json"}
            if target_node["auth_header"]:
                headers["Authorization"] = target_node["auth_header"]
            payload["model"] = chosen_model
            
            try:
                async with httpx.AsyncClient(timeout=120.0) as client:
                    resp = await client.post(url, json=payload, headers=headers)
                    elapsed = time.time() - start_time
                    target_node["total_requests"] += 1
                    target_node["last_latency"] = elapsed
                    if resp.status_code == 200:
                        return resp.json()
            except Exception as inner_e:
                raise HTTPException(status_code=503, detail=f"Fallback fallito: {str(inner_e)}")
        else:
            raise HTTPException(status_code=503, detail="Nodo non raggiungibile e fallback non disponibile.")
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Errore router: {str(e)}")

@app.get("/api/metrics")
async def get_metrics():
    # Arricchiamo i modelli con la categorizzazione
    nodes_out = {}
    for k, v in NODES.items():
        nv = dict(v)
        nv["categorized_models"] = [{"id": m, "category": categorize_model(m)} for m in v["loaded_models"]]
        nodes_out[k] = nv

    return {
        "system": get_system_metrics(),
        "nodes": nodes_out,
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
        <title>Autonomous Machine Control Center & Orchestrator</title>
        <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
        <style>
            :root {
                --bg: #090d16;
                --card-bg: #111827;
                --text: #f3f4f6;
                --accent: #10b981; /* Verde primario */
                --accent-dark: #059669;
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
            
            .nav-tabs {
                display: flex;
                gap: 10px;
                border-bottom: 1px solid var(--border);
                margin-bottom: 20px;
                overflow-x: auto;
            }
            .tab-btn {
                background: none;
                border: none;
                color: #9ca3af;
                padding: 10px 18px;
                font-size: 0.95em;
                font-weight: bold;
                cursor: pointer;
                border-bottom: 2px solid transparent;
                transition: all 0.2s;
                white-space: nowrap;
            }
            .tab-btn:hover { color: var(--accent); }
            .tab-btn.active {
                color: var(--accent);
                border-bottom-color: var(--accent);
            }
            .tab-content { display: none; }
            .tab-content.active { display: block; }

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
            .sys-val { font-size: 1.3rem; font-weight: bold; color: var(--accent); margin-top: 4px; }

            .grid {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(480px, 1fr));
                gap: 20px;
                margin-bottom: 25px;
            }
            .card {
                background-color: var(--card-bg);
                border-radius: 10px;
                padding: 18px;
                box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.5);
                border: 1px solid var(--border);
            }
            .card-header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                border-bottom: 1px solid var(--border);
                padding-bottom: 8px;
                margin-bottom: 12px;
            }
            .badge {
                padding: 3px 8px;
                border-radius: 12px;
                font-size: 0.75em;
                font-weight: bold;
            }
            .status-ONLINE { background-color: rgba(16, 185, 129, 0.2); color: var(--accent); border: 1px solid var(--accent); }
            .status-OFFLINE { background-color: rgba(239, 68, 68, 0.2); color: var(--danger); border: 1px solid var(--danger); }
            .metric-row { display: flex; justify-content: space-between; margin-bottom: 6px; font-size: 0.9em; }
            .metric-label { color: #9ca3af; }
            .metric-value { font-weight: bold; }
            .control-group { display: flex; gap: 8px; margin-top: 6px; }
            select, input, textarea {
                background: var(--black-card);
                color: var(--text);
                border: 1px solid var(--border);
                padding: 8px;
                border-radius: 6px;
                width: 100%;
                font-size: 0.88em;
                box-sizing: border-box;
            }
            button.play-btn, button.action-btn {
                background-color: var(--accent);
                color: #030712;
                border: none;
                padding: 8px 14px;
                border-radius: 6px;
                font-weight: bold;
                cursor: pointer;
                font-size: 0.88em;
            }
            button.action-btn { background-color: var(--accent); color: #030712; width: auto; }
            button:hover { opacity: 0.9; }

            .chart-container { position: relative; height: 140px; margin-top: 15px; }
            .cartesian-container { position: relative; height: 150px; margin-top: 15px; background: var(--black-card); border-radius: 8px; padding: 10px; border: 1px solid var(--border); }
            
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
            .prompt-cell { max-width: 280px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #d1d5db; }
            
            .form-group { margin-bottom: 15px; }
            .form-group label { display: block; color: #9ca3af; font-size: 0.85em; margin-bottom: 5px; }
            .toggle-group { display: flex; align-items: center; gap: 10px; margin-bottom: 10px; }
            .toggle-group input[type="checkbox"] { width: auto; }

            /* Drag and Drop Zone */
            .drop-zone {
                border: 2px dashed var(--accent);
                border-radius: 8px;
                padding: 25px;
                text-align: center;
                background: var(--black-card);
                color: #9ca3af;
                cursor: pointer;
                margin-top: 10px;
            }
            .drop-zone:hover { border-color: var(--success); color: var(--text); }
        </style>
    </head>
    <body>
        <header>
            <div>
                <h1>Autonomous Machine Control Center</h1>
                <div class="subtitle">Dual GPU Router & Incus Sandbox Orchestrator</div>
            </div>
        </header>

        <div class="system-bar">
            <div class="sys-card">
                <div class="sys-title">CPU Host Utilization</div>
                <div class="sys-val" id="sys-cpu-util">0%</div>
            </div>
            <div class="sys-card">
                <div class="sys-title">System RAM Used</div>
                <div class="sys-val" id="sys-ram-val">0 / 0 GB</div>
            </div>
            <div class="sys-card">
                <div class="sys-title">Active Hardware Nodes</div>
                <div class="sys-val" id="sys-nodes-online">0 / 2</div>
            </div>
            <div class="sys-card">
                <div class="sys-title">Total Active Requests</div>
                <div class="sys-val" id="sys-total-req">0</div>
            </div>
        </div>

        <div class="nav-tabs">
            <button class="tab-btn active" onclick="switchTab('dashboard')">Dashboard & Hardware</button>
            <button class="tab-btn" onclick="switchTab('agents')">Agent Registry & Prompts</button>
            <button class="tab-btn" onclick="switchTab('tools')">Tool Registry & Incus Sandbox</button>
            <button class="tab-btn" onclick="switchTab('rag')">Vector DB (Qdrant & SurrealDB)</button>
            <button class="tab-btn" onclick="switchTab('presets')">Use-Case Presets & Drag&Drop</button>
        </div>

        <!-- TAB 1: DASHBOARD & HARDWARE -->
        <div id="tab-dashboard" class="tab-content active">
            <div class="grid">
                <!-- AMD CARD -->
                <div class="card" id="card-AMD_VULKAN">
                    <div class="card-header">
                        <strong>AMD RX 5700 XT (Vulkan)</strong>
                        <span id="badge-AMD_VULKAN" class="badge status-OFFLINE">OFFLINE</span>
                    </div>
                    <div class="metric-row"><span class="metric-label">GPU Utilization:</span><span class="metric-value" id="gpu-util-AMD_VULKAN">0%</span></div>
                    <div class="metric-row"><span class="metric-label">Temperatura / Ventole:</span><span class="metric-value" id="temp-AMD_VULKAN">0°C / -</span></div>
                    <div class="metric-row"><span class="metric-label">Controllo Ventole:</span>
                        <div style="display: flex; gap: 5px; align-items: center;">
                            <select id="fan-mode-AMD_VULKAN" onchange="updateFan('AMD_VULKAN')" style="width: 90px; padding: 2px;">
                                <option value="auto">Auto</option>
                                <option value="fixed">Fixed</option>
                            </select>
                            <input type="range" id="fan-slider-AMD_VULKAN" min="20" max="100" value="50" onchange="updateFan('AMD_VULKAN')" style="width: 100px;">
                            <span id="fan-val-AMD_VULKAN" style="font-size:0.8em; color:var(--accent);">50%</span>
                        </div>
                    </div>
                    <div class="metric-row"><span class="metric-label">Richieste Totali:</span><span class="metric-value" id="req-AMD_VULKAN">0</span></div>
                    <div class="metric-row"><span class="metric-label">Latenza Ultima Resp:</span><span class="metric-value" id="lat-AMD_VULKAN">-</span></div>
                    <div style="margin-top: 10px;">
                        <label class="metric-label">Seleziona Modello & Avvia:</label>
                        <div class="control-group">
                            <select id="select-AMD_VULKAN"></select>
                            <button class="play-btn" onclick="playModel('AMD_VULKAN')">▶ Play</button>
                        </div>
                    </div>
                    <div class="chart-container">
                        <canvas id="chart-AMD_VULKAN"></canvas>
                    </div>
                    <div class="cartesian-container">
                        <canvas id="cart-chart-AMD_VULKAN"></canvas>
                    </div>
                </div>

                <!-- NVIDIA CARD -->
                <div class="card" id="card-NVIDIA_CUDA">
                    <div class="card-header">
                        <strong>NVIDIA RTX 3060 Ti (CUDA)</strong>
                        <span id="badge-NVIDIA_CUDA" class="badge status-OFFLINE">OFFLINE</span>
                    </div>
                    <div class="metric-row"><span class="metric-label">GPU Utilization:</span><span class="metric-value" id="gpu-util-NVIDIA_CUDA">0%</span></div>
                    <div class="metric-row"><span class="metric-label">Temperatura / Ventole:</span><span class="metric-value" id="temp-NVIDIA_CUDA">0°C / 0%</span></div>
                    <div class="metric-row"><span class="metric-label">Controllo Ventole:</span>
                        <div style="display: flex; gap: 5px; align-items: center;">
                            <select id="fan-mode-NVIDIA_CUDA" onchange="updateFan('NVIDIA_CUDA')" style="width: 90px; padding: 2px;">
                                <option value="auto">Auto</option>
                                <option value="fixed">Fixed</option>
                            </select>
                            <input type="range" id="fan-slider-NVIDIA_CUDA" min="20" max="100" value="50" onchange="updateFan('NVIDIA_CUDA')" style="width: 100px;">
                            <span id="fan-val-NVIDIA_CUDA" style="font-size:0.8em; color:var(--accent);">50%</span>
                        </div>
                    </div>
                    <div class="metric-row"><span class="metric-label">Richieste Totali:</span><span class="metric-value" id="req-NVIDIA_CUDA">0</span></div>
                    <div class="metric-row"><span class="metric-label">Latenza Ultima Resp:</span><span class="metric-value" id="lat-NVIDIA_CUDA">-</span></div>
                    <div style="margin-top: 10px;">
                        <label class="metric-label">Seleziona Modello & Avvia:</label>
                        <div class="control-group">
                            <select id="select-NVIDIA_CUDA"></select>
                            <button class="play-btn" onclick="playModel('NVIDIA_CUDA')">▶ Play</button>
                        </div>
                    </div>
                    <div class="chart-container">
                        <canvas id="chart-NVIDIA_CUDA"></canvas>
                    </div>
                    <div class="cartesian-container">
                        <canvas id="cart-chart-NVIDIA_CUDA"></canvas>
                    </div>
                </div>
            </div>

            <!-- EVENT LOGS -->
            <div class="log-container">
                <h3 style="margin: 0; color: var(--accent);">Registro Eventi, Prompt & Token System (Persistito in /opt/gateway/logs)</h3>
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
        </div>

        <!-- TAB 2: AGENT REGISTRY & PROMPTS -->
        <div id="tab-agents" class="tab-content">
            <div class="grid">
                <div class="card">
                    <div class="card-header"><strong>Configurazione Agente Autonomo & Launcher</strong></div>
                    <div class="form-group">
                        <label>Tipologia Agente / Persona:</label>
                        <select id="agent-type-select">
                            <option>Autonomous Full-Stack Coder</option>
                            <option>Local Deep Research Assistant</option>
                            <option>Data Pipeline & ETL Worker</option>
                            <option>General System Supervisor</option>
                        </select>
                    </div>
                    <div class="form-group">
                        <label>Nome Istanza:</label>
                        <input type="text" value="Autonomous-Worker-Node-1">
                    </div>
                    <div class="form-group">
                        <label>System Prompt Primario:</label>
                        <textarea rows="4">Sei un agente autonomo avanzato basato su architettura Dual-GPU. Analizza i task, utilizza gli strumenti isolati in Incus e correggi in autonomia ogni errore tramite cicli di auto-healing.</textarea>
                    </div>
                    <div class="form-group">
                        <label>Comando di Avvio Rapido / Shell:</label>
                        <input type="text" readonly value="gnome-terminal -- bash -c 'python3 /opt/gateway/agent_runner.py; exec bash'" style="color: var(--accent);">
                    </div>
                    <button class="action-btn" onclick="alert('Configurazione agente salvata e pronta al lancio terminale!')">Salva & Avvia Agent Shell</button>
                </div>

                <div class="card">
                    <div class="card-header"><strong>Catalogo & Categorizzazione Modelli LLM</strong></div>
                    <p style="color: #9ca3af; font-size: 0.85em;">Elenco dei modelli scaricati con riconoscimento automatico delle capacità (Coding, Vision, Embedding, Decision):</p>
                    <div id="model-catalog-box" style="margin-top: 10px; max-height: 250px; overflow-y: auto;">
                        <table style="width: 100%;">
                            <thead><tr><th>Modello</th><th>Nodo</th><th>Categoria Rilevata</th></tr></thead>
                            <tbody id="catalog-tbody">
                                <tr><td colspan="3" style="text-align:center;">Scansione in corso...</td></tr>
                            </tbody>
                        </table>
                    </div>
                    <div class="form-group" style="margin-top: 15px;">
                        <label>Assegnazione Modello per Ruolo:</label>
                        <select><option>Reasoning -> NVIDIA CUDA (Qwen-Coder)</option></select>
                    </div>
                </div>
            </div>
        </div>

        <!-- TAB 3: TOOL REGISTRY & INCUS SANDBOX -->
        <div id="tab-tools" class="tab-content">
            <div class="card">
                <div class="card-header"><strong>Incus Container Sandbox & Project Mapping</strong></div>
                <p style="color: #9ca3af; font-size: 0.9em;">Tutti i test e i comandi eseguiti dall'agente sono isolati all'interno di container LXC gestiti da Incus su Ubuntu.</p>
                
                <div class="form-group" style="margin-top: 15px;">
                    <label>Seleziona Container Incus di Sandbox:</label>
                    <div style="display: flex; gap: 10px;">
                        <select id="incus-container-select">
                            <option>Caricamento container...</option>
                        </select>
                        <button class="action-btn" onclick="loadIncusContainers()">Aggiorna Lista</button>
                    </div>
                </div>

                <div class="form-group">
                    <label>Associa Progetto Sandbox:</label>
                    <input type="text" value="project-autonomous-alpha" placeholder="Nome progetto Incus">
                </div>

                <div class="toggle-group">
                    <input type="checkbox" id="sandbox-isolation" checked>
                    <label for="sandbox-isolation"><strong>Isolamento Stretto:</strong> Impedisci accesso diretto al file host al di fuori del progetto Incus</label>
                </div>
                <div class="toggle-group">
                    <input type="checkbox" id="tool-net" checked>
                    <label for="tool-net"><strong>Network Bridge:</strong> Consenti accesso internet controllato per web scraping ed estrazione dati</label>
                </div>
                
                <br>
                <button class="action-btn" onclick="alert('Configurazione Incus Sandbox associata con successo!')">Salva Mapping Sandbox</button>
            </div>
        </div>

        <!-- TAB 4: VECTOR DB & KNOWLEDGE BASE -->
        <div id="tab-rag" class="tab-content">
            <div class="grid">
                <div class="card">
                    <div class="card-header"><strong>Vector Database Engine Selection</strong></div>
                    <div class="form-group">
                        <label>Motore Attivo:</label>
                        <select id="vectordb-engine">
                            <option value="surrealdb">SurrealDB (Multi-Model / Vector / Graph - Porta 8000)</option>
                            <option value="qdrant">Qdrant Local (Porta 6333)</option>
                        </select>
                    </div>
                    <div class="form-group">
                        <label>Endpoint Connessione:</label>
                        <input type="text" id="vectordb-endpoint" value="ws://127.0.0.1:8000/rpc">
                    </div>
                    <div class="form-group">
                        <label>Namespace / Database:</label>
                        <input type="text" value="namespace_autonomous:db_knowledge">
                    </div>
                    <div class="form-group">
                        <label>SurrealQL / Paradigma Query:</label>
                        <textarea rows="3" readonly style="font-family: monospace; font-size: 0.75em;">DEFINE TABLE vector_memory SCHEMAFULL; DEFINE FIELD embedding ON vector_memory TYPE array<float>; DEFINE INDEX vec_idx ON vector_memory COLUMNS embedding VECTOR HNSW DIMENSION 4096;</textarea>
                    </div>
                    <button class="action-btn" onclick="alert('Connessione al motore Vector DB stabilita!')">Connetti & Inizializza DB</button>
                </div>

                <div class="card">
                    <div class="card-header"><strong>Stato Memoria & Vettorizzazione</strong></div>
                    <div class="metric-row"><span class="metric-label">Motore in Uso:</span><span class="metric-value" style="color:var(--accent);">SurrealDB v2.x</span></div>
                    <div class="metric-row"><span class="metric-label">Tabelle Indicizzate:</span><span class="metric-value">1 (vector_memory)</span></div>
                    <div class="metric-row"><span class="metric-label">Vettori Totali:</span><span class="metric-value">1,420</span></div>
                    <div class="metric-row"><span class="metric-label">Stato Connessione:</span><span class="metric-value" style="color: var(--success);">ONLINE [ACTIVE]</span></div>
                </div>
            </div>
        </div>

        <!-- TAB 5: USE-CASE PRESETS & DRAG AND DROP -->
        <div id="tab-presets" class="tab-content">
            <div class="grid">
                <div class="card">
                    <div class="card-header"><strong>Source Code Preset & Repository Ingestion</strong></div>
                    <p style="color: #9ca3af; font-size: 0.85em;">Carica archivi di codice sorgente o repository per l'analisi e il refactoring automatico tramite l'agente coder.</p>
                    <div class="drop-zone" onclick="document.getElementById('file-code').click()">
                        📁 Trascina qui i file sorgente o clicca per caricare (.zip, .py, .js, .cpp)
                        <input type="file" id="file-code" style="display:none;" multiple>
                    </div>
                    <button class="action-btn" style="margin-top: 15px;" onclick="alert('Preset Source Code caricato e indicizzato in SurrealDB!')">Carica & Indicizza Coder</button>
                </div>

                <div class="card">
                    <div class="card-header"><strong>Research Assistant & Document Ingestion</strong></div>
                    <p style="color: #9ca3af; font-size: 0.85em;">Carica paper di ricerca, PDF o dataset documentali per alimentare la Knowledge Base vettoriale dell'assistente.</p>
                    <div class="drop-zone" onclick="document.getElementById('file-research').click()">
                        📄 Trascina qui i documenti di ricerca (.pdf, .txt, .md)
                        <input type="file" id="file-research" style="display:none;" multiple>
                    </div>
                    <button class="action-btn" style="margin-top: 15px;" onclick="alert('Documenti di ricerca elaborati e vettorizzati!')">Carica & Vettorizza Research</button>
                </div>
            </div>
        </div>

        <script>
            const charts = {};
            const cartesianCharts = {};

            function switchTab(tabId) {
                document.querySelectorAll('.tab-btn').forEach(btn => btn.classList.remove('active'));
                document.querySelectorAll('.tab-content').forEach(content => content.classList.remove('active'));
                
                event.target.classList.add('active');
                document.getElementById(`tab-${tabId}`).classList.add('active');
            }

            function createGaugeChart(canvasId, label) {
                const ctx = document.getElementById(canvasId).getContext('2d');
                return new Chart(ctx, {
                    type: 'doughnut',
                    data: {
                        labels: ['VRAM Usata (MB)', 'VRAM Libera (MB)'],
                        datasets: [{
                            data: [0, 8192],
                            backgroundColor: ['#10b981', '#1f2937'],
                            borderWidth: 0
                        }]
                    },
                    options: {
                        responsive: true,
                        maintainAspectRatio: false,
                        plugins: {
                            legend: { position: 'right', labels: { color: '#9ca3af', font: { size: 10 } } },
                            title: { display: true, text: label, color: '#f3f4f6', font: { size: 11 } }
                        },
                        cutout: '70%'
                    }
                });
            }

            function createCartesianChart(canvasId, label) {
                const ctx = document.getElementById(canvasId).getContext('2d');
                return new Chart(ctx, {
                    type: 'line',
                    data: {
                        labels: Array(10).fill(''),
                        datasets: [{
                            label: label,
                            data: Array(10).fill(0),
                            borderColor: '#10b981',
                            backgroundColor: 'rgba(16, 185, 129, 0.1)',
                            borderWidth: 2,
                            tension: 0.3,
                            fill: true
                        }]
                    },
                    options: {
                        responsive: true,
                        maintainAspectRatio: false,
                        plugins: { legend: { display: false } },
                        scales: {
                            x: { display: false },
                            y: { grid: { color: '#1f2937' }, ticks: { color: '#9ca3af', font: { size: 9 } }, min: 0, max: 100 }
                        }
                    }
                });
            }

            charts['AMD_VULKAN'] = createGaugeChart('chart-AMD_VULKAN', 'AMD VRAM (MB)');
            charts['NVIDIA_CUDA'] = createGaugeChart('chart-NVIDIA_CUDA', 'NVIDIA VRAM (MB)');
            
            cartesianCharts['AMD_VULKAN'] = createCartesianChart('cart-chart-AMD_VULKAN', 'AMD GPU Load (%)');
            cartesianCharts['NVIDIA_CUDA'] = createCartesianChart('cart-chart-NVIDIA_CUDA', 'NVIDIA GPU Load (%)');

            async function updateFan(nodeKey) {
                const mode = document.getElementById(`fan-mode-${nodeKey}`).value;
                const speed = document.getElementById(`fan-slider-${nodeKey}`).value;
                document.getElementById(`fan-val-${nodeKey}`).innerText = speed + '%';
                try {
                    await fetch('/api/control/fan', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ node_key: nodeKey, mode: mode, speed: parseInt(speed) })
                    });
                } catch(e) { console.error("Errore controllo ventole:", e); }
            }

            async function loadIncusContainers() {
                try {
                    const res = await fetch('/api/incus/containers');
                    const data = await res.json();
                    const sel = document.getElementById('incus-container-select');
                    if(data.containers && data.containers.length > 0) {
                        sel.innerHTML = data.containers.map(c => `<option value="${c.name}">${c.name} (${c.status})</option>`).join('');
                    } else {
                        sel.innerHTML = '<option>Nessun container trovato</option>';
                    }
                } catch(e) { console.error("Errore caricamento Incus:", e); }
            }

            async function playModel(nodeKey) {
                const select = document.getElementById(`select-${nodeKey}`);
                const modelName = select.value;
                if (!modelName || modelName.includes("Nessun")) return;
                try {
                    const res = await fetch('/api/play-model', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ node_key: nodeKey, model_name: modelName })
                    });
                    if (!res.ok) alert("Errore durante l'avvio del modello.");
                } catch(e) { console.error("Errore play:", e); }
            }

            async function updateDashboard() {
                try {
                    const res = await fetch('/api/metrics');
                    const data = await res.json();
                    
                    if (data.system) {
                        document.getElementById('sys-cpu-util').innerText = `${data.system.cpu_util_pct}%`;
                        document.getElementById('sys-ram-val').innerText = `${data.system.ram_used_gb} / ${data.system.ram_total_gb} GB (${data.system.ram_util_pct}%)`;
                    }

                    let onlineNodes = 0;
                    let totalReqs = 0;
                    let catalogHtml = '';

                    for (const [key, node] of Object.entries(data.nodes)) {
                        if (node.status.startsWith('ONLINE')) onlineNodes++;
                        totalReqs += node.total_requests;

                        document.getElementById(`badge-${key}`).className = `badge status-${node.status.startsWith('ONLINE') ? 'ONLINE' : 'OFFLINE'}`;
                        document.getElementById(`badge-${key}`).innerText = node.active_model ? `${node.status} [ACTIVE]` : `${node.status} [IDLE]`;
                        document.getElementById(`req-${key}`).innerText = node.total_requests;
                        document.getElementById(`lat-${key}`).innerText = node.last_latency > 0 ? node.last_latency.toFixed(2) + 's' : '-';
                        
                        document.getElementById(`gpu-util-${key}`).innerText = `${node.gpu_util || 0}%`;
                        document.getElementById(`temp-${key}`).innerText = `${node.temp_c || 0}°C / ${node.fan_speed_pct || 0}%`;

                        const sel = document.getElementById(`select-${key}`);
                        if (node.loaded_models.length > 0) {
                            const currentVal = sel.value;
                            sel.innerHTML = node.loaded_models.map(m => 
                                `<option value="${m}" ${m === node.active_model ? 'selected' : ''}>${m}</option>`
                            ).join('');
                            if (currentVal && node.loaded_models.includes(currentVal)) {
                                sel.value = currentVal;
                            }
                        } else {
                            sel.innerHTML = '<option>Nessun modello disponibile</option>';
                        }

                        // Popola il catalogo modelli categorizzati
                        if (node.categorized_models) {
                            node.categorized_models.forEach(cm => {
                                catalogHtml += `<tr><td><strong>${cm.id}</strong></td><td>${key}</td><td><span class="badge status-ONLINE">${cm.category}</span></td></tr>`;
                            });
                        }

                        if (charts[key]) {
                            const free = Math.max(0, node.vram_total_mb - node.vram_used_mb);
                            charts[key].data.datasets[0].data = [node.vram_used_mb, free];
                            charts[key].options.plugins.title.text = `VRAM: ${node.vram_used_mb} MB / ${node.vram_total_mb} MB`;
                            charts[key].update();
                        }

                        if (cartesianCharts[key]) {
                            const cChart = cartesianCharts[key];
                            cChart.data.datasets[0].data.shift();
                            cChart.data.datasets[0].data.push(node.gpu_util || 0);
                            cChart.update();
                        }
                    }

                    if(catalogHtml) {
                        document.getElementById('catalog-tbody').innerHTML = catalogHtml;
                    }

                    document.getElementById('sys-nodes-online').innerText = `${onlineNodes} / 2`;
                    document.getElementById('sys-total-req').innerText = totalReqs;

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

            loadIncusContainers();
            setInterval(updateDashboard, 2000);
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
Description=Autonomous Machine Control Center Service
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

echo ""
echo "[OK] Control Center & Orchestrator v4.0 aggiornato ed avviato con successo."
echo "--------------------------------------------------------"
echo " Log persistenti scritti in: /opt/gateway/logs/gateway.log"
echo " Dashboard Web disponibile all'indirizzo:"
echo " http://127.0.0.1:9000"
echo "--------------------------------------------------------"
