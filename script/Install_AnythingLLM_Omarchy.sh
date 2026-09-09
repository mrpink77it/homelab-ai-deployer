#!/usr/bin/env bash
set -euo pipefail

echo "=== Installazione e Configurazione AnythingLLM Nativo su Omarchy ==="

INSTALL_DIR="/opt/anythingllm"
APPIMAGE_PATH="${INSTALL_DIR}/AnythingLLM.AppImage"
SERVICE_FILE="/etc/systemd/system/anythingllm.service"
APP_USER="${SUDO_USER:-$USER}"

# Fallback se lo script viene eseguito direttamente da root
if [ "$APP_USER" = "root" ]; then
    APP_USER="alex"
fi

echo "[1/5] Installazione dipendenze di sistema..."
sudo pacman -Sy --needed --noconfirm curl wget fuse2 jq git

echo "[2/5] Preparazione directory ${INSTALL_DIR}..."
sudo mkdir -p "${INSTALL_DIR}"

# Arresta il servizio se già attivo per sbloccare il file AppImage
if systemctl is-active --quiet anythingllm.service 2>/dev/null; then
    echo "   -> Arresto temporaneo del servizio anythingllm in corso..."
    sudo systemctl stop anythingllm.service
fi

echo "[3/5] Download di AnythingLLM AppImage (con gestione redirect)..."
sudo curl -SL "https://s3.amazonaws.com/anythingllm-desktop/AnythingLLMDesktop.AppImage" -o "${APPIMAGE_PATH}"

# Verifica di sicurezza sulla dimensione del file scaricato
FILE_SIZE=$(stat -c%s "${APPIMAGE_PATH}" 2>/dev/null || echo 0)
if [ "$FILE_SIZE" -lt 50000000 ]; then
    echo "[!] ERRORE: Download fallito o incompleto (Dimensione: ${FILE_SIZE} bytes)."
    echo "    Verifica la connettività di rete e riprova."
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
