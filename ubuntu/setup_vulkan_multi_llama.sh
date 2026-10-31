#!/usr/bin/env bash

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root." >&2
  exit 1
fi

INSTALL_DIR="/opt/llama-cpp-vulkan-multi"
MODEL_DIR="/opt/llama_models"
PORT=9800

echo "[*] Installazione dipendenze di sistema per Vulkan e compilazione..."
apt-get update -qq
apt-get install -y -qq build-essential cmake git libvulkan-dev vulkan-tools glslc

echo "[*] Clonazione / Aggiornamento repository llama.cpp in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" pull
else
    git clone https://github.com/ggml-org/llama.cpp.git "$INSTALL_DIR"
fi

echo "[*] Compilazione di llama.cpp con supporto Vulkan (-DGGML_VULKAN=ON)..."
cmake -S "$INSTALL_DIR" -B "$INSTALL_DIR/build" -DGGML_VULKAN=ON
cmake --build "$INSTALL_DIR/build" --config Release -j$(nproc)

BINARY="$INSTALL_DIR/build/bin/llama-server"
if [ ! -x "$BINARY" ]; then
    echo "[-] Errore: Compilazione fallita o binario llama-server non trovato." >&2
    exit 1
fi

echo "[*] Rilevamento dispositivi Vulkan disponibili..."
DEVICES_OUTPUT=$("$BINARY" --list-devices 2>&1 || true)
echo "$DEVICES_OUTPUT"

# Conta dinamicamente i dispositivi Vulkan presenti nel sistema
VK_COUNT=$(grep -oiE "Vulkan[0-9]+" <<< "$DEVICES_OUTPUT" | sort -u | wc -l)
if [ "$VK_COUNT" -eq 0 ]; then
    echo "[!] Nessun device Vulkan esplicito trovato nell'intestazione. Impostazione predefinita a 2 device."
    VK_COUNT=2
fi

echo "[*] Rilevati n. $VK_COUNT dispositivi Vulkan. Costruzione flag di split..."
DEVICE_CLI_ARGS=""
for ((i=0; i<VK_COUNT; i++)); do
    DEVICE_CLI_ARGS="$DEVICE_CLI_ARGS --device Vulkan$i"
done

CTX=16384
BATCH=1024
NGL=99

echo -e "\033[32m[AUTO-CONFIG]\033[0m Multi-GPU Vulkan (${VK_COUNT} schede) -> CTX=${CTX}, BATCH=${BATCH}, NGL=${NGL}"

mkdir -p "$MODEL_DIR"

SERVICE_FILE="/etc/systemd/system/llama-vulkan-multi.service"
echo "[*] Creazione servizio systemd unificato su porta $PORT..."
cat << EOF_SERVICE > "$SERVICE_FILE"
[Unit]
Description=Llama.cpp Multi-GPU Vulkan Auto-Tuned Server (Port $PORT)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/build/bin
ExecStart=$BINARY \
    --host 0.0.0.0 \
    --port $PORT \
    --models-dir $MODEL_DIR \
    --split-mode layer \
    $DEVICE_CLI_ARGS \
    --ctx-size $CTX \
    --batch-size $BATCH \
    --n-gpu-layers $NGL \
    --cache-type-k q8_0 \
    --cache-type-v q8_0 \
    --fa
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE

echo "[*] Ricarica daemon systemd e avvio del servizio..."
systemctl daemon-reload
systemctl enable llama-vulkan-multi.service
systemctl restart llama-vulkan-multi.service

echo "=============================================================================="
echo "[OK] Setup Vulkan Multi-GPU completato con successo sulla porta $PORT."
echo "------------------------------------------------------------------------------"
echo " Directory Modelli: $MODEL_DIR"
echo " Comando di stato:  sudo systemctl status llama-vulkan-multi.service"
echo "=============================================================================="
