#!/usr/bin/env bash
set -euo pipefail

ANYTHINGLLM_DIR="/opt/anythingllm-server"
NODE20_DIR="/opt/node20"
SERVICE_FILE="/etc/systemd/system/anythingllm.service"
RUN_USER="${SUDO_USER:-$USER}"

echo "=========================================================================="
echo "  ██████╗  █████╗  ██████╗██╗  ██╗██╗   ██╗██████╗ "
echo "  ██╔══██╗██╔══██╗██╔════╝██║ ██╔╝██║   ██║██╔══██╗"
echo "  ██████╔╝███████║██║     █████╔╝ ██║   ██║██████╔╝"
echo "  ██╔══██╗██╔══██║██║     ██╔═██╗ ██║   ██║██╔═══╝ "
echo "  ██████╔╝██║  ██║╚██████╗██║  ██╗╚██████╔╝██║     "
echo "  ╚═════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝     "
echo "=========================================================================="
echo "  ATTENZIONE: SALVATAGGIO DATI E DATABASE (STORAGE) IN CORSO"
echo "  I file verranno SPOSTATI in: /opt/anythingllm_storage_backup"
echo "=========================================================================="
sleep 2

if [ -d "$ANYTHINGLLM_DIR/server/storage" ]; then
    # Rimuove eventuali backup precedenti prima di spostare il nuovo
    sudo rm -rf /opt/anythingllm_storage_backup
    sudo mv "$ANYTHINGLLM_DIR/server/storage" /opt/anythingllm_storage_backup
    echo "[OK] Storage spostato con successo."
else
    echo "[INFO] Nessuno storage esistente trovato. Salto il backup."
fi
sleep 1

echo "=== [1/8] Pulizia installazioni e servizi precedenti ==="
sudo systemctl stop anythingllm.service 2>/dev/null || true
sudo systemctl disable anythingllm.service 2>/dev/null || true
sudo rm -f "$SERVICE_FILE"
sudo systemctl daemon-reload
sudo rm -rf "$ANYTHINGLLM_DIR"

echo "=== [2/8] Installazione dipendenze di sistema ==="
if command -v pacman &>/dev/null; then
    sudo pacman -Sy --needed --noconfirm -q git curl tar make gcc python openssl >/dev/null 2>&1
elif command -v apt-get &>/dev/null; then
    sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq git curl tar build-essential python3 openssl >/dev/null 2>&1
fi

echo "=== [3/8] Setup Node.js v20 LTS isolato in $NODE20_DIR ==="
if [ ! -x "$NODE20_DIR/bin/node" ]; then
    sudo mkdir -p "$NODE20_DIR"
    # curl usa -fsSL per scaricare in modo silenzioso (s), mostrando solo errori (f)
    curl -fsSL https://nodejs.org/dist/v20.18.0/node-v20.18.0-linux-x64.tar.xz | sudo tar -xJ --strip-components=1 -C "$NODE20_DIR"
fi

echo "=== [4/8] Clonazione AnythingLLM in $ANYTHINGLLM_DIR ==="
sudo git clone -q --depth 1 https://github.com/Mintplex-Labs/anything-llm.git "$ANYTHINGLLM_DIR"
sudo chown -R "$RUN_USER:$RUN_USER" "$ANYTHINGLLM_DIR"

echo "=== [5/8] Configurazione file .env e ripristino storage ==="
# Se esiste il backup, lo rimettiamo al suo posto con il comando mv
if [ -d "/opt/anythingllm_storage_backup" ]; then
    echo "          [!] Ripristino il backup dello storage precedente..."
    mkdir -p "$ANYTHINGLLM_DIR/server"
    sudo mv /opt/anythingllm_storage_backup "$ANYTHINGLLM_DIR/server/storage"
    sudo chown -R "$RUN_USER:$RUN_USER" "$ANYTHINGLLM_DIR/server/storage"
else
    mkdir -p "$ANYTHINGLLM_DIR/server/storage"
fi

JWT_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "anythingllm_secret_$(date +%s)")

cat <<EOF > "$ANYTHINGLLM_DIR/server/.env"
SERVER_PORT=3001
STORAGE_DIR="$ANYTHINGLLM_DIR/server/storage"
JWT_SECRET="$JWT_SECRET"
DISABLE_TELEMETRY="true"
EOF

echo "=== [6/8] Installazione Backend, Fix Zod e DB Prisma ==="
cd "$ANYTHINGLLM_DIR/server"
"$NODE20_DIR/bin/npm" install --legacy-peer-deps --loglevel error --no-fund --no-audit
"$NODE20_DIR/bin/npm" install zod-to-json-schema@latest zod@latest --legacy-peer-deps --loglevel error --no-fund --no-audit
"$NODE20_DIR/bin/npx" prisma generate >/dev/null 2>&1
"$NODE20_DIR/bin/npx" prisma migrate deploy --schema=./prisma/schema.prisma >/dev/null 2>&1

echo "=== [7/8] Compilazione Interfaccia Web (Frontend) ==="
cd "$ANYTHINGLLM_DIR/frontend"
"$NODE20_DIR/bin/npm" install --legacy-peer-deps --loglevel error --no-fund --no-audit
"$NODE20_DIR/bin/npm" install regenerator-runtime --legacy-peer-deps --loglevel error --no-fund --no-audit
# Reindirizziamo l'output della build per nascondere i warning di Vite
"$NODE20_DIR/bin/npm" run build --loglevel error >/dev/null 2>&1

cd "$ANYTHINGLLM_DIR/server"
ln -s ../frontend/dist ./public

echo "=== [8/8] Configurazione ed avvio del servizio Systemd ==="
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
sudo systemctl enable --now anythingllm.service -q

echo "=== Installazione completata con successo ==="
sleep 2
sudo systemctl status anythingllm.service --no-pagerv
