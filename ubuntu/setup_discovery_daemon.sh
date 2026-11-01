#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/gateway"
SCRIPT_PATH="$INSTALL_DIR/discovery.py"
SERVICE_FILE="/etc/systemd/system/cluster-discovery.service"
TIMER_FILE="/etc/systemd/system/cluster-discovery.timer"
CURRENT_USER="${SUDO_USER:-root}"

echo "[*] Configurazione del demone di auto-discovery in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

cat << 'EOF' > "$SCRIPT_PATH"
#!/usr/bin/env python3
import asyncio
import httpx
import json
import socket

PORT_RANGE = range(8000, 8025)
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
    url = f"http://{ip}:{port}/v1/models"
    try:
        async with httpx.AsyncClient(timeout=0.8) as client:
            resp = await client.get(url)
            if resp.status_code == 200:
                data = resp.json()
                models = [m.get("id") for m in data.get("data", [])]
                return {
                    "host": ip,
                    "port": port,
                    "status": "ONLINE",
                    "models": models
                }
    except Exception:
        pass
    return None

async def scan_subnet():
    local_ip = get_local_ip()
    subnet_prefix = ".".join(local_ip.split(".")[:3]) + "."
    
    ips = [f"{subnet_prefix}{i}" for i in range(1, 255)]
    if "127.0.0.1" not in ips:
        ips.append("127.0.0.1")
        
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
            nodes_map[host]["backends"].append({
                "port": res["port"],
                "models_loaded": res["models"],
                "status": res["status"]
            })
            
    topology = {
        "cluster_version": "2.2.0",
        "nodes": list(nodes_map.values())
    }
    
    with open(AUTO_MANIFEST_PATH, "w") as f:
        json.dump(topology, f, indent=4)

if __name__ == "__main__":
    asyncio.run(scan_subnet())
EOF

chmod +x "$SCRIPT_PATH"
chown "$CURRENT_USER:$CURRENT_USER" "$SCRIPT_PATH"

cat << EOF > "$SERVICE_FILE"
[Unit]
Description=LLM Cluster Auto-Discovery Worker
After=network.target

[Service]
Type=oneshot
User=$CURRENT_USER
ExecStart=$INSTALL_DIR/venv/bin/python $SCRIPT_PATH
EOF

cat << EOF > "$TIMER_FILE"
[Unit]
Description=Run LLM Cluster Auto-Discovery periodically

[Timer]
OnBootSec=10sec
OnUnitActiveSec=2min
Unit=cluster-discovery.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now cluster-discovery.timer

echo "[OK] Demone di Auto-Discovery installato e avviato con successo!"
