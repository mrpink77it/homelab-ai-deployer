#!/usr/bin/env bash
# ==============================================================================
# Script: uninstall.sh
# Versione: 1.0.0
# Descrizione: Disinstallazione e pulizia universale suite Homelab AI
# Supporto: AMD, NVIDIA, CPU-Only (Bare-Metal & LXC)
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${RED}=================================================================${NC}"
echo -e "${RED} ATTENZIONE: DISINSTALLAZIONE COMPLETA HOMELAB AI${NC}"
echo -e "${RED}=================================================================${NC}"
echo -e "Questa operazione eliminerà definitivamente:"
echo -e " - Servizi systemd (Backend e Frontend)"
echo -e " - Directory di installazione (/opt/homelab-ai)"
echo -e " - Tutti i modelli GGUF scaricati"
echo -e " - Log di sistema e cache (pip, uv, ccache)"
echo -e ""

read -rp "Sei assolutamente sicuro di voler procedere? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Operazione annullata.${NC}"
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERRORE] Lo script richiede i privilegi di root. Avvialo con sudo.${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# Rilevamento Hardware
# ------------------------------------------------------------------------------
detect_hardware() {
    local pci_info
    pci_info=$(lspci | grep -iE 'vga|3d|display' 2>/dev/null || true)
    
    if echo "$pci_info" | grep -qi 'nvidia'; then
        echo "NVIDIA"
    elif echo "$pci_info" | grep -qi 'amd'; then
        echo "AMD"
    else
        echo "CPU"
    fi
}

HW_TYPE=$(detect_hardware)
echo -e "\n${CYAN}>>> Rilevamento hardware completato: Profilo [${HW_TYPE}]${NC}"

# ------------------------------------------------------------------------------
# Pulizia Comune (Tutti gli ambienti)
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}[1/5] Arresto e disabilitazione servizi systemd...${NC}"
systemctl stop homelab-ai-backend homelab-ai-frontend 2>/dev/null || true
systemctl disable homelab-ai-backend homelab-ai-frontend 2>/dev/null || true
rm -f /etc/systemd/system/homelab-ai-backend.service
rm -f /etc/systemd/system/homelab-ai-frontend.service
systemctl daemon-reload

echo -e "\n${GREEN}[2/5] Rimozione directory e log...${NC}"
rm -rf /opt/homelab-ai
rm -f /var/log/homelab-ai-*.log

echo -e "\n${GREEN}[3/5] Rimozione gestore pacchetti UV isolato...${NC}"
rm -f /root/.cargo/bin/uv /root/.cargo/bin/uvx
rm -f /root/.local/bin/uv /root/.local/bin/uvx
rm -f /home/*/.cargo/bin/uv /home/*/.cargo/bin/uvx 2>/dev/null || true
rm -f /home/*/.local/bin/uv /home/*/.local/bin/uvx 2>/dev/null || true

echo -e "\n${GREEN}[4/5] Svuotamento cache di compilazione e pacchetti...${NC}"
rm -rf /root/.cache/ccache /root/.cache/pip /root/.cache/uv
rm -rf /home/*/.cache/ccache /home/*/.cache/pip /home/*/.cache/uv 2>/dev/null || true

# ------------------------------------------------------------------------------
# Pulizia Specifica per Hardware
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}[5/5] Esecuzione pulizia specifica per architettura [${HW_TYPE}]...${NC}"

case "${HW_TYPE}" in
    "AMD")
        # Rimuove le preferenze apt e i repo di ROCm iniettati da manager-amd.sh
        echo -e "${YELLOW} -> Rimozione iniezioni repository ROCm...${NC}"
        rm -f /etc/apt/sources.list.d/rocm.list
        rm -f /etc/apt/sources.list.d/amdgpu.list
        rm -f /etc/apt/preferences.d/99-rocm-amd
        rm -f /etc/apt/keyrings/rocm.gpg
        ;;
    "NVIDIA")
        # Predisposto per la rimozione di repo CUDA o configurazioni toolkit specifiche per manager-nvidia.sh
        echo -e "${YELLOW} -> Rimozione configurazioni specifiche CUDA/NVIDIA...${NC}"
        # rm -f /etc/apt/sources.list.d/cuda*.list 2>/dev/null || true
        ;;
    "CPU")
        echo -e "${YELLOW} -> Nessuna configurazione repository GPU esterna da rimuovere per CPU-Only.${NC}"
        ;;
esac

# ------------------------------------------------------------------------------
# Pulizia APT Finale
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}>>> Ottimizzazione pacchetti APT...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null 2>&1 || true
apt-get autoremove --purge -y
apt-get clean

echo -e "\n${GREEN}=================================================================${NC}"
echo -e "${GREEN} Disinstallazione completata con successo!${NC}"
echo -e "${GREEN} Il sistema è tornato a uno stato pulito.${NC}"
echo -e "${GREEN}=================================================================${NC}"
