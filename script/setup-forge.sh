#!/bin/bash
# ==============================================================================
# Installazione Stable Diffusion WebUI Forge (Fix Python 3.10 Definitivo)
# Ambiente: Bare-Metal / LXC (Debian 13)
# ==============================================================================

set -euo pipefail

FORGE_DIR="/opt/sd-forge"
SERVICE_FILE="/etc/systemd/system/homelab-ai-forge.service"

echo "[1/5] Pulizia totale installazione precedente..."
systemctl stop homelab-ai-forge 2>/dev/null || true
systemctl disable homelab-ai-forge 2>/dev/null || true
rm -f "$SERVICE_FILE"
rm -rf "$FORGE_DIR"
systemctl daemon-reload

echo "[2/5] Installazione di Python 3.10 e dipendenze di sistema su Debian 13..."
apt-get update -y
# Installiamo i repository alternativi o il pacchetto python3.10 se disponibile, oppure usiamo uv per scaricare il binario isolato di python
apt-get install -y wget git libgl1 libglib2.0-0 bc curl psmisc google-perftools python3-full

echo "[3/5] Installazione di 'uv' e generazione forzata di Python 3.10..."
curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh

# Creazione utente forge se non esiste
if ! id -u forge > /dev/null 2>&1; then
    useradd -r -m -s /bin/false forge
fi
mkdir -p "$FORGE_DIR"
chown -R forge:forge "$FORGE_DIR" /home/forge

# Clonazione repository come utente forge
su -s /bin/bash forge -c "git clone https://github.com/lllyasviel/stable-diffusion-webui-forge.git \"$FORGE_DIR\""

echo "[4/5] Creazione venv isolato con Python 3.10 gestito da uv e pre-configurazione CLIP..."
# Forziamo uv a scaricare e utilizzare specificamente Python 3.10.14 isolato nel venv
su -s /bin/bash forge -c "cd $FORGE_DIR && uv venv --python 3.10.14 --seed venv"

# Downgrade di setuptools ed eliminazione ostacoli CLIP
su -s /bin/bash forge -c "cd $FORGE_DIR && venv/bin/pip install 'setuptools<70' ftfy regex tqdm"
su -s /bin/bash forge -c "cd $FORGE_DIR && venv/bin/pip install --no-build-isolation --no-deps https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip"

echo "[5/5] Configurazione e avvio del servizio Systemd..."
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Stable Diffusion WebUI Forge (Homelab AI)
After=network.target

[Service]
Type=simple
User=forge
WorkingDirectory=$FORGE_DIR
Environment="PYTHON=$FORGE_DIR/venv/bin/python"
Environment="PIP_NO_BUILD_ISOLATION=1"
ExecStart=/bin/bash $FORGE_DIR/webui.sh --api --listen --port 7860
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now homelab-ai-forge

echo "Fatto! Ora puoi monitorare l'avvio pulito con:"
echo "journalctl -u homelab-ai-forge -f"
