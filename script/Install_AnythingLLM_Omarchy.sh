#!/usr/bin/env bash
set -euo pipefail

echo "=== Installazione AnythingLLM Server Native (Headless) su Omarchy ==="

INSTALL_DIR="/opt/anythingllm-server"
SERVICE_FILE="/etc/systemd/system/anythingllm.service"
APP_USER="${SUDO_USER:-$USER}"

if [ "$APP_USER" = "root" ]; then
    APP_USER="alex"
fi

echo "[1/6] Installazione dipendenze di sistema (Node.js, Yarn, Build Tools)..."
sudo pacman -Sy --needed --noconfirm nodejs npm yarn git python make gcc curl jq

echo "[2/6] Preparazione directory di installazione..."
if [ -d "${INSTALL_DIR}" ]; then
    echo "   -> Pulizia vecchia installazione in ${INSTALL_DIR}..."
    sudo rm -rf "${INSTALL_DIR}"
fi
sudo mkdir -p "${INSTALL_DIR}"
sudo chown -R "${APP_USER}:${APP_USER}" "${INSTALL_DIR}"

echo "[3/6] Download repository AnythingLLM..."
git clone https://github.com/Mintplex-Labs/anything-llm.git "${INSTALL_DIR}"

cd "${INSTALL_DIR}"

echo "[4/6] Installazione dipendenze e build del progetto..."
# Configurazione file d'ambiente server
cat << EOF > server/.env
SERVER_PORT=3001
STORAGE_DIR="${INSTALL_DIR}/server/storage"
DISABLE_TELEMETRY="true"
EOF

# Installazione dipendenze e build
yarn setup

echo "[5/6] Inizializzazione Database Prisma..."
cd "${INSTALL_DIR}/server"
npx prisma generate
npx prisma migrate deploy

echo "[6/6] Creazione servizio Systemd Native..."
sudo tee "${SERVICE_FILE}" > /dev/null << EOF
[Unit]
Description=AnythingLLM Headless Node Server su Omarchy
After=network.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${INSTALL_DIR}/server
Environment=NODE_ENV=production
Environment=SERVER_PORT=3001
Environment=STORAGE_DIR=${INSTALL_DIR}/server/storage
ExecStart=/usr/bin/node ${INSTALL_DIR}/server/index.js
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

echo "[+] Reload systemd, abilitazione ed avvio del servizio..."
sudo systemctl daemon-reload
sudo systemctl enable anythingllm.service
sudo systemctl restart anythingllm.service

echo "[+] Attesa avvio server backend..."
sleep 4

echo "=== Stato del Servizio AnythingLLM ==="
sudo systemctl status anythingllm.service --no-pager
echo ""
echo "-> Interfaccia Web raggiungibile su: http://localhost:3001 (o IP_SERVER:3001)"
