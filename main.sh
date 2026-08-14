#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Main Entrypoint Router (main.sh)
# Hardware Discovery & Automated Controller Delegation
# ==============================================================================

set -e

# Determination of Script Directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Palette Colori & Stili ANSI ---
BOLD='\033[1m'
RESET='\033[0m'

C_CYAN='\033[38;5;38m'
C_BLUE='\033[38;5;32m'
C_GREEN='\033[38;5;42m'
C_YELLOW='\033[38;5;214m'
C_RED='\033[38;5;196m'
C_PURPLE='\033[38;5;141m'
C_GRAY='\033[38;5;242m'
C_WHITE='\033[38;5;255m'

# --- Componenti Grafici ---
show_header() {
    clear
    echo -e "${C_CYAN}┌────────────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${C_CYAN}│${RESET}  ${BOLD}${C_WHITE}H O M E L A B   A I   D E P L O Y E R${RESET}  │  ${BOLD}${C_PURPLE}A U T O - R O U T E R${RESET}    ${C_CYAN}│${RESET}"
    echo -e "${C_CYAN}│${RESET}  ${C_GRAY}Zero-Config Hardware Discovery & AI Environment Orchestrator${RESET}         ${C_CYAN}│${RESET}"
    echo -e "${C_CYAN}└────────────────────────────────────────────────────────────────────────┘${RESET}"
    echo ""
}

show_about() {
    echo -e "  ${BOLD}${C_PURPLE}❖ INFORMAZIONI SUL PROGETTO${RESET}"
    echo -e "  ${C_GRAY}┌────────────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${C_WHITE}Homelab AI Deployer è uno stack automatizzato per l'infrastruttura   ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${C_WHITE}di AI locale. Rileva l'hardware presente (NVIDIA / AMD / CPU) e      ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${C_WHITE}configura i controller dedicati, i driver accelerati (CUDA/Vulkan) ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${C_WHITE}e i backend d'inferenza (llama.cpp, Unsloth, PyTorch).              ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}└────────────────────────────────────────────────────────────────────────┘${RESET}\n"
}

# --- Verifiche Iniziali ---
if [ "$EUID" -ne 0 ]; then
    show_header
    echo -e "  ${C_RED}✖ PERMESSI INSUFFICIENTI${RESET}"
    echo -e "  ${C_GRAY}Esegui lo script con privilegi di root: ${C_WHITE}sudo ./main.sh${RESET}\n"
    exit 1
fi

show_header
show_about

echo -e "  ${BOLD}${C_CYAN}❖ ANALISI HARDWARE IN CORSO...${RESET}\n"

# Detection GPU Logic
GPU_TYPE="CPU"
GPU_INFO=""
TARGET_SCRIPT=""

if lspci | grep -iE 'vga|3d|display' | grep -i 'nvidia' > /dev/null 2>&1; then
    GPU_TYPE="NVIDIA"
    GPU_INFO=$(lspci | grep -iE 'vga|3d|display' | grep -i 'nvidia' | head -n 1 | cut -d ':' -f3 | sed 's/^[ \t]*//')
    TARGET_SCRIPT="${SCRIPT_DIR}/manager-nvidia.sh"
elif lspci | grep -iE 'vga|3d|display' | grep -iE 'amd|radeon' > /dev/null 2>&1; then
    GPU_TYPE="AMD"
    GPU_INFO=$(lspci | grep -iE 'vga|3d|display' | grep -iE 'amd|radeon' | head -n 1 | cut -d ':' -f3 | sed 's/^[ \t]*//')
    TARGET_SCRIPT="${SCRIPT_DIR}/manager-amd.sh"
else
    GPU_TYPE="CPU"
    GPU_INFO="Nessuna GPU dedicata rilevata (Modalità CPU Nativa)"
    TARGET_SCRIPT="${SCRIPT_DIR}/manager-cpu.sh"
fi

# Visualizzazione Risultati
case $GPU_TYPE in
    NVIDIA)
        echo -e "  ${C_GREEN}✔ HARDWARE RILEVATO:${RESET} ${BOLD}${C_WHITE}GPU NVIDIA GEFORCE / QUADRO${RESET}"
        echo -e "  ${C_GRAY}  Scheda :${RESET} ${GPU_INFO}"
        echo -e "  ${C_GRAY}  Stack  :${RESET} ${C_CYAN}CUDA / TensorRT / llama.cpp / Unsloth${RESET}\n"
        ;;
    AMD)
        echo -e "  ${C_GREEN}✔ HARDWARE RILEVATO:${RESET} ${BOLD}${C_WHITE}GPU AMD RADEON${RESET}"
        echo -e "  ${C_GRAY}  Scheda :${RESET} ${GPU_INFO}"
        echo -e "  ${C_GRAY}  Stack  :${RESET} ${C_CYAN}ROCm / Vulkan (RADV) / llama.cpp${RESET}\n"
        ;;
    CPU)
        echo -e "  ${C_YELLOW}⚠ HARDWARE RILEVATO:${RESET} ${BOLD}${C_WHITE}ACCELERAZIONE CPU ONLY${RESET}"
        echo -e "  ${C_GRAY}  Note   :${RESET} ${GPU_INFO}"
        echo -e "  ${C_GRAY}  Stack  :${RESET} ${C_CYAN}OpenMP / AVX2 / AVX-512 / llama.cpp CPU${RESET}\n"
        ;;
esac

# Verifica esistenza dello script target
if [ ! -f "$TARGET_SCRIPT" ]; then
    echo -e "  ${C_RED}✖ ERRORE ROUTING:${RESET} Impossibile trovare il controller ${C_WHITE}${TARGET_SCRIPT}${RESET}\n"
    exit 1
fi

echo -e "  ${C_GRAY}────────────────────────────────────────────────────────────────────────${RESET}"
echo -e "  ${BOLD}${C_YELLOW}➜ Premere un tasto per avviare il Controller ${GPU_TYPE}...${RESET}"
echo -e "  ${C_GRAY}────────────────────────────────────────────────────────────────────────${RESET}\n"

# Attesa pressione tasto obbligatoria (senza timeout)
read -n 1 -s -r

# Esecuzione del controller corrispondente
exec bash "$TARGET_SCRIPT"
