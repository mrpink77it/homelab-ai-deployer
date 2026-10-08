#!/usr/bin/env bash
# ==============================================================================
# Proxmox AI Deployer - Server Edition Setup (Headless Host Preparation)
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
  log_err "Questo script deve essere eseguito come root su Proxmox VE!"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log_info "Inizio preparazione Proxmox Host in modalità Server (Headless)..."

# 1. Configurazione Repository Proxmox (No-Subscription)
log_info "Configurazione repository PVE No-Subscription..."
if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
  sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list || true
  log_ok "Disabilitato repository pve-enterprise."
fi

if ! grep -q "pve-no-subscription" /etc/apt/sources.list; then
  DEBIAN_CODENAME=$(lsb_release -sc 2>/dev/null || echo "bookworm")
  echo "deb http://download.proxmox.com/debian/pve ${DEBIAN_CODENAME} pve-no-subscription" >> /etc/apt/sources.list
  log_ok "Aggiunto repository pve-no-subscription."
fi

# 2. Aggiornamento sistema e installazione dipendenze Host
log_info "Aggiornamento pacchetti e installazione PVE Headers..."
apt-get update -qq
apt-get install -y -qq "pve-headers-$(uname -r)" build-essential dkms pciutils wget curl git ca-certificates

# 3. Gestione e Blacklist Driver Open-Source (Nouveau)
GPU_MODE="${GPU_TYPE:-CPU}"

if [ "$GPU_MODE" = "NVIDIA" ] || [ "$GPU_MODE" = "MIXED_VULKAN" ]; then
  log_info "Disattivazione driver Nouveau per schede NVIDIA..."
  cat <<EOF > /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF
  update-initramfs -u -k all
fi

# 4. Installazione Driver GPU sull'Host Proxmox
log_info "Configurazione driver Host per la modalità: $GPU_MODE"

case "$GPU_MODE" in
  "NVIDIA")
    log_info "Installazione driver proprietari NVIDIA sull'host..."
    apt-get install -y -qq nvidia-driver nvidia-smi
    
    # Enable UVM (Unified Memory Management) per CUDA
    log_info "Abilitazione modulo nvidia-uvm..."
    if ! grep -q "nvidia-uvm" /etc/modules; then
      echo "nvidia-uvm" >> /etc/modules
    fi
    modprobe nvidia-uvm 2>/dev/null || true
    ;;

  "AMD")
    log_info "Installazione driver AMDGPU e firmware per host..."
    apt-get install -y -qq firmware-amd-graphics xserver-xorg-video-amdgpu
    ;;

  "MIXED_VULKAN")
    log_info "Installazione driver misti (NVIDIA + AMD) ed estensioni Vulkan sull'host..."
    apt-get install -y -qq nvidia-driver nvidia-smi firmware-amd-graphics xserver-xorg-video-amdgpu \
                       vulkan-tools libvulkan-dev
    if ! grep -q "nvidia-uvm" /etc/modules; then
      echo "nvidia-uvm" >> /etc/modules
    fi
    modprobe nvidia-uvm 2>/dev/null || true
    ;;

  *)
    log_warn "Nessuna GPU configurata sull'host o modalità CPU. Salto l'installazione dei driver grafici."
    ;;
esac

# 5. Moduli Kernel per Passthrough LXC (cgroup2)
log_info "Verifica configurazione cgroup2 e abilitazione moduli kernel..."
for module in vfio vfio_iommu_type1 vfio_pci; do
  if ! grep -q "$module" /etc/modules; then
    echo "$module" >> /etc/modules
  fi
done

log_ok "Host Proxmox preparato con successo per la Server Edition!"
echo -e "\n${YELLOW}[NOTA] Se è stata installata una GPU NVIDIA, è consigliato un riavvio dell'host prima di creare i container LXC.${NC}"
read -p "Vuoi riavviare l'host Proxmox adesso? (s/N): " REBOOT_CHOICE

if [[ "$REBOOT_CHOICE" =~ ^[Ss]$ ]]; then
  log_info "Riavvio in corso..."
  reboot
else
  log_info "Riavvio posposto. Ricorda di riavviare prima di lanciare il deploy dei container!"
fi
