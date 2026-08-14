#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Unified Hardware & VRAM Dashboard (monitor.sh)
# Compatible with: Baremetal & Proxmox LXC | NVIDIA & AMD (ROCm / Vulkan)
# ==============================================================================

set -e

INSTALL_DIR="/opt/homelab-monitor"
VENV_DIR="${INSTALL_DIR}/env"
SERVICE_NAME="homelab-monitor.service"
PORT=8050

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Homelab AI Deployer - Monitor Setup ===${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Errore: Esegui lo script come root (sudo ./monitor.sh)${NC}"
  exit 1
fi

# 1. Install System Dependencies
echo -e "${YELLOW}[1/4] Installazione dipendenze di sistema...${NC}"
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv lm-sensors pciutils > /dev/null

# 2. Setup Dedicated Virtual Environment
echo -e "${YELLOW}[2/4] Configurazione ambiente Python in ${INSTALL_DIR}...${NC}"
mkdir -p "${INSTALL_DIR}"
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --upgrade pip -q
"${VENV_DIR}/bin/pip" install fastapi uvicorn psutil pynvml -q

# 3. Create Monitoring Server Application
echo -e "${YELLOW}[3/4] Generazione server di monitoraggio Python...${NC}"

cat << 'EOF' > "${INSTALL_DIR}/server.py"
import asyncio
import os
import glob
import json
import psutil
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse

app = FastAPI()

# --- Hardware Detection Helpers ---
def is_lxc():
    return os.path.exists('/dev/lxd') or os.path.exists('/dev/lxc') or os.path.exists('/proc/1/environ') and 'container=lxc' in open('/proc/1/environ', 'r', errors='ignore').read()

def get_system_metrics():
    mem = psutil.virtual_memory()
    return {
        "cpu_percent": psutil.cpu_percent(interval=None),
        "ram_used_gb": round(mem.used / (1024**3), 2),
        "ram_total_gb": round(mem.total / (1024**3), 2),
        "ram_percent": mem.percent,
        "is_lxc": is_lxc()
    }

def get_gpu_metrics():
    gpus = []
    
    # 1. Check AMD GPUs via sysfs (Works in LXC and Baremetal)
    amd_cards = glob.glob('/sys/class/drm/card*/device')
    for card in amd_cards:
        try:
            vendor_path = os.path.join(card, 'vendor')
            if os.path.exists(vendor_path):
                with open(vendor_path, 'r') as f:
                    if '0x1002' not in f.read().lower(): # 0x1002 is AMD Vendor ID
                        continue

            gpu_data = {"vendor": "AMD", "name": "AMD Radeon GPU"}
            
            # Name
            product_name_path = os.path.join(card, 'product_name')
            if os.path.exists(product_name_path):
                with open(product_name_path, 'r') as f:
                    gpu_data["name"] = f.read().strip()

            # Busy %
            busy_path = os.path.join(card, 'gpu_busy_percent')
            if os.path.exists(busy_path):
                with open(busy_path, 'r') as f:
                    gpu_data["load_percent"] = int(f.read().strip())
            else:
                gpu_data["load_percent"] = 0

            # VRAM Total & Used
            vram_used_path = os.path.join(card, 'mem_info_vram_used')
            vram_total_path = os.path.join(card, 'mem_info_vram_total')
            
            if os.path.exists(vram_used_path) and os.path.exists(vram_total_path):
                with open(vram_used_path, 'r') as f:
                    gpu_data["vram_used_mb"] = int(int(f.read().strip()) / (1024**2))
                with open(vram_total_path, 'r') as f:
                    gpu_data["vram_total_mb"] = int(int(f.read().strip()) / (1024**2))
            else:
                gpu_data["vram_used_mb"] = 0
                gpu_data["vram_total_mb"] = 0

            # Temperature
            temp_paths = glob.glob(os.path.join(card, 'hwmon/hwmon*/temp1_input'))
            if temp_paths:
                with open(temp_paths[0], 'r') as f:
                    gpu_data["temp_c"] = int(int(f.read().strip()) / 1000)
            else:
                gpu_data["temp_c"] = 0

            gpus.append(gpu_data)
        except Exception:
            pass

    # 2. Check NVIDIA GPUs via PyNVML
    try:
        import pynvml
        pynvml.nvmlInit()
        device_count = pynvml.nvmlDeviceGetCount()
        for i in range(device_count):
            handle = pynvml.nvmlDeviceGetHandleByIndex(i)
            name = pynvml.nvmlDeviceGetName(handle)
            if isinstance(name, bytes):
                name = name.decode('utf-8')
            util = pynvml.nvmlDeviceGetUtilizationRates(handle)
            mem_info = pynvml.nvmlDeviceGetMemoryInfo(handle)
            try:
                temp = pynvml.nvmlDeviceGetTemperature(handle, pynvml.NVML_TEMPERATURE_GPU)
            except Exception:
                temp = 0

            gpus.append({
                "vendor": "NVIDIA",
                "name": name,
                "load_percent": util.gpu,
                "vram_used_mb": int(mem_info.used / (1024**2)),
                "vram_total_mb": int(mem_info.total / (1024**2)),
                "temp_c": temp
            })
    except Exception:
        pass

    return gpus

# --- Dashboard HTML Frontend ---
HTML_LAYOUT = """
<!DOCTYPE html>
<html lang="it">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Homelab AI - Realtime Monitor</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
</head>
<body class="bg-slate-950 text-slate-100 font-sans p-6 min-h-screen">
    <div class="max-w-6xl mx-auto space-y-6">
        <!-- Header -->
        <div class="flex justify-between items-center border-b border-slate-800 pb-4">
            <div>
                <h1 class="text-2xl font-bold text-indigo-400">Homelab AI Monitor</h1>
                <p class="text-xs text-slate-400" id="env-type">Ambiente: Rilevamento in corso...</p>
            </div>
            <div id="status-badge" class="px-3 py-1 text-xs rounded-full bg-yellow-500/20 text-yellow-300 border border-yellow-500/30">
                Connessione in corso...
            </div>
        </div>

        <!-- System Grid -->
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <!-- CPU Card -->
            <div class="bg-slate-900 border border-slate-800 rounded-xl p-4 space-y-2">
                <div class="flex justify-between items-center">
                    <span class="text-sm font-semibold text-slate-400">CPU Load</span>
                    <span id="cpu-text" class="text-lg font-bold text-slate-200">0%</span>
                </div>
                <div class="w-full bg-slate-800 rounded-full h-2.5">
                    <div id="cpu-bar" class="bg-indigo-500 h-2.5 rounded-full duration-300" style="width: 0%"></div>
                </div>
            </div>

            <!-- RAM Card -->
            <div class="bg-slate-900 border border-slate-800 rounded-xl p-4 space-y-2">
                <div class="flex justify-between items-center">
                    <span class="text-sm font-semibold text-slate-400">RAM System</span>
                    <span id="ram-text" class="text-lg font-bold text-slate-200">0 / 0 GB</span>
                </div>
                <div class="w-full bg-slate-800 rounded-full h-2.5">
                    <div id="ram-bar" class="bg-emerald-500 h-2.5 rounded-full duration-300" style="width: 0%"></div>
                </div>
            </div>
        </div>

        <!-- GPU Section Container -->
        <div id="gpu-container" class="space-y-4">
            <!-- Dynamic GPU Cards will be injected here -->
        </div>

        <!-- Realtime Chart -->
        <div class="bg-slate-900 border border-slate-800 rounded-xl p-4">
            <h2 class="text-sm font-semibold text-slate-400 mb-4">VRAM Usage & GPU Load History</h2>
            <div class="h-64">
                <canvas id="realtimeChart"></canvas>
            </div>
        </div>
    </div>

    <script>
        const ws = new WebSocket(`ws://${location.host}/ws`);
        const statusBadge = document.getElementById('status-badge');
        const envType = document.getElementById('env-type');
        const gpuContainer = document.getElementById('gpu-container');

        // Setup Chart.js
        const ctx = document.getElementById('realtimeChart').getContext('2d');
        const chart = new Chart(ctx, {
            type: 'line',
            data: {
                labels: [],
                datasets: [
                    { label: 'GPU Load (%)', borderColor: '#818cf8', data: [], tension: 0.3, fill: false },
                    { label: 'VRAM Usage (%)', borderColor: '#f43f5e', data: [], tension: 0.3, fill: false }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                scales: {
                    x: { grid: { color: '#1e293b' }, ticks: { color: '#64748b' } },
                    y: { min: 0, max: 100, grid: { color: '#1e293b' }, ticks: { color: '#64748b' } }
                },
                plugins: { legend: { labels: { color: '#94a3b8' } } }
            }
        });

        ws.onopen = () => {
            statusBadge.className = "px-3 py-1 text-xs rounded-full bg-emerald-500/20 text-emerald-400 border border-emerald-500/30";
            statusBadge.innerText = "Live WebSocket Active";
        };

        ws.onclose = () => {
            statusBadge.className = "px-3 py-1 text-xs rounded-full bg-rose-500/20 text-rose-400 border border-rose-500/30";
            statusBadge.innerText = "Disconnesso";
        };

        ws.onmessage = (event) => {
            const data = JSON.parse(event.data);
            
            // System Metrics Update
            envType.innerText = `Ambiente: ${data.system.is_lxc ? 'Proxmox LXC Container' : 'Baremetal / Standalone Host'}`;
            document.getElementById('cpu-text').innerText = `${data.system.cpu_percent}%`;
            document.getElementById('cpu-bar').style.width = `${data.system.cpu_percent}%`;
            
            document.getElementById('ram-text').innerText = `${data.system.ram_used_gb} / ${data.system.ram_total_gb} GB`;
            document.getElementById('ram-bar').style.width = `${data.system.ram_percent}%`;

            // GPU Render
            gpuContainer.innerHTML = '';
            let primaryGpuLoad = 0;
            let primaryVramPercent = 0;

            if (data.gpus.length === 0) {
                gpuContainer.innerHTML = `<div class="bg-slate-900 border border-slate-800 rounded-xl p-4 text-center text-slate-500 text-sm">Nessuna GPU rilevata o permessi /dev insufficienti</div>`;
            } else {
                data.gpus.forEach((gpu, idx) => {
                    const vramPercent = gpu.vram_total_mb > 0 ? Math.round((gpu.vram_used_mb / gpu.vram_total_mb) * 100) : 0;
                    if(idx === 0) {
                        primaryGpuLoad = gpu.load_percent;
                        primaryVramPercent = vramPercent;
                    }

                    const card = document.createElement('div');
                    card.className = "bg-slate-900 border border-slate-800 rounded-xl p-4 space-y-3";
                    card.innerHTML = `
                        <div class="flex justify-between items-center">
                            <span class="text-sm font-bold text-slate-200">${gpu.vendor} - ${gpu.name}</span>
                            <span class="text-xs px-2 py-1 bg-slate-800 text-slate-400 rounded">Temp: ${gpu.temp_c}°C</span>
                        </div>
                        <div class="grid grid-cols-2 gap-4">
                            <div>
                                <div class="flex justify-between text-xs text-slate-400 mb-1">
                                    <span>GPU Core Load</span>
                                    <span>${gpu.load_percent}%</span>
                                </div>
                                <div class="w-full bg-slate-800 rounded-full h-2">
                                    <div class="bg-indigo-500 h-2 rounded-full duration-300" style="width: ${gpu.load_percent}%"></div>
                                </div>
                            </div>
                            <div>
                                <div class="flex justify-between text-xs text-slate-400 mb-1">
                                    <span>VRAM Allocata</span>
                                    <span>${gpu.vram_used_mb} / ${gpu.vram_total_mb} MB (${vramPercent}%)</span>
                                </div>
                                <div class="w-full bg-slate-800 rounded-full h-2">
                                    <div class="bg-rose-500 h-2 rounded-full duration-300" style="width: ${vramPercent}%"></div>
                                </div>
                            </div>
                        </div>
                    `;
                    gpuContainer.appendChild(card);
                });
            }

            // Update Chart Data
            const now = new Date().toLocaleTimeString();
            if (chart.data.labels.length > 20) {
                chart.data.labels.shift();
                chart.data.datasets[0].data.shift();
                chart.data.datasets[1].data.shift();
            }
            chart.data.labels.push(now);
            chart.data.datasets[0].data.push(primaryGpuLoad);
            chart.data.datasets[1].data.push(primaryVramPercent);
            chart.update();
        };
    </script>
</body>
</html>
"""

@app.get("/")
async def get():
    return HTMLResponse(HTML_LAYOUT)

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    try:
        while True:
            payload = {
                "system": get_system_metrics(),
                "gpus": get_gpu_metrics()
            }
            await websocket.send_text(json.dumps(payload))
            await asyncio.sleep(1) # Refresh rate: 1s
    except WebSocketDisconnect:
        pass
EOF

# 4. Create and Enable Systemd Service
echo -e "${YELLOW}[4/4] Creazione ed avvio servizio systemd...${NC}"

cat << EOF > "/etc/systemd/system/${SERVICE_NAME}"
[Unit]
Description=Homelab AI Deployer - Hardware Monitoring Dashboard
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${VENV_DIR}/bin/uvicorn server:app --host 0.0.0.0 --port ${PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

# Fetch local IP address
SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "\n${GREEN}=== Monitoraggio Attivato con Successo! ===${NC}"
echo -e "Dashboard raggiungibile all'indirizzo: ${BLUE}http://${SERVER_IP}:${PORT}${NC}"
echo -e "Servizio Systemd: ${YELLOW}systemctl status ${SERVICE_NAME}${NC}\n"
