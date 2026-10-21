#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/llama.cpp"
SERVICE_FILE="/etc/systemd/system/llama-cpp-vulkan.service"

echo "[*] Installazione dipendenze di sistema e driver Vulkan..."
apt-get update
apt-get install -y build-essential cmake git libvulkan-dev vulkan-tools glslang-tools

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

echo "[*] Creazione directory modelli..."
mkdir -p /home/alex/llama_models

echo "[*] Generazione file systemd in $SERVICE_FILE..."
cat << 'EOF_SERVICE' > "$SERVICE_FILE"
[Unit]
Description=Llama.cpp Vulkan Server (RX 5700 XT)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/llama.cpp/build/bin
Environment="GGML_VK_VISIBLE_DEVICES=0"
ExecStart=/opt/llama.cpp/build/bin/llama-server --host 0.0.0.0 --port 8080 --models-dir /home/alex/llama_models --cache-type-k q4_0 --cache-type-v q4_0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_SERVICE

echo "[*] Configurazione e avvio del servizio systemd..."
systemctl daemon-reload
systemctl enable llama-cpp-vulkan.service
systemctl start llama-cpp-vulkan.service

echo "================================================================="
echo "[OK] Installazione completata con successo!"
echo " Stato servizio: sudo systemctl status llama-cpp-vulkan"
echo " Log in tempo reale: sudo journalctl -u llama-cpp-vulkan -f"
echo "================================================================="
