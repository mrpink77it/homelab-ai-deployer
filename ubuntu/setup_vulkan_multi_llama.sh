#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/llama-cpp-vulkan-multi"
MODEL_DIR="/opt/llama_models"
PORT=9800

echo "[*] Installazione dipendenze di sistema per Vulkan e compilazione..."
apt-get update
apt-get install -y build-essential cmake git libvulkan-dev vulkan-tools glslc

echo "[*] Clonazione o aggiornamento repository llama.cpp in $INSTALL_DIR..."
if [ -d "$INSTALL_DIR/.git" ]; then
    cd "$INSTALL_DIR"
    git pull
else
    git clone https://github.com/ggerganov/llama.cpp.git "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

echo "[*] Compilazione di llama.cpp con supporto Vulkan (-DGGML_VULKAN=ON)..."
cmake -B build -DGGML_VULKAN=ON
cmake --build build --config Release -j$(nproc)

mkdir -p "$MODEL_DIR"

echo "[*] Rilevamento dispositivi Vulkan disponibili:"
"$INSTALL_DIR/build/bin/llama-server" --list-devices || true

SERVICE_FILE="/etc/systemd/system/llama-vulkan-multi.service"

echo "[*] Creazione servizio systemd unificato Vulkan sulla porta $PORT..."
cat << EOF_SERVICE > "$SERVICE_FILE"
[Unit]
Description=Llama.cpp Multi-GPU Vulkan Server (Port $PORT)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/build/bin
ExecStart=$INSTALL_DIR/build/bin/llama-server --host 0.0.0.0 --port $PORT --models-dir $MODEL_DIR --split-mode layer --cache-type-k q8_0 --cache-type-v q8_0 -ngl 99
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable llama-vulkan-multi.service
systemctl restart llama-vulkan-multi.service

echo "================================================================="
echo "[OK] Setup Vulkan Multi-GPU completato sulla porta $PORT."
echo "================================================================="
