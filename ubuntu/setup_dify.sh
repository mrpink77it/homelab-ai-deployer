#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/dify"
CURRENT_USER="${SUDO_USER:-root}"

echo "=== [1/6] Pulizia vecchi container, volumi e directory Dify ==="
if [ -d "$INSTALL_DIR" ]; then
    cd "$INSTALL_DIR"
    # Arresta i container e rimuove i volumi corrotti (-v) per evitare errori di permessi
    docker compose down -v --remove-orphans 2>/dev/null || true
    cd /opt
    rm -rf "$INSTALL_DIR"
    echo "[*] Vecchia installazione rimossa con successo."
fi

echo "=== [2/6] Verifica di Docker e Docker Compose ==="
if ! command -v docker &> /dev/null; then
    echo "[*] Installazione di Docker..."
    apt-get update && apt-get install -y docker.io docker-compose-v2
    systemctl enable --now docker
fi

echo "=== [3/6] Creazione directory pulita in $INSTALL_DIR ==="
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "=== [4/6] Download delle configurazioni ufficiali di Dify ==="
curl -s https://raw.githubusercontent.com/langgenius/dify/main/docker/docker-compose.yaml -o "$INSTALL_DIR/docker-compose.yml"
curl -s https://raw.githubusercontent.com/langgenius/dify/main/docker/.env.example -o "$INSTALL_DIR/.env"

# Impostazione della porta Nginx su 9111
if grep -q "EXPOSE_NGINX_PORT=" "$INSTALL_DIR/.env"; then
    sed -i 's/^EXPOSE_NGINX_PORT=.*/EXPOSE_NGINX_PORT=9111/' "$INSTALL_DIR/.env"
else
    echo "EXPOSE_NGINX_PORT=9111" >> "$INSTALL_DIR/.env"
fi

echo "=== [5/6] Configurazione routing locale (porta 9000) ==="
python3 -c '
import yaml

compose_path = "/opt/dify/docker-compose.yml"
with open(compose_path, "r") as f:
    data = yaml.safe_load(f)

for service_name in ["api", "worker"]:
    if service_name in data.get("services", {}):
        if "extra_hosts" not in data["services"][service_name]:
            data["services"][service_name]["extra_hosts"] = []
        if "host.docker.internal:host-gateway" not in data["services"][service_name]["extra_hosts"]:
            data["services"][service_name]["extra_hosts"].append("host.docker.internal:host-gateway")

with open(compose_path, "w") as f:
    yaml.safe_dump(data, f, sort_keys=False)
'

chown -R "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR"

echo "=== [6/6] Avvio pulito dei container Dify sulla porta 9111 ==="
cd "$INSTALL_DIR"
docker compose up -d

echo "================================================================="
echo "[OK] Dify installato e avviato da zero con successo!"
echo " 🌐 Interfaccia Web Dify: http://127.0.0.1:9111"
echo " 🔌 Base URL per i modelli: http://host.docker.internal:9000/v1"
echo "================================================================="
