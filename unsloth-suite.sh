#!/usr/bin/env bash
# ==============================================================================
# UNSLOTH SUITE INSTALLER - DEBIAN 13 (TRIXIE)
# Supporto automatico Bare Metal e Container LXC/Proxmox
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
# 1. VERIFICA PRIVILEGI E RILEVAMENTO AMBIENTE (LXC / CONTAINER)
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

log_info "Avvio installazione Unsloth Suite su Debian 13 per l'utente: ${REAL_USER}"
if [ "$IS_CONTAINER" = true ]; then
    log_warn "Rilevato ambiente CONTAINER (LXC/Proxmox). L'installazione dei linux-headers e dei moduli kernel DKMS verrà saltata."
else
    log_info "Rilevato ambiente Macchina Reale / VM (Bare-Metal)."
fi

# ------------------------------------------------------------------------------
# 2. PULIZIA CONFIGURAZIONI PRECEDENTI
# ------------------------------------------------------------------------------
rm -f /etc/crypto-policies/back-ends/apt-sequoia.config
rm -f /etc/apt/sources.list.d/cuda*.list
rm -f /etc/apt/sources.list.d/nvidia*.list

mkdir -p /etc/apt/keyrings

# ------------------------------------------------------------------------------
# 3. STRUMENTI ESSENZIALI DI SISTEMA
# ------------------------------------------------------------------------------
log_info "Installazione pacchetti base (curl, wget, ca-certificates)..."
apt update || true
apt install -y curl wget ca-certificates gnupg

# ------------------------------------------------------------------------------
# 4. REPOSITORY UFFICIALE NVIDIA (CON FIX SQV PER DEBIAN 13)
# ------------------------------------------------------------------------------
log_info "Scaricamento della chiave GPG ufficiale NVIDIA..."
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/3bf863cc.pub | gpg --dearmor --yes -o /etc/apt/keyrings/cuda-archive-keyring.gpg

log_info "Configurazione sorgente repository CUDA NVIDIA..."
echo "deb [trusted=yes signed-by=/etc/apt/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/ /" > /etc/apt/sources.list.d/cuda-official.list

log_info "Configurazione priorità APT (Pinning)..."
cat <<EOF > /etc/apt/preferences.d/nvidia-official-pin
Package: *
Pin: origin developer.download.nvidia.com
Pin-Priority: 1001
EOF

apt update

# ------------------------------------------------------------------------------
# 5. INSTALLAZIONE DIPENDENZE E DRIVER NVIDIA / CUDA
# ------------------------------------------------------------------------------
if [ "$IS_CONTAINER" = false ]; then
    log_info "Installazione linux-headers e strumenti DKMS per Macchina Fisica/VM..."
    apt install -y build-essential dkms linux-headers-"$(uname -r)" python3-pip python3-venv git

    log_info "Disabilitazione Nouveau..."
    cat <<EOF > /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF
    update-initramfs -u

    log_info "Installazione completa Driver Kernel + CUDA..."
    apt install -y cuda-drivers cuda-toolkit
else
    log_info "Installazione dipendenze base Python/Git in container LXC..."
    apt install -y build-essential python3-pip python3-venv git

    log_info "Installazione CUDA Toolkit in container LXC (Userland Only)..."
    # In LXC installiamo solo il Toolkit CUDA. I driver del kernel sono gestiti dall'host Proxmox.
    apt install -y cuda-toolkit
fi

log_info "Configurazione delle variabili d'ambiente CUDA..."
CUDA_PROFILE_SCRIPT="/etc/profile.d/cuda.sh"
cat <<'EOF' > "$CUDA_PROFILE_SCRIPT"
export PATH=/usr/local/cuda/bin${PATH:+:${PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}
EOF
chmod +x "$CUDA_PROFILE_SCRIPT"

export PATH=/usr/local/cuda/bin${PATH:+:${PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}

log_ok "CUDA Toolkit e componenti NVIDIA installati con successo!"

# ------------------------------------------------------------------------------
# 6. INSTALLAZIONE ASTRAL UV
# ------------------------------------------------------------------------------
log_info "Installazione di 'uv' per la gestione dell'ambiente Python..."
if ! command -v uv &> /dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="${REAL_HOME}/.cargo/bin:${PATH}"
fi

# ------------------------------------------------------------------------------
# 7. CREAZIONE VIRTUALENV E INSTALLAZIONE UNSLOTH / UNSLOTH STUDIO
# ------------------------------------------------------------------------------
INSTALL_DIR="${REAL_HOME}/unsloth_env"
log_info "Creazione virtualenv Python con 'uv' in: ${INSTALL_DIR}"

su - "$REAL_USER" -c "
    export PATH=/usr/local/cuda/bin:\$PATH
    export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\$LD_LIBRARY_PATH
    
    uv venv ${INSTALL_DIR} --python 3.12
    source ${INSTALL_DIR}/bin/activate

    echo '[INFO] Installazione PyTorch, Unsloth e dipendenze via uv...'
    uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
    uv pip install unsloth xformers trl peft accelerate bitsandbytes
"

# ------------------------------------------------------------------------------
# 8. SCRIPT DI AVVIO UNSLOTH STUDIO
# ------------------------------------------------------------------------------
LAUNCHER_SCRIPT="${REAL_HOME}/start-unsloth-studio.sh"
log_info "Creazione dello script di avvio in: ${LAUNCHER_SCRIPT}"

cat <<EOF > "$LAUNCHER_SCRIPT"
#!/usr/bin/env bash
export PATH=/usr/local/cuda/bin:\$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\$LD_LIBRARY_PATH

source "${INSTALL_DIR}/bin/activate"

echo "=== Avvio di Unsloth Studio ==="
echo "Accessibile via browser su: http://127.0.0.1:8888"
unsloth studio -H 0.0.0.0 -p 8888
EOF

chmod +x "$LAUNCHER_SCRIPT"
chown "$REAL_USER":"$REAL_USER" "$LAUNCHER_SCRIPT"
chown -R "$REAL_USER":"$REAL_USER" "$INSTALL_DIR"

# ------------------------------------------------------------------------------
# COMPLETAMENTO
# ------------------------------------------------------------------------------
echo "=============================================================================="
log_ok "INSTALLAZIONE COMPLETATA SENZA ERRORI!"
echo "=============================================================================="
if [ "$IS_CONTAINER" = true ]; then
    echo "NOTA LXC: Assicurati che i device della GPU NVIDIA (/dev/nvidia*) siano traspassati"
    echo "         dall'host Proxmox al container LXC."
fi
echo "Per avviare Unsloth Studio:"
echo "  ${LAUNCHER_SCRIPT}"
echo "=============================================================================="
