#!/usr/bin/env bash
# ==============================================================================
# Script: main.sh (Homelab AI Deployer - Core Router & System Fixer)
# Descrizione: System Pre-flight, Fix Repository OS, Auto-routing & Menu TUI
# Ambienti: Bare-Metal & Proxmox LXC (Debian 12+ / Ubuntu 22.04+)
# Repository: homelab-ai-deployer
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Colors & Layout Definition
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/opt/homelab-ai-deployer/homelab-ai-deployer.log"

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_DIM='\033[2m'

# ------------------------------------------------------------------------------
# Auto-Fix Repository e Dipendenze di Base
# ------------------------------------------------------------------------------
fix_os_repositories() {
    export DEBIAN_FRONTEND=noninteractive
    
    local os_id=""
    local os_version=""
    
    if [[ -f /etc/os-release ]]; then
        os_id=$(grep -E '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
        os_version=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    fi

    echo -e "${C_CYAN}[PRE-FLIGHT] Verifiche e fix repository per OS (${os_id} ${os_version})...${C_RESET}"

    # 1. Dipendenze base per la gestione repo e TUI
    apt-get update -qq || true
    apt-get install -y -qq pciutils python3 python3-pip python3-venv gnupg ca-certificates openssh-server openssh-client net-tools pciutils nodejs whiptail curl wget git build-essential g++ freeglut3-dev libx11-dev libxmu-dev libxi-dev libglu1-mesa-dev libfreeimage-dev libglfw3-dev wget htop btop nvtop nano glances git pciutils cmake curl libcurl4-openssl-dev mc >/dev/null 2>&1

    # 2. Fix specifici per Distribuzione
    if [[ "${os_id}" == "debian" ]]; then
        # Abilita componenti non-free su Debian (fondamentali per driver e toolkit NVIDIA/AMD)
        if ! grep -q "non-free-firmware" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
            echo -e "${C_YELLOW}[FIX REPO] Abilitazione contrib, non-free e non-free-firmware per Debian...${C_RESET}"
            apt-add-repository -y contrib non-free non-free-firmware 2>/dev/null || true
            apt-get update -qq || true
        fi
    elif [[ "${os_id}" == "ubuntu" ]]; then
        # Abilita repository universe/multiverse su Ubuntu
        if ! grep -q "universe" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
            echo -e "${C_YELLOW}[FIX REPO] Abilitazione universe e multiverse per Ubuntu...${C_RESET}"
            add-apt-repository -y universe 2>/dev/null || true
            add-apt-repository -y multiverse 2>/dev/null || true
            apt-get update -qq || true
        fi
    fi
}

# ------------------------------------------------------------------------------
# Diagnostica Hardware
# ------------------------------------------------------------------------------
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed -e 's/^[ \t]*//' || echo "CPU Generica")
CPU_CORES=$(nproc)

CPU_EXT="x86_64 Standard"
if grep -q "avx512" /proc/cpuinfo; then CPU_EXT="AVX-512";
elif grep -q "avx2" /proc/cpuinfo; then CPU_EXT="AVX2"; fi

RAM_TOTAL_GB=$(free -g | awk '/^Mem:/{print $2}')
RAM_AVAIL_GB=$(free -g | awk '/^Mem:/{print $7}')
DISK_FREE_GB=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')

HAS_NVIDIA=false
HAS_AMD=false
GPU_DESC="Solo CPU (Nessun acceleratore GPU rilevato)"

if command -v nvidia-smi >/dev/null 2>&1 || lspci | grep -i "nvidia" >/dev/null 2>&1; then
    HAS_NVIDIA=true
    GPU_DESC=$(lspci | grep -iE 'vga|3d|display' | grep -i nvidia | cut -d: -f3 | sed 's/^[ \t]*//' | head -n1)
    [[ -z "$GPU_DESC" ]] && GPU_DESC="NVIDIA GPU (CUDA Support)"
elif lspci | grep -iE 'vga|3d|display' | grep -i amd >/dev/null 2>&1; then
    HAS_AMD=true
    GPU_DESC=$(lspci | grep -iE 'vga|3d|display' | grep -i amd | cut -d: -f3 | sed 's/^[ \t]*//' | head -n1)
fi

detect_environment() {
    if [[ -f /proc/1/environ ]] && grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        echo "LXC (Proxmox Virtual Environment)"
    else
        echo "Bare-Metal Direct OS"
    fi
}

# ------------------------------------------------------------------------------
# Interfaccia Utente Grafica
# ------------------------------------------------------------------------------
render_header() {
    clear
    echo -e "${C_CYAN}${C_BOLD}"
    echo "┌──────────────────────────────────────────────────────────────────────────────┐"
    echo "│                 H O M E L A B   A I   D E P L O Y E R                        │"
    echo "│         Hardware Discovery & Environment Router (v0.3 Multi-Node)            │"
    echo "└──────────────────────────────────────────────────────────────────────────────┘${C_RESET}"
    echo -e "${C_DIM} Virtualization:${C_RESET} ${C_BOLD}$(detect_environment)${C_RESET}"
    echo -e "${C_DIM} Kernel        :${C_RESET} ${C_BOLD}$(uname -s -r -m)${C_RESET}\n"
}

render_hardware_summary() {
    echo -e "${C_BOLD}❖ DIAGNOSTICA RISORSE E REPOSITORY SISTEMA${C_RESET}"
    echo -e "${C_CYAN}┌──────────────────────────────────────────────────────────────────────────────┐${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_BOLD}🖥️  CPU    :${C_RESET} ${CPU_MODEL} (${CPU_CORES} Core | Istruzioni: ${C_YELLOW}${CPU_EXT}${C_RESET})"
    echo -e "${C_CYAN}│${C_RESET} ${C_BOLD}🧠 RAM    :${C_RESET} ${C_GREEN}${RAM_TOTAL_GB} GB Totali${C_RESET} (${RAM_AVAIL_GB} GB Liberi per caricamento pesi)"
    echo -e "${C_CYAN}│${C_RESET} ${C_BOLD}💾 Storage:${C_RESET} ${DISK_FREE_GB} GB Liberi su Partizione Root (/)"
    
    if $HAS_NVIDIA; then
        echo -e "${C_CYAN}│${C_RESET} ${C_BOLD}🚀 GPU    :${C_RESET} ${C_GREEN}[NVIDIA ACCELERATION]${C_RESET} ${GPU_DESC}"
    elif $HAS_AMD; then
        echo -e "${C_CYAN}│${C_RESET} ${C_BOLD}🚀 GPU    :${C_RESET} ${C_RED}[AMD ROCm / VULKAN]${C_RESET} ${GPU_DESC}"
    else
        echo -e "${C_CYAN}│${C_RESET} ${C_BOLD}⚡ GPU    :${C_RESET} ${C_YELLOW}[MODE CPU ENHANCED]${C_RESET} OpenMP & Vector Acceleration Active"
    fi
    echo -e "${C_CYAN}└──────────────────────────────────────────────────────────────────────────────┘${C_RESET}\n"
}

# ------------------------------------------------------------------------------
# Routing & Esecuzione Controller
# ------------------------------------------------------------------------------
launch_manager() {
    local script_name="$1"
    local full_path="${SCRIPT_DIR}/${script_name}"

    if [[ ! -f "${full_path}" ]]; then
        whiptail --title "Errore Controller Mancante" --msgbox "Impossibile trovare lo script:\n${full_path}\n\nAssicurati che il file sia presente nella stessa cartella di main.sh." 10 70
        return
    fi

    chmod +x "${full_path}"
    echo -e "${C_GREEN}[OK] Avvio controller:${C_RESET} ${C_BOLD}${script_name}${C_RESET}\n"
    sleep 1
    exec "${full_path}"
}

main_menu() {
    while true; do
        render_header
        render_hardware_summary

        local default_item="1"
        if $HAS_NVIDIA; then default_item="2";
        elif $HAS_AMD; then default_item="3"; fi

        local choice
        choice=$(whiptail --title "Homelab AI Deployer - Seleziona Modulo Operativo" \
            --default-item "${default_item}" \
            --menu "\nScegli il profilo di deployment per questo nodo di calcolo:" 20 88 5 \
            "1" "[INFERENZA CPU] llama.cpp + Open WebUI (Ottimizzato RAM/OpenMP)" \
            "2" "[INFERENZA NVIDIA] llama.cpp + CUDA + Driver Check + Open WebUI" \
            "3" "[INFERENZA AMD] llama.cpp + ROCm / Vulkan + Open WebUI" \
            "4" "[FINE-TUNING NVIDIA] Unsloth Studio + PyTorch CUDA + llama.cpp" \
            "5" "[FIX REPO / SYSTEM] Ri-Esegui Aggiornamento Repository e Pacchetti" \
            3>&1 1>&2 2>&3) || exit 0

        case "$choice" in
            1) launch_manager "manager-cpu.sh" ;;
            2) launch_manager "manager-nvidia.sh" ;;
            3) launch_manager "manager-amd.sh" ;;
            4) launch_manager "manager-fine-tuning-nvidia.sh" ;;
            5) 
                fix_os_repositories
                whiptail --title "Fix Completato" --msgbox "I repository e i pacchetti di base sono stati configurati e aggiornati." 8 65
                ;;
            *) exit 0 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo -e "${C_RED}[ERRORE] Homelab AI Deployer richiede i privilegi di root per configurare i repo.${C_RESET}"
    echo -e "Avvia con: ${C_BOLD}sudo ./main.sh${C_RESET}"
    exit 1
fi

fix_os_repositories
main_menu
