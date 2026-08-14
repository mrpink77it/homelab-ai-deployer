#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Unified Hardware Router (main.sh)
# Style: Cyberpunk / Modern Minimal CLI
# ==============================================================================

set -e

# --- Palette Colori ANSI (16/256 Color Safe) ---
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Colors
C_CYAN='\033[38;5;39m'
C_BLUE='\033[38;5;33m'
C_GREEN='\033[38;5;42m'
C_YELLOW='\033[38;5;214m'
C_RED='\033[38;5;196m'
C_PURPLE='\033[38;5;135m'
C_GRAY='\033[38;5;244m'
C_WHITE='\033[38;5;255m'

# Card / Box Frames
BORDER_CYAN="${C_CYAN}│${RESET}"
BORDER_GRAY="${C_GRAY}│${RESET}"

# --- Helper Grafici ---
draw_header() {
    clear
    echo -e "${C_CYAN}┌──────────────────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${C_CYAN}│${RESET}  ${BOLD}${C_WHITE}H O M E L A B   A I   D E P L O Y E R${RESET}                                ${C_CYAN}│${RESET}"
    echo -e "${C_CYAN}│${RESET}  ${C_GRAY}Zero-Config Hardware Discovery & AI Controller Router${RESET}               ${C_CYAN}│${RESET}"
    echo -e "${C_CYAN}└──────────────────────────────────────────────────────────────────────────────┘${RESET}"
    echo ""
}

show_spinner() {
    local pid=$1
    local delay=0.08
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    echo -ne "  "
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " ${C_CYAN}%c${RESET}  ${C_GRAY}Scansione bus PCIe e rilevamento GPU in corso...${RESET}" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b"
    done
    printf "                                                                               \r"
}

# --- Controllo Privilegi ---
if [ "$EUID" -ne 0 ]; then
    draw_header
    echo -e "  ${C_RED}𐄂 PERMESSI INSUFFICIENTI${RESET}"
    echo -e "  ${C_GRAY}Questo script richiede privilegi di root per accedere ai nodi hardware.${RESET}\n"
    echo -e "  ${BOLD}Uso consigliato:${RESET} ${C_CYAN}sudo ./main.sh${RESET}\n"
    exit 1
fi

draw_header

# --- Rilevamento Hardware con Animation ---
( sleep 1.2 ) &
SPINNER_PID=$!
show_spinner $SPINNER_PID

# Query PCI Bus
NVIDIA_FOUND=false
AMD_FOUND=false

if lspci | grep -iE 'vga|3d|display' | grep -iq 'nvidia'; then
    NVIDIA_FOUND=true
fi

if lspci | grep -iE 'vga|3d|display' | grep -iq 'amd\|radeon\|advanced micro devices'; then
    AMD_FOUND=true
fi

# Rilevamento modello GPU esatto per il banner
GPU_MODEL=$(lspci | grep -iE 'vga|3d|display' | cut -d ':' -f3 | sed 's/^[ \t]*//' | head -n 1)
[ -z "$GPU_MODEL" ] && GPU_MODEL="Dispositivo Grafico Generico"

# --- Routing dell'Hardware ---
if [ "$NVIDIA_FOUND" = true ] && [ "$AMD_FOUND" = true ]; then
    echo -e "  ${C_YELLOW}⚡ RILEVATA CONFIGURAZIONE DUAL-GPU (HYBRID)${RESET}"
    echo -e "  ${C_GRAY}Hardware trovato:${RESET} ${C_WHITE}${GPU_MODEL}${RESET}\n"
    
    echo -e "  ${C_GRAY}┌────────────────────────────────────────────────────────┐${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  Seleziona quale stack software desideri avviare:      ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}├────────────────────────────────────────────────────────┤${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${BOLD}${C_CYAN}[1]${RESET} Avvia Manager ${BOLD}NVIDIA${RESET} (CUDA / vLLM)                 ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${BOLD}${C_PURPLE}[2]${RESET} Avvia Manager ${BOLD}AMD${RESET} (ROCm / Vulkan)                   ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}└────────────────────────────────────────────────────────┘${RESET}\n"
    
    read -p "  Scelta [1-2]: " dual_choice
    case $dual_choice in
        1)
            echo -e "\n  ${C_GREEN}➔ Redirection:${RESET} Inizializzazione ${C_CYAN}manager.sh${RESET} (NVIDIA)..."
            sleep 0.8
            exec ./manager.sh
            ;;
        2)
            echo -e "\n  ${C_GREEN}➔ Redirection:${RESET} Inizializzazione ${C_PURPLE}manager-amd.sh${RESET} (AMD)..."
            sleep 0.8
            exec ./manager-amd.sh
            ;;
        *)
            echo -e "\n  ${C_RED}Scelta non valida. Annullamento.${RESET}"
            exit 1
            ;;
    esac

elif [ "$NVIDIA_FOUND" = true ]; then
    echo -e "  ${C_GREEN}✔ GPU NVIDIA RILEVATA${RESET}"
    echo -e "  ${C_GRAY}Scheda:${RESET} ${C_WHITE}${GPU_MODEL}${RESET}"
    echo -e "  ${C_GRAY}Stack:${RESET}  ${C_CYAN}CUDA Toolkit / PyTorch Native / vLLM${RESET}\n"
    echo -e "  ${C_GRAY}Lancio di ${RESET}${C_CYAN}manager.sh${RESET}${C_GRAY} in corso...${RESET}\n"
    sleep 1.2
    exec ./manager.sh

elif [ "$AMD_FOUND" = true ]; then
    echo -e "  ${C_PURPLE}✔ GPU AMD RADEON RILEVATA${RESET}"
    echo -e "  ${C_GRAY}Scheda:${RESET} ${C_WHITE}${GPU_MODEL}${RESET}"
    echo -e "  ${C_GRAY}Stack:${RESET}  ${C_PURPLE}ROCm / Vulkan (RADV) / llama.cpp${RESET}\n"
    echo -e "  ${C_GRAY}Lancio di ${RESET}${C_PURPLE}manager-amd.sh${RESET}${C_GRAY} in corso...${RESET}\n"
    sleep 1.2
    exec ./manager-amd.sh

else
    echo -e "  ${C_RED}✖ NESSUNA GPU DEDICATA COMPATIBILE RILEVATA${RESET}"
    echo -e "  ${C_GRAY}Non è stata trovata alcuna GPU NVIDIA o AMD supportata nel bus PCI.${RESET}\n"
    
    echo -e "  ${C_GRAY}┌────────────────────────────────────────────────────────┐${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  Come desideri procedere?                              ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}├────────────────────────────────────────────────────────┤${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${BOLD}${C_CYAN}[1]${RESET} Forza avvio Manager NVIDIA (CUDA)                   ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${BOLD}${C_PURPLE}[2]${RESET} Forza avvio Manager AMD (Vulkan / CPU Fallback)     ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${BOLD}${C_WHITE}[3]${RESET} Esci                                                ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}└────────────────────────────────────────────────────────┘${RESET}\n"
    
    read -p "  Scelta [1-3]: " force_choice
    case $force_choice in
        1) exec ./manager.sh ;;
        2) exec ./manager-amd.sh ;;
        3) echo -e "\n  ${C_GRAY}Uscita...${RESET}"; exit 0 ;;
        *) echo -e "\n  ${C_RED}Opzione non valida.${RESET}"; exit 1 ;;
    esac
fi
