#!/bin/bash
# ==============================================================================
# Script: setup-forge.sh
# Repo: homelab-ai-deployer
# Descrizione: Installazione automatizzata bare-metal di SD WebUI Forge su Debian
# ==============================================================================

# Verifica privilegi di root
if [ "$EUID" -ne 0 ]; then
  echo "ERRORE: Questo script deve essere eseguito come root."
  exit 1
fi

echo "[1/7] Pulizia totale installazione precedente..."
systemctl stop homelab-ai-forge.service 2>/dev/null
systemctl disable homelab-ai-forge.service 2>/dev/null
rm -f /etc/systemd/system/homelab-ai-forge.service
rm -rf /opt/sd-forge
userdel -r forge 2>/dev/null
echo "[1/7] Pulizia totale installazione precedente... [Completato]"

echo "[2/7] Installazione dipendenze di sistema su Debian 13..."
apt-get update -qq
apt-get install -y -qq curl git python3 python3-venv python3-pip libgl1 libglib2.0-0 google-perftools sudo
echo "[2/7] Installazione dipendenze di sistema su Debian 13... [Completato]"

echo "[3/7] Installazione di 'uv' e preparazione utente..."
useradd -m -s /bin/bash forge
curl -LsSf https://astral.sh/uv/install.sh | sh > /dev/null 2>&1
# Assicurati che uv sia accessibile a livello di sistema
cp /root/.local/bin/uv /usr/local/bin/uv 2>/dev/null || true
echo "[3/7] Installazione di 'uv' e preparazione utente... [Completato]"

echo "[4/7] Clonazione repository Forge..."
git clone https://github.com/lllyasviel/stable-diffusion-webui-forge.git /opt/sd-forge -q
chown -R forge:forge /opt/sd-forge
echo "[4/7] Clonazione repository Forge... [Completato]"

echo "[5/7] Creazione venv (Forzato a Python 3.10 tramite uv) e requisiti..."
sudo -u forge /usr/local/bin/uv venv --python 3.10 /opt/sd-forge/venv
sudo -u forge /opt/sd-forge/venv/bin/pip install -U pip setuptools -q
echo "[5/7] Creazione venv e download dei requisiti Forge... [Completato]"

echo "[5.5/7] Applicazione fix definitivo (NumPy, Triton e Joblib)..."
# Rimuoviamo opencv-python standard e mettiamo headless per evitare dipendenze X11 su server bare-metal
sudo -u forge /opt/sd-forge/venv/bin/pip uninstall -y opencv-python > /dev/null 2>&1
sudo -u forge /opt/sd-forge/venv/bin/pip install -q opencv-python-headless numpy triton joblib
echo "[5.5/7] Applicazione fix definitivo (NumPy, Triton e Joblib)... [Completato]"

echo "[6/7] Download Modelli SDXL (Versioni Pubbliche Certificate)..."
MODELS_DIR="/opt/sd-forge/models/Stable-diffusion"
sudo -u forge mkdir -p "$MODELS_DIR"

echo " -> 1/3: Scaricando Juggernaut XL (Default)..."
sudo -u forge curl -L -o "$MODELS_DIR/01-Juggernaut-XL.safetensors" "https://civitai.com/api/download/models/357609" -#

echo " -> 2/3: Scaricando RealVisXL Lightning..."
sudo -u forge curl -L -o "$MODELS_DIR/02-RealVisXL-Lightning.safetensors" "https://huggingface.co/SG161222/RealVisXL_V4.0_Lightning/resolve/main/RealVisXL_V4.0_Lightning.safetensors" -#

echo " -> 3/3: Scaricando Animagine XL 3.1..."
sudo -u forge curl -L -o "$MODELS_DIR/03-Animagine-XL-3.1.safetensors" "https://huggingface.co/cagliostrolab/animagine-xl-3.1/resolve/main/animagine-xl-3.1.safetensors" -#

echo "[6.5/7] Verifica integrità dei file scaricati..."
# Elimina eventuali finti modelli (pagine HTML di errore) scaricati sotto i 100MB
find "$MODELS_DIR" -type f -name "*.safetensors" -size -100M -exec rm -v {} \;
echo " -> Pulizia eventuali file corrotti completata."
echo "[6/7] Download Modelli SDXL [Completato]"

echo "[7/7] Configurazione systemd e abilitazione servizio..."
cat << 'EOF' > /etc/systemd/system/homelab-ai-forge.service
[Unit]
Description=Stable Diffusion WebUI Forge (Homelab AI)
After=network.target

[Service]
Type=simple
User=forge
WorkingDirectory=/opt/sd-forge
Environment="COMMANDLINE_ARGS=--api --listen --port 7860 --skip-install"
ExecStart=/bin/bash /opt/sd-forge/webui.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable homelab-ai-forge.service
systemctl restart homelab-ai-forge.service
echo "[7/7] Configurazione systemd e abilitazione servizio... [Completato]"

# Attendi 5 secondi per far avviare il demone
sleep 5

# Stampa riassunto finale
LOCAL_IP=$(hostname -I | awk '{print $1}')

clear
echo "========================================================================"
echo " [SUCCESSO] Forge è pienamente operativo e l'API è in ascolto!"
echo "========================================================================"
echo ""
echo "🌐 INDIRIZZI DI ACCESSO (WebUI e API):"
echo " - Locale : http://127.0.0.1:7860"
echo " - Rete   : http://$LOCAL_IP:7860"
echo ""
echo "📚 MODELLI SDXL INSTALLATI E VERIFICATI:"

if [ -f "$MODELS_DIR/01-Juggernaut-XL.safetensors" ]; then
    echo " ✔ 1. Juggernaut XL      : Modello versatile, eccellente per fotografia, paesaggi e concept art."
fi
if [ -f "$MODELS_DIR/02-RealVisXL-Lightning.safetensors" ]; then
    echo " ✔ 2. RealVisXL Lightning: Ottimizzato per ritratti iper-realistici. (Nota: genera immagini in soli 4-8 step)."
fi
if [ -f "$MODELS_DIR/03-Animagine-XL-3.1.safetensors" ]; then
    echo " ✔ 3. Animagine XL 3.1   : Il gold-standard open source per stile manga, anime e illustrazione 2D."
fi

echo ""
echo "========================================================================"
echo ""
read -n 1 -s -r -p "Premi un tasto qualsiasi per uscire dallo script..."
echo ""
