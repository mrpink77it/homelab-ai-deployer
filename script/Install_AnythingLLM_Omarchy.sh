#!/usr/bin/env bash
set -euo pipefail

ANYTHINGLLM_DIR="/opt/anythingllm-server"
NODE20_DIR="/opt/node20"
SERVICE_FILE="/etc/systemd/system/anythingllm.service"
RUN_USER="${SUDO_USER:-$USER}"

echo "=== [1/6] Rimozione installazioni precedenti ==="
sudo systemctl stop anythingllm.service 2>/dev/null || true
sudo systemctl disable anythingllm.service 2>/dev/null || true
sudo rm -f "$SERVICE_FILE"
sudo systemctl daemon-reload
sudo rm -rf "$ANYTHINGLLM_DIR"

echo "=== [2/6] Installazione dipendenze di sistema ==="
if command -v pacman &>/dev/null; then
    sudo pacman -Sy --needed --noconfirm git curl tar make gcc python
elif command -v apt-get &>/dev/null; then
    sudo apt-get update && sudo apt-get install -y git curl tar build-essential python3
fi

echo "=== [3/6] Setup Node.js v20 LTS isolato in $NODE20_DIR ==="
if [ ! -x "$NODE20_DIR/bin/node" ]; then
    sudo mkdir -p "$NODE20_DIR"
    curl -fsSL https://nodejs.org/dist/v20.18.0/node-v20.18.0-linux-x64.tar.xz | sudo tar -xJ --strip-components=1 -C "$NODE20_DIR"
fi

echo "Node attivo: $($NODE20_DIR/bin/node -v)"
echo "NPM attivo:  $($NODE20_DIR/bin/npm -v)"

echo "=== [4/6] Clonazione e installazione di AnythingLLM ==="
sudo git clone --depth 1 https://github.com/Mintplex-Labs/anything-llm.git "$ANYTHINGLLM_DIR"
sudo chown -R "$RUN_USER:$RUN_USER" "$ANYTHINGLLM_DIR"

cd "$ANYTHINGLLM_DIR/server"

if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
    else
        touch .env
    fi
fi

echo "Installazione moduli npm con Node 20 (--legacy-peer-deps)..."
"$NODE20_DIR/bin/npm" install --legacy-peer-deps

echo "=== [5/6] Creazione servizio systemd ==="
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

echo "=== [6/6] Avvio e abilitazione del servizio ==="
sudo systemctl daemon-reload
sudo systemctl enable --now anythingllm.service

echo "=== Installazione completata ==="
sudo systemctl status anythingllm.service --no-pager
