#!/usr/bin/env bash

set -euo pipefail

# 1. Verifica permessi di root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come utente root." >&2
  exit 1
fi

echo "[*] Avvio installazione e configurazione di SearXNG..."

# 2. Installazione delle dipendenze di sistema (senza uwsgi o pacchetti ridondanti)
echo "[*] Aggiornamento indici e installazione dipendenze di sistema..."
apt-get update -qq
apt-get install -y -qq \
    python3-dev python3-babel python3-venv python-is-python3 \
    git build-essential libxslt1-dev zlib1g-dev libffi-dev libssl-dev openssl

# 3. Creazione dell'utente di sistema 'searxng'
if ! id "searxng" &>/dev/null; then
    echo "[*] Creazione utente di sistema 'searxng'..."
    useradd --shell /bin/bash --system \
        --home-dir "/usr/local/searxng" \
        --comment 'Privacy-respecting metasearch engine' \
        searxng
else
    echo "[*] Utente 'searxng' già esistente."
fi

# 4. Preparazione directory e permessi
echo "[*] Configurazione directory /usr/local/searxng..."
mkdir -p "/usr/local/searxng"
chown -R "searxng:searxng" "/usr/local/searxng"

# 5. Download sorgenti e setup Virtual Environment via utente searxng
echo "[*] Setup ambiente Python e clone repository SearXNG..."
su - searxng -c '
set -e
SEARXNG_DIR="/usr/local/searxng"
SRC_DIR="$SEARXNG_DIR/searxng-src"
VENV_DIR="$SEARXNG_DIR/searx-pyenv"

if [ ! -d "$SRC_DIR" ]; then
    git clone "https://github.com/searxng/searxng.git" "$SRC_DIR"
else
    echo "[*] Repository già clonata. Aggiornamento in corso..."
    git -C "$SRC_DIR" pull
fi

if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

if ! grep -q "searx-pyenv/bin/activate" "$SEARXNG_DIR/.profile" 2>/dev/null; then
    echo ". $VENV_DIR/bin/activate" >> "$SEARXNG_DIR/.profile"
fi

source "$VENV_DIR/bin/activate"

pip install -U --quiet pip setuptools wheel
pip install -U --quiet pyyaml msgspec typing-extensions pybind11

cd "$SRC_DIR"
pip install --use-pep517 --no-build-isolation -e .
'

# 6. Generazione file di configurazione /etc/searxng/settings.yml
echo "[*] Generazione configurazione /etc/searxng/settings.yml..."
mkdir -p "/etc/searxng"

# Generazione secret_key univoca
SECRET_KEY=$(openssl rand -hex 32)

cat << EOF > /etc/searxng/settings.yml
# SearXNG settings

use_default_settings: true

general:
  debug: false
  instance_name: "SearXNG"

search:
  safe_search: 2
  autocomplete: 'duckduckgo'
  formats:
    - html

server:
  secret_key: "${SECRET_KEY}"
  limiter: true
  image_proxy: true
  port: 8889
  bind_address: "127.0.0.1"

valkey:
  url: valkey://localhost:6379/0
EOF

chown -R "searxng:searxng" "/etc/searxng"

# 7. Creazione e abilitazione del servizio Systemd
echo "[*] Creazione del servizio systemd..."
cat << 'EOF' > /etc/systemd/system/searxng.service
[Unit]
Description=SearXNG Metasearch Engine
After=network.target

[Service]
Type=simple
User=searxng
Group=searxng
WorkingDirectory=/usr/local/searxng/searxng-src
Environment="SEARXNG_SETTINGS_PATH=/etc/searxng/settings.yml"
ExecStart=/usr/local/searxng/searx-pyenv/bin/python searx/webapp.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "[*] Ricarica daemon systemd e avvio del servizio..."
systemctl daemon-reload
systemctl enable --now searxng.service

echo "=============================================================================="
echo "[OK] Setup completato con successo!"
echo "------------------------------------------------------------------------------"
echo " Stato servizio:   sudo systemctl status searxng.service"
echo " Endpoint attivo:  http://127.0.0.1:8889"
echo "=============================================================================="
