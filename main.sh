#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Main Dispatcher TUI
# Repo: mrpink77it/homelab-ai-deployer
# Version: V.1.1.0
# ==============================================================================

set -e

# Format e Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BG_CYAN='\033[46;30m' # Sfondo Ciano, Testo Nero per selezione

# Controllo Permessi Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Questo script deve essere eseguito come root!${NC}"
  echo -e "${YELLOW}Usa: sudo ./main.sh${NC}"
  exit 1
fi

# Assegna permessi di esecuzione
chmod +x manager-*.sh uninstall.sh purge-homelab-ai.sh 2>/dev/null || true

# ------------------------------------------------------------------------------
# DIAGNOSTICA HARDWARE
# ------------------------------------------------------------------------------
HAS_NVIDIA=false
HAS_AMD=false
SELECTED_INDEX=2 # Default a CPU-Only

echo -e "${YELLOW}Ricerca hardware in corso...${NC}"

if lspci | grep -iq "NVIDIA" || [ -d "/proc/driver/nvidia" ] || command -v nvidia-smi &> /dev/null; then
    HAS_NVIDIA=true
    SELECTED_INDEX=0 # Posiziona su NVIDIA
elif lspci | grep -i "vga\|3d\|display" | grep -iq "AMD\|Radeon" || [ -d "/sys/module/amdgpu" ]; then
    HAS_AMD=true
    SELECTED_INDEX=1 # Posiziona su AMD
fi

# ------------------------------------------------------------------------------
# FUNZIONI DI GESTIONE E AVVIO
# ------------------------------------------------------------------------------
run_script() {
    local script_name=$1
    if [ -f "./$script_name" ]; then
        clear
        echo -e "${CYAN}Avvio di $script_name in corso...${NC}\n"
        sleep 1
        exec "./$script_name"
    else
        clear
        echo -e "${RED}[ERROR] File $script_name non trovato!${NC}"
        echo -e "${YELLOW}Assicurati di essere nella root della repository e che il file esista.${NC}"
        exit 1
    fi
}

# Array delle opzioni del menu
OPTIONS=(
    "🟢 AMBIENTE NVIDIA      (manager-nvidia.sh)"
    "🔴 AMBIENTE AMD         (manager-amd.sh)"
    "⚪ AMBIENTE CPU-ONLY    (manager-cpu.sh)"
    "🛠️  MODULO FINE-TUNING   (manager-finetuning.sh)"
    "🗑️  DISINSTALLA SERVIZI  (uninstall.sh)"
    "💥 PURGE ESTREMO        (purge-homelab-ai.sh)"
    "🚪 ESCI"
)
NUM_OPTIONS=${#OPTIONS[@]}

# ------------------------------------------------------------------------------
# RENDER DEL MENU INTERATTIVO
# ------------------------------------------------------------------------------
render_menu() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}         🦥 HOMELAB AI DEPLOYER - MAIN MENU        ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    
    # Mostra l'hardware rilevato per rassicurare l'utente
    if [ "$HAS_NVIDIA" = true ]; then
        echo -e " ${YELLOW}Hardware Rilevato:${NC} ${GREEN}GPU NVIDIA${NC} (Consigliato)"
    elif [ "$HAS_AMD" = true ]; then
        echo -e " ${YELLOW}Hardware Rilevato:${NC} ${RED}GPU AMD${NC} (Consigliato)"
    else
        echo -e " ${YELLOW}Hardware Rilevato:${NC} ${CYAN}Nessuna GPU / CPU-Only${NC}"
    fi
    echo -e "${BLUE}----------------------------------------------------${NC}"

    for i in "${!OPTIONS[@]}"; do
        if [ "$i" -eq "$SELECTED_INDEX" ]; then
            # Opzione Selezionata
            echo -e " ${BG_CYAN} ➔  ${OPTIONS[$i]} ${NC}"
        else
            # Opzione Deselezionata
            echo -e "    ${OPTIONS[$i]} "
        fi
    done

    echo -e "${BLUE}====================================================${NC}"
    echo -e "Usa le frecce direzionali ${YELLOW}[↑]${NC} e ${YELLOW}[↓]${NC} per muoverti."
    echo -e "Premi ${YELLOW}[INVIO]${NC} per confermare."
}

# ------------------------------------------------------------------------------
# LOOP DI NAVIGAZIONE
# ------------------------------------------------------------------------------
while true; do
    render_menu
    
    # Cattura input dei tasti
    read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        # Legge sequenze di escape per le frecce direzionali
        read -rsn2 -t 0.1 seq
        if [[ $seq == "[A" ]]; then
            # Freccia Su
            ((SELECTED_INDEX--))
            if [ "$SELECTED_INDEX" -lt 0 ]; then SELECTED_INDEX=$((NUM_OPTIONS - 1)); fi
        elif [[ $seq == "[B" ]]; then
            # Freccia Giù
            ((SELECTED_INDEX++))
            if [ "$SELECTED_INDEX" -ge "$NUM_OPTIONS" ]; then SELECTED_INDEX=0; fi
        fi
    elif [[ $key == "" ]]; then
        # Tasto INVIO
        break
    fi
done

# ------------------------------------------------------------------------------
# AZIONE IN BASE ALLA SELEZIONE
# ------------------------------------------------------------------------------
case $SELECTED_INDEX in
    0) run_script "manager-nvidia.sh" ;;
    1) run_script "manager-amd.sh" ;;
    2) run_script "manager-cpu.sh" ;;
    3) run_script "manager-finetuning.sh" ;;
    4) run_script "uninstall.sh" ;;
    5) run_script "purge-homelab-ai.sh" ;;
    6) clear; echo -e "${GREEN}Uscita dal deployer. A presto!${NC}"; exit 0 ;;
esac
