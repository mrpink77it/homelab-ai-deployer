#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/gateway"
SCRIPT_PATH="$INSTALL_DIR/discovery.py"
SERVICE_FILE="/etc/systemd/system/cluster-discovery.service"
TIMER_FILE="/etc/systemd/system/cluster-discovery.timer"
CURRENT_USER="${SUDO_USER:-root}"

echo "[*] Configurazione demone discovery con ispezione OpenAPI in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

cat << 'EOF' > "$SCRIPT_PATH"
#!/usr/bin/env python3
import asyncio
import httpx
import json
import psutil

AUTO_MANIFEST_PATH = "/opt/gateway/cluster-topology.json"

def inspect_process_for_port(port: int):
    """Ispeziona la riga di comando e i binari in esecuzione per estrarre standard, ngl, ctx e cache."""
    info = {
        "pid": None,
        "backend_type": "CPU / OpenBLAS",
        "ngl": "Auto",
        "ctx_size": "Default",
        "cache_type": "default"
    }
    try:
        for proc in psutil.process_iter(['pid', 'name', 'cmdline', 'connections']):
            try:
                cmdline = proc.info.get('cmdline') or []
                if not any("llama-server" in str(c) for c in cmdline):
                    continue
                
                match_port = False
                for conn in proc.info.get('connections') or []:
                    if conn.laddr.port == port:
                        match_port = True
                        break
                
                if match_port:
                    info["pid"] = proc.info['pid']
                    cmd_str = " ".join(cmdline).lower()
                    
                    # Rilevamento Backend / Standard di calcolo
                    if "cuda" in cmd_str or "llama-cpp-cuda" in cmd_str:
                        info["backend_type"] = "CUDA (NVIDIA)"
                    elif "vulkan" in cmd_str:
                        info["backend_type"] = "Vulkan (GPU)"
                    elif "rocm" in cmd_str:
                        info["backend_type"] = "ROCm (AMD)"
                    elif "-ngl 0" in cmd_str or "--n-gpu-layers 0" in cmd_str:
                        info["backend_type"] = "CPU (Pure)"
                    else:
                        info["backend_type"] = "CUDA / GPU Offload"

                    # Estrazione -ngl
                    if "-ngl" in cmdline:
                        idx = cmdline.index("-ngl")
                        if idx + 1 < len(cmdline):
                            info["ngl"] = cmdline[idx + 1]
                    elif "--n-gpu-layers" in cmd_str:
                        for c in cmdline:
                            if "--n-gpu-layers" in c and "=" in c:
                                info["ngl"] = c.split("=")[1]

                    # Estrazione --ctx-size
                    if "--ctx-size" in cmdline:
                        idx = cmdline.index("--ctx-size")
                        if idx + 1 < len(cmdline):
                            info["ctx_size"] = cmdline[idx + 1]

                    # Estrazione tipo cache
                    if "--cache-type-k" in cmdline:
                        idx = cmdline.index("--cache-type-k")
                        if idx + 1 < len(cmdline):
                            info["cache_type"] = f"K:{cmdline[idx+1]}"
                    break
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
    except Exception:
        pass
    return info

async def probe_endpoint(ip: str, port: int):
    url_models = f"http://{ip}:{port}/v1/models"
    try:
        async with httpx.AsyncClient(timeout=1.5) as client:
            resp_models = await client.get(url_models)
            if resp_models.status_code == 200:
                models = []
                try:
                    data = resp_models.json()
                    models = [m.get("id") for m in data.get("data", [])]
                except Exception:
                    pass
                
                if not models:
                    models = ["dynamic-models-dir"]

                # Ispezione avanzata dei parametri OpenAPI e binari
                proc_info = inspect_process_for_port(port)
                
                mem = psutil.virtual_memory()
                hardware_metrics = {
                    "cpu_util_pct": psutil.cpu_percent(interval=None),
                    "ram_used_gb": round(mem.used / (1024**3), 2),
                    "ram_total_gb": round(mem.total / (1024**3), 2),
                    "ram_util_pct": mem.percent
                }

                return {
                    "host": ip,
                    "port": port,
                    "status": "ONLINE",
                    "models": models,
                    "backend_type": proc_info["backend_type"],
                    "pid": proc_info["pid"],
                    "ngl": proc_info["ngl"],
                    "ctx_size": proc_info["ctx_size"],
                    "cache_type": proc_info["cache_type"],
                    "hardware": hardware_metrics
                }
    except Exception:
        pass
    return None

async def scan_cluster():
    targets = set()
    for conn in psutil.net_connections(kind='inet'):
        if conn.status == psutil.CONN_LISTEN:
            ip, port = conn.laddr.ip, conn.laddr.port
            if 8000 <= port <= 8500:
                probe_ip = "127.0.0.1" if ip in ("0.0.0.0", "::") else ip
                targets.add((probe_ip, port))

    tasks = [probe_endpoint(ip, port) for ip, port in targets]
    results = await asyncio.gather(*tasks) if tasks else []
    
    nodes_map = {}
    for res in results:
        if res:
            host = res["host"]
            if host not in nodes_map:
                nodes_map[host] = {
                    "node_id": f"node-{host.replace('.', '-')}",
                    "host": host,
                    "backends": []
                }
            existing_ports = [b["port"] for b in nodes_map[host]["backends"]]
            if res["port"] not in existing_ports:
                nodes_map[host]["backends"].append({
                    "port": res["port"],
                    "models_loaded": res["models"],
                    "status": res["status"],
                    "backend_type": res["backend_type"],
                    "pid": res["pid"],
                    "ngl": res["ngl"],
                    "ctx_size": res["ctx_size"],
                    "cache_type": res["cache_type"],
                    "hardware": res["hardware"]
                })
            
    topology = {
        "cluster_version": "2.6.0",
        "nodes": list(nodes_map.values())
    }
    
    with open(AUTO_MANIFEST_PATH, "w") as f:
        json.dump(topology, f, indent=4)

if __name__ == "__main__":
    asyncio.run(scan_cluster())
EOF

chmod +x "$SCRIPT_PATH"
chown "$CURRENT_USER:$CURRENT_USER" "$SCRIPT_PATH"

cat << EOF > "$SERVICE_FILE"
[Unit]
Description=LLM Cluster Smart Auto-Discovery Worker
After=network.target

[Service]
Type=oneshot
User=$CURRENT_USER
ExecStart=$INSTALL_DIR/venv/bin/python $SCRIPT_PATH
EOF

cat << EOF > "$TIMER_FILE"
[Unit]
Description=Run LLM Cluster Smart Auto-Discovery periodically

[Timer]
OnBootSec=5sec
OnUnitActiveSec=1min
Unit=cluster-discovery.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now cluster-discovery.timer

echo "[OK] Demone discovery con ispezione OpenAPI installato!"
