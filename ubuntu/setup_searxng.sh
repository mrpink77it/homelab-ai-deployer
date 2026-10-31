#!/usr/bin/env bash
set -euo pipefail

==============================================================================

Homelab AI Deployer - SearXNG Local Search Setup Script

==============================================================================

export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export PYTHONIOENCODING="utf-8"

echo "=== [1/7] Controllo privilegi di root ==="
if [ "$EUID" -ne 0 ]; then
echo "[-] Errore: Esegui questo script con sudo o come root."
exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "=== [2/7] Installazione dipendenze di sistema ==="
apt-get update -qq
apt-get install -y -qq 

python3-dev python3-babel python3-venv python-is-python3 

uwsgi uwsgi-plugin-python3 

git build-essential libxslt-dev zlib1g-dev libffi-dev libssl-dev 

locales

locale-gen en_US.UTF-8 C.UTF-8 >/dev/null 2>&1 || true
update-locale LANG=C.UTF-8 LC_ALL=C.UTF-8 >/dev/null 2>&1 || true

echo "=== [3/7] Creazione utente di sistema 'searxng' ==="
if ! id -u searxng &>/dev/null; then
useradd --shell /bin/bash --system 

--home-dir "/usr/local/searxng" 

--comment 'Privacy-respecting metasearch engine' 

searxng
echo "[+] Utente searxng creato."
else
echo "[*] Utente searxng già esistente."
fi

echo "=== [4/7] Preparazione directory di lavoro ==="
mkdir -p "/usr/local/searxng"
chown -R "searxng:searxng" "/usr/local/searxng"

echo "=== [5/7] Clonazione del repository SearXNG ==="
if [ ! -d "/usr/local/searxng/searxng-src" ]; then
sudo -H -u searxng git clone "https://github.com/searxng/searxng" "/usr/local/searxng/searxng-src"
else
echo "[*] Repository searxng già presente, eseguo pull..."
sudo -H -u searxng git -C "/usr/local/searxng/searxng-src" pull || true
fi

echo "=== [6/7] Configurazione Python Virtual Environment & Dipendenze ==="
if [ ! -d "/usr/local/searxng/searx-pyenv" ]; then
sudo -H -u searxng python3 -m venv "/usr/local/searxng/searx-pyenv"
fi

if ! grep -q "searx-pyenv/bin/activate" "/usr/local/searxng/.profile" 2>/dev/null; then
echo ". /usr/local/searxng/searx-pyenv/bin/activate" >> "/usr/local/searxng/.profile"
fi

sudo -H -u searxng bash << 'EOF'
. /usr/local/searxng/searx-pyenv/bin/activate
pip install -U pip setuptools wheel
pip install -U pyyaml msgspec typing-extensions pybind11
cd "/usr/local/searxng/searxng-src"
pip install --use-pep517 --no-build-isolation -e .
EOF

echo "=== [7/7] Configurazione file di impostazioni ==="
mkdir -p "/etc/searxng"
if [ -f "/usr/local/searxng/searxng-src/utils/templates/etc/searxng/settings.yml" ]; then
cp "/usr/local/searxng/searxng-src/utils/templates/etc/searxng/settings.yml" "/etc/searxng/settings.yml"
echo "[+] File settings.yml copiato in /etc/searxng/settings.yml"
fi

echo ""
echo "[OK] SearXNG installato con successo!"
echo " Per avviare manualmente in ambiente virtuale:"
echo "   sudo -H -u searxng -i"
echo "   . /usr/local/searxng/searx-pyenv/bin/activate"
echo "   python /usr/local/searxng/searxng-src/searx/webapp.py"
echo " Interfaccia locale prevista su: http://127.0.0.1:8888"
echo ""
