#!/usr/bin/env bash
# ==============================================================================
# Script di Installazione Dify con Logging Avanzato e Debug a Video
# ==============================================================================

set -euo pipefail

BASE_DIR="/opt/homelab-ai-deployer"
LOG_DIR="$BASE_DIR/homelab-ai-logs"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/setup_dify_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"

# Funzione di logging duale (schermo + file)
log_action() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "\033[36m$msg\033[0m"
    echo "$msg" >> "$LOG_FILE"
}

log_error() {
    local msg="[ERRORE][$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "\033[31m$msg\033[0m" >&2
    echo "$msg" >> "$LOG_FILE"
}

log_success() {
    local msg="[OK][$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "\033[32m$msg\033[0m"
    echo "$msg" >> "$LOG_FILE"
}

if [ "$EUID" -ne 0 ]; then
    log_error "Questo script deve essere eseguito con sudo o come root."
    exit 1
fi

INSTALL_DIR="/opt/dify"
CURRENT_USER="${SUDO_USER:-root}"

log_action "=== [1/6] Pulizia vecchi container, volumi e directory Dify ==="
if [ -d "$INSTALL_DIR" ]; then
    cd "$INSTALL_DIR"
    log_action "Arresto container esistenti e rimozione volumi corrotti..."
    docker compose down -v --remove-orphans >> "$LOG_FILE" 2>&1 || true
    cd /opt
    rm -rf "$INSTALL_DIR"
    log_success "Vecchia installazione rimossa con successo."
fi

log_action "=== [2/6] Verifica di Docker e Docker Compose ==="
if ! command -v docker &> /dev/null; then
    log_action "Docker non trovato. Installazione in corso..."
    apt-get update -qq && apt-get install -yq docker.io docker-compose-v2 >> "$LOG_FILE" 2>&1
    systemctl enable --now docker >> "$LOG_FILE" 2>&1
    log_success "Docker installato e avviato."
else
    log_success "Docker è già installato."
fi

log_action "=== [3/6] Creazione directory pulita in $INSTALL_DIR ==="
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
log_success "Directory creata in $INSTALL_DIR"

log_action "=== [4/6] Download delle configurazioni ufficiali di Dify ==="
curl -s https://raw.githubusercontent.com/langgenius/dify/main/docker/docker-compose.yaml -o "$INSTALL_DIR/docker-compose.yml"
curl -s https://raw.githubusercontent.com/langgenius/dify/main/docker/.env.example -o "$INSTALL_DIR/.env"

if grep -q "EXPOSE_NGINX_PORT=" "$INSTALL_DIR/.env"; then
    sed -i 's/^EXPOSE_NGINX_PORT=.*/EXPOSE_NGINX_PORT=9111/' "$INSTALL_DIR/.env"
else
    echo "EXPOSE_NGINX_PORT=9111" >> "$INSTALL_DIR/.env"
fi
log_success "File di configurazione generati e porta impostata su 9111."

log_action "=== [5/6] Configurazione routing locale (porta 9000) ==="
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
' >> "$LOG_FILE" 2>&1
log_success "Routing locale configurato con extra_hosts."

chown -R "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR"

log_action "=== [6/6] Avvio pulito dei container Dify sulla porta 9111 ==="
cd "$INSTALL_DIR"
docker compose up -d >> "$LOG_FILE" 2>&1

log_success "Dify installato e avviato con successo!"
echo -e "\033[1;33m-----------------------------------------------------------------\033[0m"
echo -e " 🌐 Interfaccia Web Dify: \033[1;36mhttp://127.0.0.1:9111\033[0m"
echo -e " 🔌 Base URL per i modelli: \033[1;36mhttp://host.docker.internal:9000/v1\033[0m"
echo -e " 📄 File di log salvato in: \033[1;32m$LOG_FILE\033[0m"
echo -e "\033[1;33m-----------------------------------------------------------------\033[0m"
