#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

if ! command -v nvidia-smi &> /dev/null; then
  echo "[-] Errore: nvidia-smi non trovato. Nessuna GPU CUDA rilevata."
  exit 1
fi

INSTALL_DIR="/opt/llama-cpp-cuda"
MODEL_DIR="/opt/llama_models"
START_PORT=8200

echo "[*] Installazione dipendenze per compilazione CUDA..."
apt-get update
apt-get install -y build-essential cmake git

echo "[*] Clonazione o aggiornamento repository llama.cpp in $INSTALL_DIR..."
if [ -d "$INSTALL_DIR/.git" ]; then
    cd "$INSTALL_DIR"
    git pull
else
    git clone https://github.com/ggerganov/llama.cpp.git "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

echo "[*] Compilazione di llama.cpp con supporto CUDA (-DGGML_CUDA=ON)..."
cmake -B build -DGGML_CUDA=ON
cmake --build build --config Release -j$(nproc)

mkdir -p "$MODEL_DIR"

NUM_GPUS=$(nvidia-smi --query-gpu=count --format=csv,noheader | head -n 1)
echo "[*] Rilevate $NUM_GPUS schede GPU CUDA."

for ((i=0; i<NUM_GPUS; i++)); do
    PORT=$((START_PORT + i))
    SERVICE_FILE="/etc/systemd/system/llama-cuda-$i.service"
    
    echo "[*] Creazione servizio systemd per GPU $i sulla porta $PORT..."
    cat << EOF_SERVICE > "$SERVICE_FILE"
[Unit]
Description=Llama.cpp CUDA Server - GPU $i (Port $PORT)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/build/bin
Environment="CUDA_VISIBLE_DEVICES=$i"
ExecStart=$INSTALL_DIR/build/bin/llama-server --host 0.0.0.0 --port $PORT --models-dir $MODEL_DIR --cache-type-k q4_0 --cache-type-v q4_0 -ngl 99
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    systemctl daemon-reload
    systemctl enable "llama-cuda-$i.service"
    systemctl restart "llama-cuda-$i.service"
    echo "[OK] Servizio llama-cuda-$i avviato sulla porta $PORT."
done

echo "================================================================="
echo "[OK] Setup CUDA completato per $NUM_GPUS schede (Porte da $START_PORT in poi)."
echo "================================================================="
