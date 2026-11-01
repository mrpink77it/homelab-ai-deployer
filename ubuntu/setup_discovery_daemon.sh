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

echo "[*] Configurazione del demone di auto-discovery (Porte 8000-8500) in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

cat << 'EOF' > "$SCRIPT_PATH"
#!/usr/bin/env python3
import asyncio
import httpx
import json
import socket
import psutil

# Range completo richiesto: da 8000 a 8500
PORT_RANGE = list(range(8000, 8501))
AUTO_MANIFEST_PATH = "/opt/gateway/cluster-topology.json"

def get_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        IP = s.getsockname()[0]
    except Exception:
        IP = "127.0.0.1"
    finally:
        s.close()
    return IP

async def probe_endpoint(ip: str, port: int):
    url_models = f"http://{ip}:{port}/v1/models"
    url_props = f"http://{ip}:{port}/props"
    try:
        async with httpx.AsyncClient(timeout=1.0) as client:
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

                backend_type = "llama-server (CUDA/CPU)"
                try:
                    resp_props = await client.get(url_props)
                    if resp_props.status_code == 200:
                        props = resp_props.json()
                        if "cuda" in str(props).lower():
                            backend_type = "CUDA (NVIDIA)"
                        elif "vulkan" in str(props).lower():
                            backend_type = "Vulkan (Mixed/GPU)"
                        else:
                            backend_type = "CPU / OpenBLAS"
                except Exception:
                    pass
                
                mem = psutil.virtual_memory()
                hardware_metrics = {
                    "cpu_util_pct": psutil.cpu_percent(interval=None),
                    "ram_used_gb": round(mem.used / (1024**3), 2),
                    "ram_total_gb": round(mem.total / (1024**3), 2),
                    "ram_util_pct": mem.percent
                }

                print(f"[OK] Rilevato backend attivo su {ip}:{port} ({backend_type})")
                return {
                    "host": ip,
                    "port": port,
                    "status": "ONLINE",
                    "models": models,
                    "backend_type": backend_type,
                    "hardware": hardware_metrics
                }
    except Exception:
        pass
    return None

async def scan_cluster():
    local_ip = get_local_ip()
    ips = ["127.0.0.1", local_ip]
    if local_ip != "127.0.0.1":
        ips = list(set(ips))

    tasks = []
    for ip in ips:
        for port in PORT_RANGE:
            tasks.append(probe_endpoint(ip, port))
            
    results = await asyncio.gather(*tasks)
    
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
                    "hardware": res["hardware"]
                })
            
    topology = {
        "cluster_version": "2.2.0",
        "nodes": list(nodes_map.values())
    }
    
    with open(AUTO_MANIFEST_PATH, "w") as f:
        json.dump(topology, f, indent=4)
    print(f"[*] Topologia salvata in {AUTO_MANIFEST_PATH}. Nodi totali mappati: {len(nodes_map)}")

if __name__ == "__main__":
    asyncio.run(scan_cluster())
EOF

chmod +x "$SCRIPT_PATH"
chown "$CURRENT_USER:$CURRENT_USER" "$SCRIPT_PATH"

cat << EOF > "$SERVICE_FILE"
[Unit]
Description=LLM Cluster Auto-Discovery Worker (Porte 8000-8500)
After=network.target

[Service]
Type=oneshot
User=$CURRENT_USER
ExecStart=$INSTALL_DIR/venv/bin/python $SCRIPT_PATH
EOF

cat << EOF > "$TIMER_FILE"
[Unit]
Description=Run LLM Cluster Auto-Discovery periodically (Porte 8000-8500)

[Timer]
OnBootSec=5sec
OnUnitActiveSec=2min
Unit=cluster-discovery.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now cluster-discovery.timer

echo "[OK] Demone di Auto-Discovery (8000-8500) installato e attivato con successo!"
