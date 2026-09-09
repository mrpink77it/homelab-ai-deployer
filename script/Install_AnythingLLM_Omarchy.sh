#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CONTROLLO E IMPOSTAZIONE LOCALE UTF-8
# ==============================================================================
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export PYTHONIOENCODING="utf-8"

echo "=== Configurazione AnythingLLM Nativo su Omarchy ==="

# 1. Installazione dipendenze di sistema
echo "[1/4] Installazione dipendenze di sistema..."
if command -v apt-get &> /dev/null; then
    sudo apt-get update && sudo apt-get install -y \
        curl wget libfuse2 jq git locales
    sudo locale-gen en_US.UTF-8 it_IT.UTF-8 C.UTF-8
    sudo update-locale LANG=C.UTF-8 LC_ALL=C.UTF-8
elif command -v pacman &> /dev/null; then
    sudo pacman -Sy --needed --noconfirm \
        curl wget fuse2 jq git
fi

# 2. Setup directory ed utente dedicato
echo "[2/4] Creazione directory per AnythingLLM..."
INSTALL_DIR="/opt/anythingllm"
DATA_DIR="/var/lib/anythingllm"

sudo mkdir -p "$INSTALL_DIR" "$DATA_DIR"
sudo chown -R $USER:$USER "$INSTALL_DIR" "$DATA_DIR"

# 3. Download dell'ultimo eseguibile/AppImage di AnythingLLM Desktop/Server
echo "[3/4] Download di AnythingLLM..."
cd "$INSTALL_DIR"
curl -sL "https://s3.amazonaws.com/anythingllm-desktop/latest/AnythingLLMDesktop.AppImage" -o AnythingLLM.AppImage
chmod +x AnythingLLM.AppImage

# 4. Creazione del servizio Systemd per avvio automatico
echo "[4/4] Creazione del servizio Systemd..."
sudo bash -c "cat << EOF > /etc/systemd/system/anythingllm.service
[Unit]
Description=AnythingLLM Service su Omarchy
After=network.target tei-bge-m3.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR
Environment=\"LANG=C.UTF-8\"
Environment=\"LC_ALL=C.UTF-8\"
Environment=\"PYTHONIOENCODING=utf-8\"
Environment=\"STORAGE_DIR=$DATA_DIR\"
ExecStart=$INSTALL_DIR/AnythingLLM.AppImage --no-sandbox
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable --now anythingllm

echo "=== Installazione di AnythingLLM Nativo Completata ==="
echo "Stato del servizio:"
sudo systemctl status anythingllm --no-pager
