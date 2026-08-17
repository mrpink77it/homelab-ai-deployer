#!/usr/bin/env bash
# ==============================================================================
# Script: main.sh (Homelab AI Deployer - Auto-Router & Core Orchestrator)
# Descrizione: Scansione hardware, diagnosi risorse ed instradamento dinamico
# Ambienti: Bare-Metal & Proxmox LXC (Debian 12+ / Ubuntu 22.04+)
# Repository: homelab-ai-deployer
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Pre-Flight Check: Installazione automatica dipendenze critiche per la scansione
# ------------------------------------------------------------------------------
ensure_bootstrap_deps() {
    local missing=()
    command -v lspci >/dev/null 2>&1 || missing+=("pciutils")
    command -v whiptail >/dev/null 2>&1 || missing+=("whiptail")

    if [ ${#missing[@]} -ne 0 ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1
    fi
}
ensure_bootstrap_deps

# ------------------------------------------------------------------------------
# Configurazione Ambiente e Palette Colori
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_BLUE='\033[1;34m'
C_DIM='\033[2m'

# ------------------------------------------------------------------------------
# Diagnostica Hardware & Risorse
# ------------------------------------------------------------------------------
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xsed -e 's/^[ \t]*//' || echo "CPU Genérica")
CPU_CORES=$(nproc)

# Identificazione estensioni vettoriali CPU
CPU_EXT=""
if grep -q "avx512" /proc/cpuinfo; then CPU_EXT="AVX-512";
elif grep -q "avx2" /proc/cpuinfo; then CPU_EXT="AVX2";
elif grep -q "avx" /proc/cpuinfo; then CPU_EXT="AVX";
else CPU_EXT="Standard x86_64"; fi

# Rilevamento Memoria e Storage
RAM_TOTAL_GB=$(free -g | awk '/^Mem:/{print $2}')
RAM_AVAIL_GB=$(free -g | awk '/^Mem:/{print $7}')
DISK_FREE_GB=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')

# Scansione Architettura Grafica (GPU)
GPU_TYPE="CPU"
GPU_NAME="Nessuna GPU dedicata rilevata"
MANAGER_SCRIPT="${SCRIPT_DIR}/manager-cpu.sh"

if command -v nvidia-smi >/dev/null 2>&1 || lspci | grep -i "nvidia" >/dev/null 2>&1; then
    GPU_TYPE="NVIDIA"
    GPU_NAME=$(lspci | grep -iE 'vga|3d|display' | grep -i nvidia | cut -d: -f3 | sed 's/^[ \t]*//' | head -n1)
    [[ -z "$GPU_NAME" ]] && GPU_NAME="Scheda Grafica NVIDIA (CUDA Ready)"
    MANAGER_SCRIPT="${SCRIPT_DIR}/manager-nvidia.sh"
elif lspci | grep -iE 'vga|3d|display' | grep -i amd >/dev/null 2>&1; then
    GPU_TYPE="AMD"
    GPU_NAME=$(lspci | grep -iE 'vga|3d|display' | grep -i amd | cut -d: -f3 | sed 's/^[ \t]*//' | head -n1)
    MANAGER_SCRIPT="${SCRIPT_DIR}/manager-amd.sh"
fi

detect_environment() {
    if [[ -f /proc/1/environ ]] && grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        echo "LXC (Proxmox Virtual Environment)"
    else
        echo "Bare-Metal OS Direct"
    fi
}

# ------------------------------------------------------------------------------
# Rendering Interfaccia Utente (Header & System Summary)
# ------------------------------------------------------------------------------
render_header() {
    clear
    echo -e "${C_CYAN}${C_BOLD}"
    echo "┌──────────────────────────────────────────────────────────────────────────────┐"
    echo "│                 H O M E L A B   A I   D E P L O Y E R                        │"
    echo "│         Zero-Config Hardware Discovery & AI Environment Router               │"
    echo "└──────────────────────────────────────────────────────────────────────────────┘${C_RESET}"
    echo -e "${C_DIM} Virtualization:${C_RESET} ${C_BOLD}$(detect_environment)${C_RESET}"
    echo -e "${C_DIM} Architecture  :${C_RESET} ${C_BOLD}$(uname -m) / Linux $(uname -r)${C_RESET}\n"
}

render_hardware_summary() {
    echo -e "${C_BOLD}❖ RILEVAMENTO RISORSE DI SISTEMA${C_RESET}"
    echo -e "${C_CYAN}┌──────────────────────────────────────────────────────────────────────────────┐${C_RESET}"
    
    # CPU
    echo -e "${C_CYAN}│${C_RESET} ${C_BOLD}🖥️  CPU    :${C_RESET} ${CPU_MODEL}"
    echo -e "${C_CYAN}│${C_RESET}            └─ ${C_GREEN}${CPU_CORES} Core Logic${C_RESET} | Istruzioni: ${C_YELLOW}${CPU_EXT}${C_RESET}"
    
    # RAM
    local ram_color="${C_GREEN}"
    [[ $RAM_TOTAL_GB -lt 16 ]] && ram_color="${C_YELLOW}"
    echo -e "${C_CYAN}│${C_RESET} ${C_BOLD}🧠 RAM    :${C_RESET} ${ram_color}${RAM_TOTAL_GB} GB Totali${C_RESET} (${RAM_AVAIL_GB} GB Disponibili)"
    
    # Storage
    echo -e "${C_CYAN}│${C_RESET} ${C_BOLD}💾 Storage:${C_RESET} ${DISK_FREE_GB} GB Liberi su Partizione Root (/)"
    
    # GPU / Accelerator
    case "${GPU_TYPE}" in
        "NVIDIA")
            echo -e "${C_CYAN}│${C_RESET} ${C_BOLD}🚀 GPU    :${C_RESET} ${C_GREEN}[NVIDIA CUDA]${C_RESET} ${GPU_NAME}"
            ;;
        "AMD")
            echo -e "${C_CYAN}│${C_RESET} ${C_BOLD}🚀 GPU    :${C_RESET} ${C_RED}[AMD ROCm/Vulkan]${C_RESET} ${GPU_NAME}"
            ;;
        *)
            echo -e "${C_CYAN}│${C_RESET} ${C_BOLD}⚡ GPU    :${C_RESET} ${C_YELLOW}[NATIVE CPU MODE]${C_RESET} Nessun acceleratore discreto"
            echo -e "${C_CYAN}│${C_RESET}            └─ Stack Ottimizzato: OpenMP / Vector Extensions / GGML CPU"
            ;;
    esac
    
    echo -e "${C_CYAN}└──────────────────────────────────────────────────────────────────────────────┘${C_RESET}\n"
}

# ------------------------------------------------------------------------------
# Orchestrazione & Routing Servizi
# ------------------------------------------------------------------------------
execute_manager() {
    local target_script="$1"
    
    if [[ ! -f "${target_script}" ]]; then
        echo -e "${C_RED}[ERRORE] Impossibile trovare lo script controller: ${target_script}${C_RESET}"
        echo -e "Verifica che tutti i file manager-*.sh siano presenti nella directory del progetto."
        exit 1
    fi

    # Assicura che i permessi di esecuzione siano presenti
    chmod +x "${target_script}"
    
    echo -e "${C_GREEN}[OK] Avvio del controller dedicato:${C_RESET} ${C_BOLD}$(basename "${target_script}")${C_RESET}\n"
    sleep 1
    exec "${target_script}"
}

main_menu() {
    render_header
    render_hardware_summary

    echo -e "${C_BOLD}❖ SELEZIONA OBIETTIVO DEL NODO AI${C_RESET}"
    echo "──────────────────────────────────────────────────────────────────────────────"
    
    local choice
    choice=$(whiptail --title "Homelab AI Deployer - Menu Principale" \
        --menu "\nSeleziona l'operazione da eseguire per questo nodo:" 18 80 4 \
        "1" "Avvia Controller Auto-Rilevato [Raccomandato per questo sistema]" \
        "2" "Forza Controller CPU (Inferenza via RAM / System Memory)" \
        "3" "Forza Controller NVIDIA (CUDA / TensorRT Stack)" \
        "4" "Forza Controller AMD (ROCm / Vulkan Stack)" \
        3>&1 1>&2 2>&3) || exit 0

    case "$choice" in
        1) execute_manager "${MANAGER_SCRIPT}" ;;
        2) execute_manager "${SCRIPT_DIR}/manager-cpu.sh" ;;
        3) execute_manager "${SCRIPT_DIR}/manager-nvidia.sh" ;;
        4) execute_manager "${SCRIPT_DIR}/manager-amd.sh" ;;
        *) exit 0 ;;
    esac
}

# ------------------------------------------------------------------------------
# Entrypoint Script
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo -e "${C_RED}[ERRORE] Homelab AI Deployer richiede i privilegi di root.${C_RESET}"
    echo -e "Esegui lo script con: ${C_BOLD}sudo ./main.sh${C_RESET}"
    exit 1
fi

main_menu
