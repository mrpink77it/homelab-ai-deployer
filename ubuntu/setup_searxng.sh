#!/usr/bin/env bash
# ==============================================================================
# Script di Installazione Locale di SearXNG (Home: /usr/local/searxng)
# Compatibile con Ubuntu / Debian
# ==============================================================================

set -euo pipefail

# 1. Verifica che lo script sia eseguito con i privilegi di root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come utente root." >&2
  exit 1
fi

echo "[*] Avvio installazione di SearXNG..."

# 2. Installazione delle dipendenze di sistema
echo "[*] Aggiornamento indici e installazione pacchetti di sistema..."
apt-get update -qq
apt-get install -y -qq \
    python3-dev python3-babel python3-venv python-is-python3 \
    uwsgi uwsgi-plugin-python3 \
    git build-essential libxslt1-dev zlib1g-dev libffi-dev libssl-dev

# 3. Creazione dell'utente di sistema per SearXNG (se non esiste già)
if ! id "searxng" &>/dev/null; then
    echo "[*] Creazione utente di sistema 'searxng'..."
    useradd --shell /bin/bash --system \
        --home-dir "/usr/local/searxng" \
        --comment 'Privacy-respecting metasearch engine' \
        searxng
else
    echo "[*] Utente 'searxng' già esistente."
fi

# 4. Creazione e configurazione permessi directory home
echo "[*] Preparazione directory /usr/local/searxng..."
mkdir -p "/usr/local/searxng"
chown -R "searxng:searxng" "/usr/local/searxng"

# 5. Download e setup del Virtual Environment tramite utente searxng
echo "[*] Download del repository e configurazione Virtual Environment..."
su - searxng -c '
set -e
SEARXNG_DIR="/usr/local/searxng"
SRC_DIR="$SEARXNG_DIR/searxng-src"
VENV_DIR="$SEARXNG_DIR/searx-pyenv"

if [ ! -d "$SRC_DIR" ]; then
    git clone "https://github.com/searxng/searxng.git" "$SRC_DIR"
else
    echo "[*] Repository già clonata. Aggiornamento codice..."
    git -C "$SRC_DIR" pull
fi

if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

if ! grep -q "searx-pyenv/bin/activate" "$SEARXNG_DIR/.profile" 2>/dev/null; then
    echo ". $VENV_DIR/bin/activate" >> "$SEARXNG_DIR/.profile"
fi

# Attivazione VENV e installazione dipendenze Python
source "$VENV_DIR/bin/activate"

pip install -U --quiet pip setuptools wheel
pip install -U --quiet pyyaml msgspec typing-extensions pybind11

cd "$SRC_DIR"
pip install --use-pep517 --no-build-isolation -e .
'

# 6. Configurazione iniziale del file settings.yml
echo "[*] Configurazione dei file di configurazione in /etc/searxng..."
mkdir -p "/etc/searxng"

if [ ! -f "/etc/searxng/settings.yml" ]; then
    cp "/usr/local/searxng/searxng-src/utils/templates/etc/searxng/settings.yml" "/etc/searxng/settings.yml"
    echo "[*] File /etc/searxng/settings.yml creato dal template."
else
    echo "[*] File /etc/searxng/settings.yml già presente, salto sovrascrittura."
fi

# Assegnazione permessi corretti alla cartella di configurazione
chown -R "searxng:searxng" "/etc/searxng"

echo "=============================================================================="
echo "[OK] Installazione di SearXNG completata con successo!"
echo "------------------------------------------------------------------------------"
echo " Per testare SearXNG in modalità standalone/debug, esegui:"
echo "   sudo -H -u searxng -i"
echo "   cd /usr/local/searxng/searxng-src"
echo "   python searx/webapp.py"
echo "------------------------------------------------------------------------------"
echo " Endpoint predefinito: http://127.0.0.1:8888"
echo "=============================================================================="
