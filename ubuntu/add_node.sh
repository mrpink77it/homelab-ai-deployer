#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo."
  exit 1
fi

STATIC_FILE="/opt/gateway/cluster-static-nodes.json"
mkdir -p /opt/gateway

# Inizializza il file JSON se non esiste
if [ ! -f "$STATIC_FILE" ]; then
    echo '{"nodes": []}' > "$STATIC_FILE"
fi

action="${1:-}"
node_id="${2:-}"
host="${3:-}"
port="${4:-8001}"

usage() {
    echo "Uso:"
    echo "  sudo ./add_node.sh add <node_id> <ip_address> <port>   (Aggiunge o aggiorna un nodo manuale)"
    echo "  sudo ./add_node.sh remove <node_id>                    (Rimuove un nodo manuale)"
    echo "  sudo ./add_node.sh list                                (Elenca i nodi manuali)"
    exit 1
}

if [ "$action" = "list" ]; then
    echo "=== Nodi Statici Manuali ==="
    cat "$STATIC_FILE"
    exit 0
fi

if [ "$action" = "add" ]; then
    if [ -z "$node_id" ] || [ -z "$host" ]; then
        echo "[-] Errore: Specificare node_id e host IP."
        usage
    fi

    python3 -c '
import json, sys
path, nid, host, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
try:
    with open(path, "r") as f:
        data = json.load(f)
except Exception:
    data = {"nodes": []}

# Rimuovi se esiste già per evitar duplicati
data["nodes"] = [n for n in data["nodes"] if n["node_id"] != nid]

# Aggiungi nuovo nodo
data["nodes"].append({
    "node_id": nid,
    "host": host,
    "backends": [{"port": port, "status": "MANUAL_STATIC"}]
})

with open(path, "w") as f:
    json.dump(data, f, indent=4)
print(f"[OK] Nodo statico {nid} ({host}:{port}) aggiunto con successo.")
' "$STATIC_FILE" "$node_id" "$host" "$port"

elif [ "$action" = "remove" ]; then
    if [ -z "$node_id" ]; then
        echo "[-] Errore: Specificare il node_id da rimuovere."
        usage
    fi
    python3 -c '
import json, sys
path, nid = sys.argv[1], sys.argv[2]
with open(path, "r") as f:
    data = json.load(f)
data["nodes"] = [n for n in data["nodes"] if n["node_id"] != nid]
with open(path, "w") as f:
    json.dump(data, f, indent=4)
print(f"[OK] Nodo {nid} rimosso.")
' "$STATIC_FILE" "$node_id"
else
    usage
fi
