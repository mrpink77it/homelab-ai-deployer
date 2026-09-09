#!/usr/bin/env bash
set -euo pipefail

ANYTHINGLLM_DIR="/opt/anythingllm-server"
NODE20_DIR="/opt/node20"
SERVICE_FILE="/etc/systemd/system/anythingllm.service"
RUN_USER="${SUDO_USER:-$USER}"

echo "=== [1/7] Pulizia installazioni e servizi precedenti ==="
sudo systemctl stop anythingllm.service 2>/dev/null || true
sudo systemctl disable anythingllm.service 2>/dev/null || true
sudo rm -f "$SERVICE_FILE"
sudo systemctl daemon-reload
sudo rm -rf "$ANYTHINGLLM_DIR"

echo "=== [2/7] Installazione dipendenze di sistema ==="
if command -v pacman &>/dev/null; then
    sudo pacman -Sy --needed --noconfirm git curl tar make gcc python openssl
elif command -v apt-get &>/dev/null; then
    sudo apt-get update && sudo apt-get install -y git curl tar build-essential python3 openssl
fi

echo "=== [3/7] Setup Node.js v20 LTS isolato in $NODE20_DIR ==="
if [ ! -x "$NODE20_DIR/bin/node" ]; then
    sudo mkdir -p "$NODE20_DIR"
    curl -fsSL https://nodejs.org/dist/v20.18.0/node-v20.18.0-linux-x64.tar.xz | sudo tar -xJ --strip-components=1 -C "$NODE20_DIR"
fi

echo "Node attivo: $($NODE20_DIR/bin/node -v)"
echo "NPM attivo:  $($NODE20_DIR/bin/npm -v)"

echo "=== [4/7] Clonazione AnythingLLM in $ANYTHINGLLM_DIR ==="
sudo git clone --depth 1 https://github.com/Mintplex-Labs/anything-llm.git "$ANYTHINGLLM_DIR"
sudo chown -R "$RUN_USER:$RUN_USER" "$ANYTHINGLLM_DIR"

cd "$ANYTHINGLLM_DIR/server"

echo "=== [5/7] Configurazione file .env e directory storage ==="
mkdir -p "$ANYTHINGLLM_DIR/server/storage"

JWT_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "anythingllm_secret_$(date +%s)")

cat <<EOF > .env
SERVER_PORT=3001
STORAGE_DIR="$ANYTHINGLLM_DIR/server/storage"
JWT_SECRET="$JWT_SECRET"
DISABLE_TELEMETRY="true"
EOF

echo "=== [6/7] Installazione moduli NPM, Fix Zod e migrazione Database Prisma ==="
"$NODE20_DIR/bin/npm" install --legacy-peer-deps
"$NODE20_DIR/bin/npm" install zod-to-json-schema@latest zod@latest --legacy-peer-deps
"$NODE20_DIR/bin/npx" prisma generate
"$NODE20_DIR/bin/npx" prisma migrate deploy --schema=./prisma/schema.prisma

echo "=== [7/7] Configurazione ed avvio del servizio Systemd ==="
sudo bash -c "cat <<EOF > $SERVICE_FILE
[Unit]
Description=AnythingLLM Headless Node Server
After=network.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$ANYTHINGLLM_DIR/server
ExecStart=$NODE20_DIR/bin/node $ANYTHINGLLM_DIR/server/index.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable --now anythingllm.service

echo "=== Installazione completata con successo ==="
sleep 3
sudo systemctl status anythingllm.service --no-pager
