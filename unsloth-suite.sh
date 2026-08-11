#!/usr/bin/env bash
# ==============================================================================
# UNSLOTH SUITE INSTALLER - DEBIAN 13 (TRIXIE)
# Correretto con OpenCode Nativo Ufficiale (https://opencode.ai/docs/it)
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ------------------------------------------------------------------------------
# 1. VERIFICA PRIVILEGI E RILEVAMENTO AMBIENTE
# ------------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    log_error "Questo script deve essere eseguito con i privilegi di root."
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~${REAL_USER}")

IS_CONTAINER=false
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -qa 'container=lxc' /proc/1/environ 2>/dev/null || grep -q 'lxc' /proc/1/cgroup 2>/dev/null; then
    IS_CONTAINER=true
fi

# ------------------------------------------------------------------------------
# 2. MENU INTERATTIVO DI SELEZIONE SERVIZI
# ------------------------------------------------------------------------------
clear
echo "=============================================================================="
echo "                   UNSLOTH SUITE INSTALLER - DEBIAN 13                        "
echo "=============================================================================="
echo "Nota: I prerequisiti base (mc, nvtop, nvidia-smi, uv, Locales, Node.js)"
echo "      e il driver/toolkit CUDA verranno installati automaticamente."
echo "------------------------------------------------------------------------------"
echo "Seleziona i servizi da installare (inserisci i numeri separati da spazio):"
echo "  1) Unsloth & Unsloth Studio (Porta 8888)"
echo "  2) ComfyUI                  (Porta 8188)"
echo "  3) OpenCode AI Web Service  (Porta 8000)"
echo "  4) Tutti i servizi sopra indicati"
echo "=============================================================================="
read -rp "Scelta: " -a USER_CHOICES

INSTALL_UNSLOTH=false
INSTALL_COMFY=false
INSTALL_OPENCODE=false

for choice in "${USER_CHOICES[@]}"; do
    case "$choice" in
        1) INSTALL_UNSLOTH=true ;;
        2) INSTALL_COMFY=true ;;
        3) INSTALL_OPENCODE=true ;;
        4) 
           INSTALL_UNSLOTH=true
           INSTALL_COMFY=true
           INSTALL_OPENCODE=true
           ;;
        *) log_warn "Opzione '$choice' non valida, ignorata." ;;
    esac
done

if [ "$INSTALL_UNSLOTH" = false ] && [ "$INSTALL_COMFY" = false ] && [ "$INSTALL_OPENCODE" = false ]; then
    log_error "Nessun servizio selezionato. Annullamento."
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. PULIZIA CONFIGURAZIONI PRECEDENTI
# ------------------------------------------------------------------------------
rm -f /etc/crypto-policies/back-ends/apt-sequoia.config
rm -f /etc/apt/sources.list.d/cuda*.list
rm -f /etc/apt/sources.list.d/nvidia*.list
mkdir -p /etc/apt/keyrings

# ------------------------------------------------------------------------------
# 4. STRUMENTI ESSENZIALI DI SISTEMA E NODE.JS (Richiesto per dipendenze Web)
# ------------------------------------------------------------------------------
log_info "Installazione pacchetti base di sistema e Node.js..."
apt update || true
apt install -y curl wget ca-certificates gnupg git build-essential netcat-openbsd locales mc nvtop htop \
    python3-full python3-pip python3-venv python3-setuptools python3-wheel

# Installazione Node.js Lts (utile per OpenCode e estensioni)
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

log_info "Configurazione globale dei Locales su en_US.UTF-8..."
sed -i '/^# *en_US.UTF-8 UTF-8/s/^# //' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 LANGUAGE=en_US.UTF-8

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LANGUAGE=en_US.UTF-8

# ------------------------------------------------------------------------------
# 5. REPOSITORY UFFICIALE NVIDIA
# ------------------------------------------------------------------------------
log_info "Configurazione repository NVIDIA CUDA..."
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/3bf863cc.pub | gpg --dearmor --yes -o /etc/apt/keyrings/cuda-archive-keyring.gpg
echo "deb [trusted=yes signed-by=/etc/apt/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/ /" > /etc/apt/sources.list.d/cuda-official.list

cat <<EOF > /etc/apt/preferences.d/nvidia-official-pin
Package: *
Pin: origin developer.download.nvidia.com
Pin-Priority: 1001
EOF

apt update

# ------------------------------------------------------------------------------
# 6. INSTALLAZIONE DRIVER NVIDIA & CUDA
# ------------------------------------------------------------------------------
if [ "$IS_CONTAINER" = false ]; then
    log_info "Ambiente Bare-Metal/VM: Installazione headers kernel e driver..."
    apt install -y dkms linux-headers-"$(uname -r)"
    cat <<EOF > /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF
    update-initramfs -u
    apt install -y cuda-drivers cuda-toolkit nvidia-smi || apt install -y cuda-drivers cuda-toolkit
else
    log_warn "Ambiente CONTAINER (LXC): Installazione solo CUDA Toolkit e utilità GPU."
    apt install -y cuda-toolkit nvidia-smi || apt install -y cuda-toolkit
fi

CUDA_PROFILE_SCRIPT="/etc/profile.d/cuda.sh"
cat <<'EOF' > "$CUDA_PROFILE_SCRIPT"
export PATH=/usr/local/cuda/bin${PATH:+:${PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
EOF
chmod +x "$CUDA_PROFILE_SCRIPT"

export PATH=/usr/local/cuda/bin${PATH:+:${PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}

# ------------------------------------------------------------------------------
# 7. INSTALLAZIONE ASTRAL UV
# ------------------------------------------------------------------------------
log_info "Installazione di 'uv'..."
if ! command -v uv &> /dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="${REAL_HOME}/.cargo/bin:${PATH}"
fi

# ------------------------------------------------------------------------------
# 8. INSTALLAZIONE UNSLOTH & UNSLOTH STUDIO (SE SELEZIONATO)
# ------------------------------------------------------------------------------
if [ "$INSTALL_UNSLOTH" = true ]; then
    UNSLOTH_DIR="${REAL_HOME}/unsloth_env"
    log_info "Installazione Unsloth e Unsloth Studio in: ${UNSLOTH_DIR}"

    su - "$REAL_USER" -c "
        export PATH=/usr/local/cuda/bin:\$PATH
        export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\$LD_LIBRARY_PATH
        uv venv ${UNSLOTH_DIR} --python 3.12 --seed
        source ${UNSLOTH_DIR}/bin/activate
        uv pip install --upgrade pip setuptools wheel
        uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
        uv pip install unsloth xformers trl peft accelerate bitsandbytes jupyterlab
    "

    cat <<EOF > /etc/systemd/system/unsloth-studio.service
[Unit]
Description=Unsloth Studio AI Service
After=network.target

[Service]
Type=simple
User=${REAL_USER}
WorkingDirectory=${REAL_HOME}
Environment="PATH=/usr/local/cuda/bin:${UNSLOTH_DIR}/bin:/usr/bin:/bin"
Environment="LD_LIBRARY_PATH=/usr/local/cuda/lib64"
Environment="LANG=en_US.UTF-8"
Environment="LC_ALL=en_US.UTF-8"
ExecStart=${UNSLOTH_DIR}/bin/jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --ServerApp.token='' --ServerApp.password='' --allow-root
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable unsloth-studio.service
    systemctl restart unsloth-studio.service
    log_ok "Servizio Unsloth Studio avviato sulla porta 8888!"
fi

# ------------------------------------------------------------------------------
# 9. INSTALLAZIONE COMFYUI (SE SELEZIONATO)
# ------------------------------------------------------------------------------
if [ "$INSTALL_COMFY" = true ]; then
    COMFY_DIR="${REAL_HOME}/ComfyUI"
    log_info "Installazione ComfyUI..."

    if [ ! -d "$COMFY_DIR" ]; then
        su - "$REAL_USER" -c "git clone https://github.com/comfyanonymous/ComfyUI.git ${COMFY_DIR}"
    fi

    su - "$REAL_USER" -c "
        export PATH=/usr/local/cuda/bin:\$PATH
        export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\$LD_LIBRARY_PATH
        cd ${COMFY_DIR}
        uv venv venv --python 3.12 --seed
        source venv/bin/activate
        uv pip install --upgrade pip setuptools wheel
        uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
        uv pip install -r requirements.txt
    "

    cat <<EOF > /etc/systemd/system/comfyui.service
[Unit]
Description=ComfyUI AI Service
After=network.target

[Service]
Type=simple
User=${REAL_USER}
WorkingDirectory=${COMFY_DIR}
Environment="PATH=/usr/local/cuda/bin:/usr/bin:/bin"
Environment="LD_LIBRARY_PATH=/usr/local/cuda/lib64"
Environment="LANG=en_US.UTF-8"
Environment="LC_ALL=en_US.UTF-8"
ExecStart=${COMFY_DIR}/venv/bin/python main.py --listen 0.0.0.0 --port 8188
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable comfyui.service
    systemctl restart comfyui.service
    log_ok "Servizio ComfyUI attivo sulla porta 8188!"
fi

# ------------------------------------------------------------------------------
# 10. INSTALLAZIONE OPENCODE AI (SECONDO GUIDA UFFICIALE OPENCODE.AI)
# ------------------------------------------------------------------------------
if [ "$INSTALL_OPENCODE" = true ]; then
    log_info "Installazione binario ufficiale OpenCode AI..."

    # Installazione binario OpenCode (supporta sia lo script install che npm)
    curl -fsSL https://opencode.ai/install | bash || npm install -g opencode-ai

    # Assicuriamo che il binario opencode sia raggiungibile globalmente in /usr/local/bin
    if [ -f "${REAL_HOME}/.opencode/bin/opencode" ]; then
        cp "${REAL_HOME}/.opencode/bin/opencode" /usr/local/bin/opencode
    elif [ -f "/root/.opencode/bin/opencode" ]; then
        cp "/root/.opencode/bin/opencode" /usr/local/bin/opencode
    fi
    chmod +x /usr/local/bin/opencode || true

    log_info "Creazione del servizio systemd per OpenCode Web..."

    cat <<EOF > /etc/systemd/system/opencode.service
[Unit]
Description=OpenCode AI Web Service
After=network.target

[Service]
Type=simple
User=${REAL_USER}
WorkingDirectory=${REAL_HOME}
Environment="PATH=/usr/local/cuda/bin:${REAL_HOME}/.opencode/bin:/usr/local/bin:/usr/bin:/bin"
Environment="LANG=en_US.UTF-8"
Environment="LC_ALL=en_US.UTF-8"
# Comando ufficiale secondo documentazione: opencode web con bind 0.0.0.0
ExecStart=/usr/local/bin/opencode web --hostname 0.0.0.0 --port 8000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable opencode.service
    systemctl restart opencode.service
    log_ok "Servizio OpenCode AI Web attivo sulla porta 8000!"
fi

# ------------------------------------------------------------------------------
# FIX PERMESSI FINALI
# ------------------------------------------------------------------------------
chown -R "$REAL_USER":"$REAL_USER" "$REAL_HOME"

# ------------------------------------------------------------------------------
# RIEPILOGO FINALE E CHECK STATO
# ------------------------------------------------------------------------------
log_info "Attesa di 10 secondi per l'avvio completo dei servizi..."
sleep 10

SERVER_IP=$(hostname -I | awk '{print $1}')
[ -z "$SERVER_IP" ] && SERVER_IP="localhost"

check_port() {
    local port=$1
    if nc -z -w 3 127.0.0.1 "$port" &>/dev/null; then
        echo -e "${GREEN}[OK - ATTIVO]${NC}"
    else
        echo -e "${RED}[FAIL - INATTIVO]${NC}"
    fi
}

echo "=============================================================================="
log_ok "INSTALLAZIONE COMPLETATA!"
echo "=============================================================================="

if [ "$INSTALL_UNSLOTH" = true ]; then
    echo -e " 1. Unsloth Studio: http://${SERVER_IP}:8888  $(check_port 8888)"
fi
if [ "$INSTALL_COMFY" = true ]; then
    echo -e " 2. ComfyUI:        http://${SERVER_IP}:8188  $(check_port 8188)"
fi
if [ "$INSTALL_OPENCODE" = true ]; then
    echo -e " 3. OpenCode Web:   http://${SERVER_IP}:8000  $(check_port 8000)"
fi

echo "=============================================================================="
