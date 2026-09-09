#!/usr/bin/env bash
set -euo pipefail

echo "=== Installazione e Configurazione AnythingLLM Nativo su Omarchy ==="

INSTALL_DIR="/opt/anythingllm"
APPIMAGE_PATH="${INSTALL_DIR}/AnythingLLM.AppImage"
SERVICE_FILE="/etc/systemd/system/anythingllm.service"
APP_USER="${SUDO_USER:-$USER}"

if [ "$APP_USER" = "root" ]; then
    APP_USER="alex"
fi

echo "[1/5] Installazione dipendenze di sistema..."
sudo pacman -Sy --needed --noconfirm curl wget fuse2 jq git

echo "[2/5] Preparazione directory ${INSTALL_DIR}..."
sudo mkdir -p "${INSTALL_DIR}"

if systemctl is-active --quiet anythingllm.service 2>/dev/null; then
    echo "   -> Arresto temporaneo del servizio anythingllm in corso..."
    sudo systemctl stop anythingllm.service
fi

echo "[3/5] Recupero URL ultima release di AnythingLLM da GitHub..."
LATEST_URL=$(curl -s https://api.github.com/repos/Mintplex-Labs/anything-llm/releases/latest | jq -r '.assets[] | select(.name | endswith(".AppImage")) | .browser_download_url' | head -n 1)

if [ -z "${LATEST_URL}" ] || [ "${LATEST_URL}" = "null" ]; then
    echo "   [!] Impossibile recuperare l'URL da GitHub API, uso URL fallback CDN..."
    LATEST_URL="https://cdn.useanything.com/latest/AnythingLLMDesktop.AppImage"
fi

echo "   -> Download in corso da: ${LATEST_URL}"
sudo curl -SL "${LATEST_URL}" -o "${APPIMAGE_PATH}"

FILE_SIZE=$(stat -c%s "${APPIMAGE_PATH}" 2>/dev/null || echo 0)
if [ "$FILE_SIZE" -lt 50000000 ]; then
    echo "[!] ERRORE: Download fallito o incompleto (Dimensione: ${FILE_SIZE} bytes)."
    echo "    Contenuto della risposta:"
    cat "${APPIMAGE_PATH}"
    exit 1
fi

echo "[+] Download completato con successo: $(du -h "${APPIMAGE_PATH}" | cut -f1)"

echo "[4/5] Configurazione permessi e proprietario..."
sudo chmod +x "${APPIMAGE_PATH}"
sudo chown -R "${APP_USER}:${APP_USER}" "${INSTALL_DIR}"

echo "[5/5] Creazione e configurazione del servizio Systemd..."
sudo tee "${SERVICE_FILE}" > /dev/null << EOF
[Unit]
Description=AnythingLLM Service su Omarchy
After=network.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${INSTALL_DIR}
Environment="APPIMAGE_EXTRACT_AND_RUN=1"
ExecStart=${APPIMAGE_PATH} --no-sandbox
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "[+] Reload systemd, abilitazione ed avvio del servizio..."
sudo systemctl daemon-reload
sudo systemctl enable anythingllm.service
sudo systemctl restart anythingllm.service

echo "[+] Attesa avvio processo..."
sleep 3

echo "=== Stato del Servizio AnythingLLM ==="
sudo systemctl status anythingllm.service --no-pager
