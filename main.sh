#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Main Entrypoint Router (main.sh)
# Hardware Discovery & Automated Controller Delegation
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Palette Colori ANSI ---
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
    echo -e "${C_CYAN}┌──────────────────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${C_CYAN}│${RESET}  ${BOLD}${C_WHITE}H O M E L A B   A I   D E P L O Y E R${RESET}  │  ${BOLD}${C_PURPLE}A U T O - R O U T E R${RESET}         ${C_CYAN}│${RESET}"
    echo -e "${C_CYAN}│${RESET}  ${C_GRAY}Zero-Config Hardware Discovery & AI Environment Orchestrator${RESET}         ${C_CYAN}│${RESET}"
    echo -e "${C_CYAN}└──────────────────────────────────────────────────────────────────────────────┘${RESET}"
    echo ""
}

show_about() {
    echo -e "  ${BOLD}${C_PURPLE}❖ INFORMAZIONI SUL PROGETTO${RESET}"
    echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${C_WHITE}Homelab AI Deployer è uno stack automatizzato per l'infrastruttura AI locale.${RESET}"
    echo -e "  ${C_WHITE}Scansiona l'hardware di sistema (GPU, CPU, RAM, Storage) e orchestra il${RESET}"
    echo -e "  ${C_WHITE}deploy dei driver accelerati (CUDA/ROCm/Vulkan) e dei motori d'inferenza.${RESET}"
    echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────────────────${RESET}\n"
}

# --- Verifiche Permessi ---
if [ "$EUID" -ne 0 ]; then
    show_header
    echo -e "  ${C_RED}✖ PERMESSI INSUFFICIENTI${RESET}"
    echo -e "  ${C_GRAY}Esegui lo script con privilegi di root: ${C_WHITE}sudo ./main.sh${RESET}\n"
    exit 1
fi

show_header
show_about

echo -e "  ${BOLD}${C_CYAN}❖ RILEVAMENTO RISORSE DI SISTEMA${RESET}"
echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────────────────${RESET}"

# 1. ANALISI CPU
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//')
[ -z "$CPU_MODEL" ] && CPU_MODEL="Processore generico x86_64"
CPU_CORES=$(nproc)
CPU_FLAGS=""
grep -q 'avx2' /proc/cpuinfo && CPU_FLAGS="AVX2 "
grep -q 'avx512' /proc/cpuinfo && CPU_FLAGS="${CPU_FLAGS}AVX-512 "

# 2. ANALISI RAM
RAM_TOTAL_MB=$(free -m | awk '/Mem:/ {print $2}')
RAM_AVAIL_MB=$(free -m | awk '/Mem:/ {print $7}')
RAM_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $RAM_TOTAL_MB/1024}")
RAM_AVAIL_GB=$(awk "BEGIN {printf \"%.1f\", $RAM_AVAIL_MB/1024}")

RAM_STATUS="🟢"
RAM_NOTE="Ottima per modelli LLM 7B/13B"
if [ "$RAM_TOTAL_MB" -lt 8192 ]; then
    RAM_STATUS="🔴"
    RAM_NOTE="Critica: RAM insufficiente per LLM complessi"
elif [ "$RAM_TOTAL_MB" -lt 16384 ]; then
    RAM_STATUS="🟡"
    RAM_NOTE="Sufficiente: consigliati modelli quantizzati (Q4_K_M)"
fi

# 3. ANALISI DISCO
DISK_FREE_KB=$(df -k / | awk 'NR==2 {print $4}')
DISK_FREE_GB=$((DISK_FREE_KB / 1024 / 1024))

DISK_STATUS="🟢"
DISK_NOTE="Spazio adeguato per pesi modelli e ambienti"
if [ "$DISK_FREE_GB" -lt 15 ]; then
    DISK_STATUS="🔴"
    DISK_NOTE="Spazio insufficiente (minimo 15GB richiesti)"
elif [ "$DISK_FREE_GB" -lt 35 ]; then
    DISK_STATUS="🟡"
    DISK_NOTE="Spazio ridotto: fai attenzione ai modelli > 10GB"
fi

# 4. ANALISI GPU & ROUTING
GPU_TYPE="CPU"
GPU_INFO=""
GPU_STATUS="🔴"
GPU_STACK=""
TARGET_SCRIPT=""

if lspci | grep -iE 'vga|3d|display' | grep -i 'nvidia' > /dev/null 2>&1; then
    GPU_TYPE="NVIDIA"
    GPU_INFO=$(lspci | grep -iE 'vga|3d|display' | grep -i 'nvidia' | head -n 1 | cut -d ':' -f3 | sed 's/^[ \t]*//')
    GPU_STATUS="🟢"
    GPU_STACK="CUDA / TensorRT / llama.cpp / Unsloth"
    TARGET_SCRIPT="${SCRIPT_DIR}/manager-nvidia.sh"

elif lspci | grep -iE 'vga|3d|display' | grep -iE 'amd|radeon' > /dev/null 2>&1; then
    GPU_TYPE="AMD"
    GPU_INFO=$(lspci | grep -iE 'vga|3d|display' | grep -iE 'amd|radeon' | head -n 1 | cut -d ':' -f3 | sed 's/^[ \t]*//')
    
    # Check per architetture AMD RDNA1 / Navi (es. RX 5000 / 5700 XT)
    if echo "$GPU_INFO" | grep -iE 'Navi 10|Navi 12|Navi 14|RX 5' > /dev/null 2>&1; then
        GPU_STATUS="🟡"
        GPU_STACK="ROCm (Sperimentale) / Vulkan RADV / llama.cpp"
    else
        GPU_STATUS="🟢"
        GPU_STACK="ROCm Nativo / Vulkan RADV / llama.cpp"
    fi
    TARGET_SCRIPT="${SCRIPT_DIR}/manager-amd.sh"

else
    GPU_TYPE="CPU"
    GPU_INFO="Nessuna GPU dedicata trovata"
    GPU_STATUS="🔴"
    GPU_STACK="OpenMP / Vector Extensions / llama.cpp CPU"
    TARGET_SCRIPT="${SCRIPT_DIR}/manager-cpu.sh"
fi

# --- STAMPA DASHBOARD RISORSE ---
echo -e "  🖥️  ${BOLD}CPU${RESET}      : ${C_WHITE}${CPU_MODEL}${RESET} (${CPU_CORES} Core | Istruzioni: ${CPU_FLAGS:-Standard})${RESET}"
echo -e "  ${RAM_STATUS}  ${BOLD}RAM${RESET}      : ${C_WHITE}${RAM_TOTAL_GB} GB Totali${RESET} (${RAM_AVAIL_GB} GB Disponibili) · ${C_GRAY}${RAM_NOTE}${RESET}"
echo -e "  ${DISK_STATUS}  ${BOLD}Storage${RESET}  : ${C_WHITE}${DISK_FREE_GB} GB Liberi su /${RESET} · ${C_GRAY}${DISK_NOTE}${RESET}"
echo -e "  ${GPU_STATUS}  ${BOLD}GPU [${GPU_TYPE}]${RESET}: ${C_WHITE}${GPU_INFO}${RESET}"
echo -e "     ${C_GRAY}└─ Stack Target: ${C_CYAN}${GPU_STACK}${RESET}"
echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────────────────${RESET}\n"

# Verifica Controller Target
if [ ! -f "$TARGET_SCRIPT" ]; then
    echo -e "  ${C_RED}✖ ERRORE CRITICO ROUTING:${RESET} Controller non trovato: ${C_WHITE}${TARGET_SCRIPT}${RESET}\n"
    exit 1
fi

echo -e "  ${BOLD}${C_YELLOW}➜ PREMERE UN TASTO PER AVVIARE IL CONTROLLER ASSOCIANTO [${GPU_TYPE}]...${RESET}"

# Attesa pressione tasto obbligatoria
read -n 1 -s -r

# Handoff al controller specifico
exec bash "$TARGET_SCRIPT"
