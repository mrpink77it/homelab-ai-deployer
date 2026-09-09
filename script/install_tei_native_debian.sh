#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CONTROLLO E IMPOSTAZIONE LOCALE UTF-8
# ==============================================================================
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export PYTHONIOENCODING="utf-8"

echo "=== Configurazione Ambiente: LANG=$LANG | LC_ALL=$LC_ALL ==="

# 1. Aggiornamento sistema e installazione dipendenze di build
echo "[1/5] Installazione dipendenze di sistema..."
apt-get update && apt-get install -y \
    curl \
    build-essential \
    cmake \
    pkg-config \
    libssl-dev \
    git \
    locales

# Assicura che i locale UTF-8 siano generati a livello di sistema
locale-gen en_US.UTF-8 it_IT.UTF-8 C.UTF-8
update-locale LANG=C.UTF-8 LC_ALL=C.UTF-8

# 2. Installazione toolchain Rust
echo "[2/5] Configurazione toolchain Rust..."
if ! command -v cargo &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

# 3. Compilazione / Installazione di TEI (text-embeddings-router)
echo "[3/5] Installazione di HuggingFace text-embeddings-router..."
cargo install --git https://github.com/huggingface/text-embeddings-inference.git text-embeddings-router

# Sposta il binario nel percorso globale di sistema
cp "$HOME/.cargo/bin/text-embeddings-router" /usr/local/bin/

# 4. Creazione utente dedicato e directory dati
echo "[4/5] Creazione utente e directory di lavoro..."
id -u tei &>/dev/null || useradd -r -s /bin/false tei
mkdir -p /var/lib/tei/data
chown -R tei:tei /var/lib/tei

# 5. Creazione del servizio Systemd con UTF-8 abilitato
echo "[5/5] Generazione del servizio Systemd..."
cat << 'EOF' > /etc/systemd/system/tei-bge-m3.service
[Unit]
Description=HuggingFace Text Embeddings Inference (bge-m3)
After=network.target

[Service]
Type=simple
User=tei
Group=tei
WorkingDirectory=/var/lib/tei
Environment="LANG=C.UTF-8"
Environment="LC_ALL=C.UTF-8"
Environment="PYTHONIOENCODING=utf-8"
ExecStart=/usr/local/bin/text-embeddings-router \
    --model-id BAAI/bge-m3 \
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
EOF

# Ricarica systemd e avvia il servizio
systemctl daemon-reload
systemctl enable --now tei-bge-m3

echo "=== Installazione completata con successo ==="
echo "Stato del servizio:"
systemctl status tei-bge-m3 --no-pager
