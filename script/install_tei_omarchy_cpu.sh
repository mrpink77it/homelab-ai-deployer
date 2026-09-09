#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CONTROLLO E IMPOSTAZIONE LOCALE UTF-8
# ==============================================================================
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export PYTHONIOENCODING="utf-8"

# Fix specifico per AMD RX 5700 XT (Navi 10 / RDNA1) in ambiente ROCm/HIP
export HSA_OVERRIDE_GFX_VERSION="10.1.0"

echo "=== Configurazione Omarchy AI: LANG=$LANG | GPU=RX 5700 XT (gfx1010) ==="

# 1. Rilevamento gestore pacchetti (Debian/Ubuntu vs Arch/Manjaro)
echo "[1/5] Verifica dipendenze di sistema..."
if command -v apt-get &> /dev/null; then
    sudo apt-get update && sudo apt-get install -y \
        curl build-essential cmake pkg-config libssl-dev git locales
    sudo locale-gen en_US.UTF-8 it_IT.UTF-8 C.UTF-8
    sudo update-locale LANG=C.UTF-8 LC_ALL=C.UTF-8
elif command -v pacman &> /dev/null; then
    sudo pacman -Sy --needed --noconfirm \
        curl base-devel cmake pkgconf openssl git
fi

# 2. Configurazione Toolchain Rust
echo "[2/5] Verificazione ambiente Rust..."
if ! command -v cargo &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

# 3. Compilazione / Installazione di TEI
echo "[3/5] Compilazione di HuggingFace text-embeddings-router..."
cargo install --git https://github.com/huggingface/text-embeddings-inference.git text-embeddings-router

sudo cp "$HOME/.cargo/bin/text-embeddings-router" /usr/local/bin/

# 4. Configurazione directory dati ed utente di servizio
echo "[4/5] Preparazione cartelle locali..."
sudo id -u tei &>/dev/null || sudo useradd -r -s /bin/false tei
sudo mkdir -p /var/lib/tei/data
sudo chown -R tei:tei /var/lib/tei

# 5. Creazione del servizio Systemd con variabili UTF-8 e ROCm/HIP
echo "[5/5] Configurazione servizio Systemd (tei-bge-m3.service)..."
sudo bash -c 'cat << EOF > /etc/systemd/system/tei-bge-m3.service
[Unit]
Description=HuggingFace Text Embeddings Inference (bge-m3) su Omarchy RX 5700 XT
After=network.target

[Service]
Type=simple
User=tei
Group=tei
WorkingDirectory=/var/lib/tei
Environment="LANG=C.UTF-8"
Environment="LC_ALL=C.UTF-8"
Environment="PYTHONIOENCODING=utf-8"
Environment="HSA_OVERRIDE_GFX_VERSION=10.1.0"
ExecStart=/usr/local/bin/text-embeddings-router \
    --model-id BAAI/bge-m3 \
    --hostname 0.0.0.0 \
    --port 8080 \
    --max-concurrent-requests 512 \
    --max-batch-tokens 16384 \
    --max-client-batch-size 128 \
    --auto-truncate
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF'

# Abilitazione e avvio del servizio
sudo systemctl daemon-reload
sudo systemctl enable --now tei-bge-m3

echo "=== Installazione su Omarchy completata ==="
echo "Stato del servizio:"
sudo systemctl status tei-bge-m3 --no-pager
