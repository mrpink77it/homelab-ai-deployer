#!/usr/bin/env bash
# ==============================================================================
# Proxmox AI Deployer - Workstation Edition Setup (KDE + Drivers + Auto-Login)
# Repo: mrpink77it/homelab-ai-deployer
# Version: 2.0.0
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
  log_err "Questo script deve essere eseguito come root!"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log_info "Inizio configurazione Workstation Edition..."

# 1. Aggiornamento sistema e installazione Desktop Environment (KDE Plasma) + Chromium + SDDM
log_info "Installazione di KDE Plasma, Chromium e Display Manager SDDM..."
apt-get update -qq
apt-get install -y -qq kde-full chromium sddm xorg sudo curl git build-essential

# 2. Rilevamento Hardware e Installazione Driver Video
log_info "Rilevamento scheda grafica in corso..."
GPU_MODE="${GPU_TYPE:-CPU}"

case "$GPU_MODE" in
  "NVIDIA")
    log_info "Installazione driver proprietari NVIDIA e CUDA Toolkit..."
    apt-get install -y -qq nvidia-driver nvidia-cuda-toolkit nvidia-smi nvidia-vulkan-icd
    ;;
  "AMD")
    log_info "Installazione driver Open AMDGPU e Vulkan..."
    apt-get install -y -qq firmware-amd-graphics xserver-xorg-video-amdgpu mesa-vulkan-drivers
    ;;
  "MIXED_VULKAN")
    log_info "Rilevate GPU miste! Installazione driver AMD + NVIDIA + Runtime Vulkan Universale..."
    apt-get install -y -qq firmware-amd-graphics xserver-xorg-video-amdgpu mesa-vulkan-drivers \
                       nvidia-driver nvidia-cuda-toolkit nvidia-vulkan-icd vulkan-tools libvulkan-dev
    ;;
  "VULKAN")
    log_info "Rilevata iGPU Intel/Vulkan. Installazione MESA Vulkan..."
    apt-get install -y -qq intel-media-va-driver-non-free mesa-vulkan-drivers vulkan-tools
    ;;
  *)
    log_warn "Nessuna GPU dedicata rilevata. Configurazione con driver vesa/standard."
    ;;
esac

# 3. Creazione dell'utente 'user' (se non esiste) e configurazione password 'user'
if ! id -u user &>/dev/null; then
  log_info "Creazione dell'utente 'user'..."
  useradd -m -s /bin/bash user
  echo "user:user" | chpasswd
  usermod -aG sudo,video,render user
  log_ok "Utente 'user' creato con password 'user'."
else
  log_info "Utente 'user' già presente nel sistema."
fi

# 4. Configurazione Auto-Login in SDDM (KDE Plasma)
log_info "Configurazione Auto-login per l'utente 'user' su SDDM..."
mkdir -p /etc/sddm.conf.d
cat <<EOF > /etc/sddm.conf.d/autologin.conf
[Autologin]
User=user
Session=plasma
EOF

# 5. Configurazione Autostart TUI per l'Utente al primo login desktop
log_info "Configurazione avvio automatico del Deployer al primo login su KDE..."
USER_AUTOSTART="/home/user/.config/autostart"
mkdir -p "$USER_AUTOSTART"
chown -R user:user /home/user/.config

cat <<EOF > "$USER_AUTOSTART/proxmox-ai-deployer.desktop"
[Desktop Entry]
Type=Application
Name=Proxmox AI Deployer
Exec=konsole -e bash -c "cd /opt/homelab-ai-deployer && sudo ./main.sh"
Icon=utilities-terminal
Terminal=false
Categories=System;
EOF
chown user:user "$USER_AUTOSTART/proxmox-ai-deployer.desktop"
chmod +x "$USER_AUTOSTART/proxmox-ai-deployer.desktop"

# 6. Abilitazione e avvio del display manager
systemctl set-default graphical.target
systemctl enable sddm

log_ok "Configurazione Workstation completata con successo!"
echo -e "\n${GREEN}Il sistema verrà riavviato per accedere direttamente al desktop KDE.${NC}"
read -p "Premi [INVIO] per riavviare ora..."
reboot
