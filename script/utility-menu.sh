#!/usr/bin/env bash
# ==============================================================================
# Proxmox AI Deployer - Utility & Maintenance Menu
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

# ------------------------------------------------------------------------------
# FUNZIONI DI MANUTENZIONE
# ------------------------------------------------------------------------------

# 1. Pulizia Forzata VRAM
purge_vram() {
  clear
  log_info "Svuotamento VRAM e reset processi AI nei container..."
  
  for vmid in 100 102 103; do
    if pct status "$vmid" 2>/dev/null | grep -q "running"; then
      log_info "Arresto processi GPU su CT $vmid..."
      pct exec "$vmid" -- bash -c "killall -9 ollama llama-server python3 2>/dev/null || true"
      pct exec "$vmid" -- bash -c "systemctl restart ollama 2>/dev/null || true"
    fi
  done

  if command -v nvidia-smi &>/dev/null; then
    log_info "Reset GPU NVIDIA dell'host..."
    nvidia-smi --gpu-reset 2>/dev/null || log_warn "GPU Reset non supportato o VRAM già completamente libera."
  fi

  whiptail --title "Pulizia VRAM" --msgbox "Memoria VRAM liberata e servizi AI riavviati con successo!" 10 60
}

# 2. Status Monitor Hardware & GPU
monitor_gpu() {
  clear
  echo -e "${CYAN}=== MONITORAGGIO HARDWARE & GPU ===${NC}\n"
  
  if command -v nvidia-smi &>/dev/null; then
    echo -e "${GREEN}[NVIDIA SMI]${NC}"
    nvidia-smi
    echo ""
  fi

  if command -v rocm-smi &>/dev/null; then
    echo -e "${GREEN}[ROCm SMI]${NC}"
    rocm-smi
    echo ""
  fi

  if command -v vulkaninfo &>/dev/null; then
    echo -e "${GREEN}[Vulkan Summary]${NC}"
    vulkaninfo --summary 2>/dev/null | head -n 20 || true
    echo ""
  fi

  read -p "Premi [INVIO] per tornare al menu utility..."
}

# 3. Status dei Container LXC
status_containers() {
  clear
  echo -e "${CYAN}=== STATO CONTAINER LXC FABBRICA IA ===${NC}\n"
  
  for vmid in 99 100 101 102 103 104 200; do
    if pct status "$vmid" &>/dev/null; then
      STATUS=$(pct status "$vmid" | awk '{print $2}')
      NAME=$(pct config "$vmid" 2>/dev/null | awk -F': ' '/hostname/ {print $2}')
      echo -e "CT $vmid ($NAME): \033[1;32m$STATUS\033[0m"
    else
      echo -e "CT $vmid: \033[1;30mNON CREATO\033[0m"
    fi
  done
  echo ""
  read -p "Premi [INVIO] per tornare al menu utility..."
}

# 4. Aggiornamento Repo da GitHub
update_repo() {
  clear
  log_info "Aggiornamento del repository da GitHub..."
  cd /opt/homelab-ai-deployer 2>/dev/null || cd "$(dirname "$0")/.."
  git pull
  chmod +x *.sh script/*.sh 2>/dev/null || true
  whiptail --title "Aggiornamento" --msgbox "Repository aggiornato con successo all'ultima versione!" 10 60
}

# 5. Disinstallazione/Distruzione Container
uninstall_containers() {
  if whiptail --title "RIMOZIONE CONTAINER" --yesno "Sei SICURO di voler eliminare tutti i container LXC della Fabbrica IA (CT 99, 100, 101, 102, 103, 104, 200)?\n\nQuesta operazione cancellerà permanentemente tutti i dati nei container." 12 65; then
    clear
    log_warn "Distruzione container in corso..."
    for vmid in 99 100 101 102 103 104 200; do
      if pct status "$vmid" &>/dev/null; then
        log_info "Arresto e rimozione CT $vmid..."
        pct stop "$vmid" 2>/dev/null || true
        pct destroy "$vmid" 2>/dev/null || true
      fi
    done
    whiptail --title "Disinstallazione" --msgbox "Container rimossi con successo." 10 60
  fi
}

# ------------------------------------------------------------------------------
# INTERFACCIA MENU UTILITY
# ------------------------------------------------------------------------------
show_utility_menu() {
  CHOICE=$(whiptail --title "Proxmox AI - Menu Utility v2.0.0" \
    --menu "\nSeleziona un'operazione di manutenzione:" 20 78 6 \
    "1" "🧹  Liberazione Forzata VRAM (Kill Processi AI)" \
    "2" "📊  Monitoraggio Hardware & GPU (nvidia-smi / ROCm)" \
    "3" "📦  Stato Container LXC (PCT Status)" \
    "4" "🔄  Aggiorna Deployer da GitHub (Git Pull)" \
    "5" "🗑️  Rimuovi / Distruggi Container AI" \
    "6" "⬅️  Torna al Menu Principale" \
    3>&1 1>&2 2>&3) || true

  case "$CHOICE" in
    1) purge_vram ;;
    2) monitor_gpu ;;
    3) status_containers ;;
    4) update_repo ;;
    5) uninstall_containers ;;
    6|"") 
       if [ -f "./main.sh" ]; then exec ./main.sh
       elif [ -f "../main.sh" ]; then cd .. && exec ./main.sh
       else exit 0; fi
       ;;
  esac
}

while true; do
  show_utility_menu
done
