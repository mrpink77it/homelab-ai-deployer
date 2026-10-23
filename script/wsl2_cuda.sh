#!/usr/bin/env bash
set -euo pipefail

if ! grep -qi microsoft /proc/version; then
    echo "Errore: questo script deve essere eseguito all'interno di WSL2." >&2
    exit 1
fi

echo "[1/6] Aggiornamento dei pacchetti di sistema..."
sudo apt-get update && sudo apt-get upgrade -y

echo "[2/6] Installazione delle dipendenze di base..."
sudo apt-get install -y wget curl gnupg ca-certificates build-essential

echo "[3/6] Configurazione del repository CUDA NVIDIA per WSL..."
CUDA_KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb"
wget -q "$CUDA_KEYRING_URL" -O /tmp/cuda-keyring.deb
sudo dpkg -i /tmp/cuda-keyring.deb
rm -f /tmp/cuda-keyring.deb
sudo apt-get update

echo "[4/6] Installazione del CUDA Toolkit..."
sudo apt-get install -y cuda-toolkit

echo "[5/6] Installazione e configurazione di Docker e NVIDIA Container Toolkit..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
fi

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker || true

echo "[6/6] Configurazione delle variabili d'ambiente..."
PROFILE_FILE="$HOME/.bashrc"
if ! grep -q "/usr/local/cuda/bin" "$PROFILE_FILE"; then
    {
        echo ''
        echo '# NVIDIA CUDA Toolkit paths'
        echo 'export PATH=/usr/local/cuda/bin:$PATH'
        echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH'
    } >> "$PROFILE_FILE"
fi

echo "Installazione completata con successo."
