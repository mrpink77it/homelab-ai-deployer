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
    echo -e "${C_CYAN}==============================================================================${RESET}"
    echo -e "  ${BOLD}${C_WHITE}H O M E L A B   A I   D E P L O Y E R${RESET}  ${C_GRAY}::${RESET}  ${BOLD}${C_PURPLE}A U T O - R O U T E R${RESET}"
    echo -e "  ${C_GRAY}Zero-Config Hardware Discovery & Local AI Environment Orchestrator${RESET}"
    echo -e "${C_CYAN}==============================================================================${RESET}\n"
}

show_about() {
    echo -e "  ${BOLD}${C_PURPLE}❖ INFORMAZIONI E ARCHITETTURA PROGETTO${RESET}"
    echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${C_WHITE}Homelab AI Deployer è una piattaforma automatizzata per l'infrastruttura AI locale.${RESET}"
    echo -e "  ${C_WHITE}Scansiona le risorse di sistema e orchestra l'ambiente ideale per:${RESET}\n"
    
    echo -e "  ${C_CYAN}🤖 Local AI Inference${RESET}    : Supporto LLM (GGUF via llama.cpp / Vulkan / CUDA)"
    echo -e "  ${C_GREEN}💻 AI-Assisted Coding${RESET}   : Server locali per VS Code, Codex, OpenCode & CodeRunner"
    echo -e "  ${C_YELLOW}⚡ Model Fine-Tuning${RESET}    : Integrazione nativa Unsloth & PyTorch per addestramento"
    echo -e "  ${C_PURPLE}🔒 Isolated Sandbox${RESET}     : Deploy sicuro via SSH/LXC per esecuzione codice locale\n"

    echo -e "  ${BOLD}${C_WHITE}📍 ROADWAY & MAPPA DI SVILUPPO:${RESET}"
    echo -e "  ${C_GRAY}  ├─ [v0.1 - v0.2]${RESET} ${C_GREEN}✔ Core Auto-Router & Controller GPU AMD/NVIDIA/CPU${RESET}"
    echo -e "  ${C_GRAY}  ├─ [v0.3 - v0.4]${RESET} ${C_YELLOW}➜ Setup JupyterLab Node & Docker Container Multi-node${RESET}"
    echo -e "  ${C_GRAY}  └─ [v0.5 +]      ${RESET} ${C_GRAY}⋯ Agenzia Agenti AI Locali & Vector DB RAG Orchestrator${RESET}"
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

# 4. ANALISI GPU
GPU_TYPE="CPU"
GPU_INFO=""
GPU_STATUS="🔴"
GPU_STACK=""

if lspci | grep -iE 'vga|3d|display' | grep -i 'nvidia' > /dev/null 2>&1; then
    GPU_TYPE="NVIDIA"
    GPU_INFO=$(lspci | grep -iE 'vga|3d|display' | grep -i 'nvidia' | head -n 1 | cut -d ':' -f3 | sed 's/^[ \t]*//')
    GPU_STATUS="🟢"
    GPU_STACK="CUDA / TensorRT / llama.cpp / Unsloth"

elif lspci | grep -iE 'vga|3d|display' | grep -iE 'amd|radeon' > /dev/null 2>&1; then
    GPU_TYPE="AMD"
    GPU_INFO=$(lspci | grep -iE 'vga|3d|display' | grep -iE 'amd|radeon' | head -n 1 | cut -d ':' -f3 | sed 's/^[ \t]*//')
    
    if echo "$GPU_INFO" | grep -iE 'Navi 10|Navi 12|Navi 14|RX 5' > /dev/null 2>&1; then
        GPU_STATUS="🟡"
        GPU_STACK="Vulkan RADV / ROCm (Sperimentale) / llama.cpp"
    else
        GPU_STATUS="🟢"
        GPU_STACK="ROCm Nativo / Vulkan RADV / llama.cpp"
    fi

else
    GPU_TYPE="CPU"
    GPU_INFO="Nessuna GPU dedicata trovata"
    GPU_STATUS="🔴"
    GPU_STACK="OpenMP / Vector Extensions / llama.cpp CPU"
fi

# --- STAMPA DASHBOARD RISORSE ---
echo -e "  🖥️  ${BOLD}CPU${RESET}      : ${C_WHITE}${CPU_MODEL}${RESET} (${CPU_CORES} Core | ${CPU_FLAGS:-Standard})"
echo -e "  ${RAM_STATUS}  ${BOLD}RAM${RESET}      : ${C_WHITE}${RAM_TOTAL_GB} GB Totali${RESET} (${RAM_AVAIL_GB} GB Disponibili) · ${C_GRAY}${RAM_NOTE}${RESET}"
echo -e "  ${DISK_STATUS}  ${BOLD}Storage${RESET}  : ${C_WHITE}${DISK_FREE_GB} GB Liberi su /${RESET} · ${C_GRAY}${DISK_NOTE}${RESET}"
echo -e "  ${GPU_STATUS}  ${BOLD}GPU [${GPU_TYPE}]${RESET}: ${C_WHITE}${GPU_INFO}${RESET}"
echo -e "     ${C_GRAY}└─ Stack Supportato: ${C_CYAN}${GPU_STACK}${RESET}"
echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────────────────${RESET}\n"

# --- SELEZIONE MODALITA' DINAMICA ---
echo -e "  ${BOLD}${C_YELLOW}❖ SELEZIONA OBIETTIVO DEL NODO AI${RESET}"
echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────────────────${RESET}"
echo -e "  ${BOLD}${C_CYAN}[1] Local AI Inference & Serving Node${RESET} ${C_GRAY}(Consigliato per ${GPU_TYPE})${RESET}"
echo -e "      ${C_WHITE}└─ Esecuzione modelli LLM (GGUF), Chat Web UI, API OpenAI-compatibile,${RESET}"
echo -e "         ${C_WHITE}assistenti di codice per VS Code e agenti locali.${RESET}\n"

if [ "$GPU_TYPE" = "NVIDIA" ]; then
    echo -e "  ${BOLD}${C_PURPLE}[2] Model Fine-Tuning & Training Node${RESET} ${C_GRAY}(Sviluppo & Addestramento)${RESET}"
    echo -e "      ${C_WHITE}└─ Ambiente di addestramento avanzato (QLoRA/LoRA) con Unsloth & PyTorch.${RESET}"
    echo -e "         ${C_WHITE}Permette di personalizzare LLM sui tuoi dati ed esportare in GGUF.${RESET}\n"
else
    echo -e "  ${BOLD}${C_GRAY}[2] Model Fine-Tuning & Training Node${RESET} ${C_RED}[NON DISPONIBILE SU $GPU_TYPE - RICHIEDE NVIDIA]${RESET}"
    echo -e "      ${C_GRAY}└─ Unsloth/Triton non supportano GPU AMD/CPU. Selezionandolo verrai reindirizzato all'Inference.${RESET}\n"
fi

echo -e "  ${BOLD}${C_RED}[3] Esci${RESET}\n"

read -rp "  Scegli l'opzione [1-3]: " WORKLOAD_CHOICE

TARGET_SCRIPT=""

case "$WORKLOAD_CHOICE" in
    1)
        echo -e "\n  ${C_GREEN}➜ Selezionata Modalità: INFERENZA LOCALE & SERVING [${GPU_TYPE}]${RESET}"
        if [ "$GPU_TYPE" = "NVIDIA" ]; then
            TARGET_SCRIPT="${SCRIPT_DIR}/manager-nvidia.sh"
        elif [ "$GPU_TYPE" = "AMD" ]; then
            TARGET_SCRIPT="${SCRIPT_DIR}/manager-amd.sh"
        else
            TARGET_SCRIPT="${SCRIPT_DIR}/manager-cpu.sh"
        fi
        ;;

    2)
        if [ "$GPU_TYPE" = "NVIDIA" ]; then
            echo -e "\n  ${C_PURPLE}➜ Selezionata Modalità: FINE-TUNING & ADDESTRAMENTO (UNSLOTH)${RESET}"
            TARGET_SCRIPT="${SCRIPT_DIR}/manager-fine-tuning-nvidia.sh"
        else
            echo -e "\n  ${C_RED}⚠️  ATTENZIONE: Hardware $GPU_TYPE non supportato per Fine-Tuning locale!${RESET}"
            echo -e "  ${C_WHITE}Impossibile effettuare il training con Unsloth su GPU AMD/CPU.${RESET}"
            echo -e "  ${C_GRAY}Unsloth & Triton richiedono architettura NVIDIA CUDA.${RESET}"
            echo -e "  ${C_GRAY}Consiglio: esegui il training su Cloud (Colab/RunPod) ed esporta il file GGUF.${RESET}\n"
            
            echo -e "  ${BOLD}${C_CYAN}➜ PREMERE UN TASTO PER PROSEGUIRE CON L'INSTALLAZIONE AMD / INFERENZA...${RESET}"
            read -n 1 -s -r

            if [ "$GPU_TYPE" = "AMD" ]; then
                TARGET_SCRIPT="${SCRIPT_DIR}/manager-amd.sh"
            else
                TARGET_SCRIPT="${SCRIPT_DIR}/manager-cpu.sh"
            fi
        fi
        ;;

    3)
        echo -e "\n  ${C_YELLOW}Uscita.${RESET}\n"
        exit 0
        ;;

    *)
        echo -e "\n  ${C_RED}Opzione non valida. Uscita.${RESET}\n"
        exit 1
        ;;
esac

# Verifica esistenza dello script di destinazione
if [ ! -f "$TARGET_SCRIPT" ]; then
    echo -e "\n  ${C_RED}✖ ERRORE CRITICO ROUTING:${RESET} Controller non trovato: ${C_WHITE}${TARGET_SCRIPT}${RESET}\n"
    exit 1
fi

echo -e "\n  ${C_GRAY}Avvio controller: ${C_WHITE}$(basename "$TARGET_SCRIPT")${RESET}...\n"
sleep 1

# Handoff al controller specifico
exec bash "$TARGET_SCRIPT"
