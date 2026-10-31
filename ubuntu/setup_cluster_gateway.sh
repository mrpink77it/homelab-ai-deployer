#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/gateway"
CONFIG_FILE="$INSTALL_DIR/cluster-topology.json"
SERVICE_FILE="/etc/systemd/system/llm-gateway.service"
CURRENT_USER="${SUDO_USER:-root}"

echo "[*] Configurazione directory gateway in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/logs"

# 1. Scrittura dello script di Auto-Discovery e Generazione Manifesto
cat << 'EOF' > "$INSTALL_DIR/discovery.py"
import asyncio
import httpx
import json
import socket
import os

SUBNET_PREFIX = "192.168.1."  # Personalizzabile o autorilevato
PORT_RANGE = range(8001, 8020)
MANIFEST_PATH = "/opt/gateway/cluster-topology.json"

async def probe_endpoint(ip: str, port: int):
    url = f"http://{ip}:{port}/v1/models"
    try:
        async with httpx.AsyncClient(timeout=1.0) as client:
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

async def scan_network():
    print("[*] Avvio scansione subnet per nodi llama.cpp / OpenAPI...")
    active_nodes = []
    
    # Genera IPs locali da scandire (es. da .1 a .254)
    ips = [f"{SUBNET_PREFIX}{i}" for i in range(1, 255)]
    ips.append("127.0.0.1") # Includi sempre localhost
    
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
        "cluster_version": "2.0.0",
        "nodes": list(nodes_map.values())
    }
    
    with open(MANIFEST_PATH, "w") as f:
        json.dump(topology, f, indent=4)
    print(f"[OK] Manifesto cluster aggiornato in {MANIFEST_PATH} ({len(nodes_map)} host trovati).")

if __name__ == "__main__":
    asyncio.run(scan_network())
EOF

# 2. Scrittura del Gateway Principale con caricamento dinamico del manifesto
cat << 'EOF' > "$INSTALL_DIR/llm_gateway.py"
#!/usr/bin/env python3
import time
import asyncio
import os
import json
from typing import Dict, Any, Optional, List
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
import httpx
from pydantic import BaseModel

app = FastAPI(title="Distributed LLM Network Gateway", version="6.0.0")
MANIFEST_PATH = "/opt/gateway/cluster-topology.json"

def load_topology() -> Dict[str, Any]:
    if os.path.exists(MANIFEST_PATH):
        try:
            with open(MANIFEST_PATH, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return {"cluster_version": "2.0.0", "nodes": []}

class GatewayChatRequest(BaseModel):
    model: Optional[str] = None
    messages: List[Dict[str, str]]
    temperature: Optional[float] = 0.2
    stream: Optional[bool] = False

@app.get("/api/topology")
async def get_topology():
    return load_topology()

@app.post("/v1/chat/completions")
async def proxy_chat(req: GatewayChatRequest):
    topology = load_topology()
    nodes = topology.get("nodes", [])
    
    target_backend = None
    # Logica di routing dinamico basata sul primo backend disponibile con il modello richiesto o attivo
    for node in nodes:
        for backend in node.get("backends", []):
            if not req.model or req.model in backend.get("models_loaded", []):
                target_backend = {
                    "host": node["host"],
                    "port": backend["port"]
                }
                break
        if target_backend:
            break
            
    if not target_backend:
        # Fallback sul primo backend disponibile in assoluto nella rete
        for node in nodes:
            if node.get("backends"):
                b = node["backends"][0]
                target_backend = {"host": node["host"], "port": b["port"]}
                break
                
    if not target_backend:
        raise HTTPException(status_code=503, detail="Nessun nodo di calcolo disponibile nella rete distribuita.")
        
    url = f"http://{target_backend['host']}:{target_backend['port']}/v1/chat/completions"
    
    async with httpx.AsyncClient(timeout=120.0) as client:
        try:
            resp = await client.post(url, json=req.dict())
            return JSONResponse(status_code=resp.status_code, content=resp.json())
        except Exception as e:
            raise HTTPException(status_code=502, detail=fupstream error: {str(e)}")

@app.get("/", response_class=HTMLResponse)
async def dashboard():
    topo = load_topology()
    return f"""
    <html>
    <head><title>Distributed LLM Gateway</title></head>
    <body style="font-family:sans-serif; background:#090d16; color:#f3f4f6; padding:20px;">
        <h1>Distributed LLM Mesh Gateway</h1>
        <p>Stato Manifesto Cluster caricato da <code>cluster-topology.json</code>:</p>
        <pre style="background:#111827; padding:15px; border-radius:8px;">{json.dumps(topo, indent=4)}</pre>
    </body>
    </html>
    """

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=9000)
EOF

# Creazione ambiente virtuale e dipendenze
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install fastapi uvicorn httpx pydantic

chown -R "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/llm_gateway.py" "$INSTALL_DIR/discovery.py"

# Configurazione Servizio Systemd per il Gateway
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Distributed LLM Mesh Gateway
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/llm_gateway.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable llm-gateway.service
systemctl restart llm-gateway.service

echo ""
echo "[OK] Setup Gateway distribuito completato con successo!"
echo " Esegui la scansione di rete con: sudo python3 $INSTALL_DIR/discovery.py"
echo " Dashboard Gateway attiva su: http://127.0.0.1:9000"
