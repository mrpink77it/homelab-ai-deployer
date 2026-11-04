#!/usr/bin/env bash

# V.1.1.0 - Ottimizzato per RX 5700 XT 8GB con precaricamento modello

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/llama.cpp"
SERVICE_FILE="/etc/systemd/system/llama-cpp-vulkan.service"
MODEL_DIR="/opt/llama_models"
MODEL_FILE="Llama-3.2-3B-Instruct-Q4_K_M.gguf"
PORT=8080

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

echo "[*] Creazione directory modelli in $MODEL_DIR..."
mkdir -p "$MODEL_DIR"

if [ ! -f "$MODEL_DIR/$MODEL_FILE" ]; then
    echo "[!] Attenzione: Il file del modello $MODEL_FILE non è presente in $MODEL_DIR."
    echo "    Assicurati di scaricarlo prima di avviare il servizio."
fi

echo "[*] Generazione file systemd in $SERVICE_FILE..."
cat << EOF_SERVICE > "$SERVICE_FILE"
[Unit]
Description=Llama.cpp Vulkan Server (RX 5700 XT 8GB)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/llama.cpp/build/bin
Environment="GGML_VK_VISIBLE_DEVICES=0"
ExecStart=/opt/llama.cpp/build/bin/llama-server --host 0.0.0.0 --port $PORT --models-dir $MODEL_DIR -m $MODEL_DIR/$MODEL_FILE -ngl 99 --cache-type-k q4_0 --cache-type-v q4_0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_SERVICE

echo "[*] Configurazione e avvio del servizio systemd..."
systemctl daemon-reload
systemctl enable llama-cpp-vulkan.service
systemctl restart llama-cpp-vulkan.service

echo "================================================================="
echo "[OK] Installazione completata con successo!"
echo " Modello precaricato in VRAM: $MODEL_FILE"
echo " Stato servizio: sudo systemctl status llama-cpp-vulkan"
echo " Log in tempo reale: sudo journalctl -u llama-cpp-vulkan -f"
echo "================================================================="
