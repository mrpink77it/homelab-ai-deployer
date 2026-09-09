#!/usr/bin/env bash
set -euo pipefail

echo "==> Avvio configurazione e deployment bare-metal di TEI (bge-m3)..."

# 1. Creazione utente ed gruppo di sistema dedicato (se non esistono)
if ! getent group tei >/dev/null 2>&1; then
    echo "[+] Creazione gruppo 'tei'..."
    sudo groupadd -r tei
fi

if ! id -u tei >/dev/null 2>&1; then
    echo "[+] Creazione utente di sistema 'tei'..."
    sudo useradd -r -g tei -d /var/lib/tei -s /usr/bin/nologin -c "TEI Service Account" tei
fi

# 2. Struttura delle directory di lavoro e cache Hugging Face
echo "[+] Configurazione directory /var/lib/tei e permessi..."
sudo mkdir -p /var/lib/tei/cache
sudo chown -R tei:tei /var/lib/tei
sudo chmod -R 750 /var/lib/tei

# 3. Verifica binario text-embeddings-router
if [ ! -x "/usr/local/bin/text-embeddings-router" ]; then
    echo "[!] WARNING: /usr/local/bin/text-embeddings-router non trovato o non eseguibile."
    echo "    Assicurati che il binario sia stato compilato/spostato correttamente."
fi

# 4. Generazione del file di unit systemd ottimizzato per CPU
echo "[+] Creazione /etc/systemd/system/tei-bge-m3.service..."
sudo tee /etc/systemd/system/tei-bge-m3.service > /dev/null << 'EOF'
[Unit]
Description=HuggingFace Text Embeddings Inference (bge-m3) su Omarchy
After=network.target

[Service]
Type=simple
User=tei
Group=tei
WorkingDirectory=/var/lib/tei
Environment="LANG=C.UTF-8"
Environment="LC_ALL=C.UTF-8"
Environment="PYTHONIOENCODING=utf-8"
Environment="HOME=/var/lib/tei"
Environment="HF_HOME=/var/lib/tei/cache"
Environment="HSA_OVERRIDE_GFX_VERSION=10.1.0"

ExecStart=/usr/local/bin/text-embeddings-router \
    --model-id BAAI/bge-m3 \
    --hostname 0.0.0.0 \
    --port 8080 \
    --max-concurrent-requests 128 \
    --max-batch-requests 4 \
    --max-batch-tokens 8192 \
    --max-client-batch-size 32

Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# 5. Reload systemd, abilitazione ed avvio servizio
echo "[+] Reload systemd daemon, abilitazione ed avvio del servizio..."
sudo systemctl daemon-reload
sudo systemctl enable tei-bge-m3.service
sudo systemctl restart tei-bge-m3.service

echo "==> Configurazione completata!"
echo "Verifica i log di avvio e il warm-up con:"
echo "    sudo journalctl -u tei-bge-m3.service -f"
