#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/dify"
CURRENT_USER="${SUDO_USER:-root}"

echo "[*] Verifica di Docker e Docker Compose..."
if ! command -v docker &> /dev/null; then
    echo "[*] Installazione di Docker..."
    apt-get update && apt-get install -y docker.io docker-compose-v2
    systemctl enable --now docker
fi

echo "[*] Creazione directory di installazione in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/docker"
cd "$INSTALL_DIR"

echo "[*] Download del file docker-compose ufficiale di Dify..."
curl -s https://raw.githubusercontent.com/langgenius/dify/main/docker/docker-compose.yaml -o "$INSTALL_DIR/docker-compose.yml"

echo "[*] Generazione del file .env di configurazione..."
if [ ! -f "$INSTALL_DIR/.env" ]; then
    curl -s https://raw.githubusercontent.com/langgenius/dify/main/docker/.env.example -o "$INSTALL_DIR/.env"
    # Personalizziamo chiavi e porte se necessario
    sed -i 's/EXPOSE_NGINX_PORT=80/EXPOSE_NGINX_PORT=8000/g' "$INSTALL_DIR/.env"
fi

# Aggiungiamo extra_hosts ai servizi api e worker per raggiungere il gateway su host.docker.internal (porta 9000)
echo "[*] Aggiornamento del docker-compose.yml per il routing locale verso il Gateway (porta 9000)..."
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

echo "[*] Configurazione permessi..."
chown -R "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR"

echo "[*] Avvio dei container Dify..."
cd "$INSTALL_DIR"
docker compose up -d

echo "================================================================="
echo "[OK] Dify installato e avviato con successo!"
echo " Interfaccia Web Dify: http://127.0.0.1:8000"
echo " Per configurare i modelli nel pannello Dify, punta all'endpoint OpenAI:"
echo " Base URL: http://host.docker.internal:9000/v1"
echo "================================================================="
