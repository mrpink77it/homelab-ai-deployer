#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Controller AMD (manager-amd.sh)
# Compatible with: Debian 13 (Trixie) / Baremetal & Proxmox LXC | AMD GPUs
# ==============================================================================

set -e

# Configuration Paths
INSTALL_DIR="/opt/homelab-ai"
UNSLOTH_ENV="/root/unsloth_env"
CODE_RUNNER_DIR="/opt/code_runner"
LLAMA_CPP_DIR="${INSTALL_DIR}/llama.cpp"

# --- Palette Colori ANSI ---
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

C_CYAN='\033[38;5;39m'
C_BLUE='\033[38;5;33m'
C_GREEN='\033[38;5;42m'
C_YELLOW='\033[38;5;214m'
C_RED='\033[38;5;196m'
C_PURPLE='\033[38;5;135m'
C_GRAY='\033[38;5;244m'
C_WHITE='\033[38;5;255m'

show_header() {
    clear
    echo -e "${C_PURPLE}┌──────────────────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${C_PURPLE}│${RESET}  ${BOLD}${C_WHITE}H O M E L A B   A I   D E P L O Y E R${RESET}  ${C_GRAY}::${RESET}  ${BOLD}${C_CYAN}C O N T R O L L E R   A M D${RESET}    ${C_PURPLE}│${RESET}"
    echo -e "${C_PURPLE}│${RESET}  ${C_GRAY}Gestione Hardware AMD, Accelerazione Vulkan/ROCm & llama.cpp Builder        ${C_PURPLE}│${RESET}"
    echo -e "${C_PURPLE}└──────────────────────────────────────────────────────────────────────────────┘${RESET}"
    echo ""
}

# Check root privileges
if [ "$EUID" -ne 0 ]; then
    show_header
    echo -e "  ${C_RED}𐄂 PERMESSI INSUFFICIENTI${RESET}"
    echo -e "  ${C_GRAY}Esegui lo script con privilegi di root (sudo ./manager-amd.sh)${RESET}\n"
    exit 1
fi

install_vulkan_dependencies() {
    echo -e "  ${C_YELLOW}[+] Aggiornamento repository e installazione dipendenze complete (Vulkan, Node.js, npm)...${RESET}"
    apt-get update
    
    # Inclusi nodejs e npm per gestire i moduli e gli assets web di llama.cpp
    apt-get install -y \
        build-essential \
        cmake \
        ccache \
        git \
        curl \
        wget \
        pkg-config \
        libssl-dev \
        libvulkan-dev \
        vulkan-tools \
        mesa-vulkan-drivers \
        glslang-tools \
        glslang-dev \
        spirv-tools \
        libspirv-tools-dev \
        spirv-headers \
        libspirv-cross-c-shared-dev \
        python3 \
        python3-pip \
        python3-venv \
        clinfo \
        nodejs \
        npm

    if ! command -v glslc &> /dev/null; then
        if [ -f "/usr/bin/glslc" ]; then
            export PATH=$PATH:/usr/bin
        fi
    fi
}

install_services() {
    show_header
    echo -e "  ${C_PURPLE}=== Selezione Backend d'Inferenza per GPU AMD ===${RESET}\n"
    echo -e "  ${C_GRAY}┌──────────────────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${BOLD}${C_CYAN}[1]${RESET} ROCm Ufficiale (Consigliato per RX 6000 / RX 7000 Series)               ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${BOLD}${C_GREEN}[2]${RESET} Vulkan / llama.cpp (Raccomandato per RX 5000 / RDNA1 - RX 5700 XT)   ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${BOLD}${C_YELLOW}[3]${RESET} ROCm Sperimentale (Override HSA_OVERRIDE_GFX_VERSION=10.3.0 PyTorch)   ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}└──────────────────────────────────────────────────────────────────────────────┘${RESET}\n"

    read -p "  Seleziona il backend [1-3]: " amd_choice

    install_vulkan_dependencies
    mkdir -p "${INSTALL_DIR}"

    case $amd_choice in
        1)
            echo -e "\n  ${C_BLUE}[+] Installazione stack ROCm Ufficiale...${RESET}"
            apt-get install -y rocm-hip-sdk || true
            mkdir -p "${UNSLOTH_ENV}"
            python3 -m venv "${UNSLOTH_ENV}"
            "${UNSLOTH_ENV}/bin/pip" install --upgrade pip
            "${UNSLOTH_ENV}/bin/pip" install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm6.0
            ;;
        2)
            echo -e "\n  ${C_GREEN}[+] Compilazione nativa di llama.cpp con accelerazione Vulkan (RADV)...${RESET}"
            cd "${INSTALL_DIR}"
            if [ -d "${LLAMA_CPP_DIR}" ]; then
                echo -e "  ${C_YELLOW}[*] Aggiornamento sorgenti llama.cpp esistenti...${RESET}"
                cd "${LLAMA_CPP_DIR}"
                git pull
            else
                git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_CPP_DIR}"
                cd "${LLAMA_CPP_DIR}"
            fi

            # Pulizia radicale della build per eliminare ogni residuo corrotto
            rm -rf build
            mkdir -p build
            cd build

            GLSLC_PATH=$(which glslc || echo "/usr/bin/glslc")

            echo -e "  ${C_YELLOW}[*] Configurazione CMake con GGML_VULKAN=ON...${RESET}"
            cmake .. -DGGML_VULKAN=ON -DVulkan_GLSLC_EXECUTABLE="${GLSLC_PATH}"

            echo -e "  ${C_YELLOW}[*] Compilazione in modalità sequenziale protetta per gli shader Vulkan (-j1)...${RESET}"
            cmake --build . --config Release -j1

            echo -e "\n  ${C_GREEN}[✔] Compilazione llama.cpp (Vulkan) completata con successo!${RESET}"
            ;;
        3)
            echo -e "\n  ${C_BLUE}[+] Configurazione ROCm Sperimentale con GFX Override (gfx1030)...${RESET}"
            apt-get install -y rocm-hip-sdk || true
            mkdir -p "${UNSLOTH_ENV}"
            python3 -m venv "${UNSLOTH_ENV}"
            "${UNSLOTH_ENV}/bin/pip" install --upgrade pip
            "${UNSLOTH_ENV}/bin/pip" install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm6.0

            if ! grep -q "HSA_OVERRIDE_GFX_VERSION=10.3.0" /root/.bashrc; then
                echo "export HSA_OVERRIDE_GFX_VERSION=10.3.0" >> /root/.bashrc
            fi
            export HSA_OVERRIDE_GFX_VERSION=10.3.0
            echo -e "  ${C_GREEN}[✔] Override HSA_OVERRIDE_GFX_VERSION=10.3.0 impostato in /root/.bashrc${RESET}"
            ;;
        *)
            echo -e "\n  ${C_RED}Scelta non valida! Annullamento...${RESET}"
            return 1
            ;;
    esac

    echo -e "\n  ${C_GREEN}[✔] Installazione completata per l'ambiente AMD!${RESET}"
    read -p "  Premi [INVIO] per tornare al menu principale..."
}

check_status() {
    show_header
    echo -e "  ${C_PURPLE}=== Verifico Stato Hardware & Servizi AMD ===${RESET}\n"

    if command -v vulkaninfo &> /dev/null; then
        echo -e "  ${C_GREEN}[✔ Vulkan]${RESET} Supporto runtime e strumenti rilevati nel sistema."
    else
        echo -e "  ${C_RED}[✖ Vulkan]${RESET} Strumenti non installati."
    fi

    if command -v glslc &> /dev/null; then
        echo -e "  ${C_GREEN}[✔ Shaderc/GLSL]${RESET} Compilatore glslc disponibile ($(which glslc))."
    else
        echo -e "  ${C_YELLOW}[! Shaderc/GLSL]${RESET} Compilatore glslc non trovato nel PATH."
    fi

    if command -v npm &> /dev/null; then
        echo -e "  ${C_GREEN}[✔ Node.js/npm]${RESET} Gestore pacchetti npm disponibile ($(npm -v))."
    else
        echo -e "  ${C_YELLOW}[! Node.js/npm]${RESET} npm non trovato nel sistema."
    fi

    if command -v rocm-smi &> /dev/null; then
        echo -e "  ${C_GREEN}[✔ ROCm]${RESET} Utility ROCm SMI disponibile:"
        rocm-smi --showid || true
    else
        echo -e "  ${C_YELLOW}[! ROCm]${RESET} Utility ROCm non presente."
    fi

    if [ -f "${LLAMA_CPP_DIR}/build/bin/llama-cli" ] || [ -f "${LLAMA_CPP_DIR}/build/bin/main" ] || [ -f "${LLAMA_CPP_DIR}/build/bin/llama-server" ]; then
        echo -e "  ${C_GREEN}[✔ llama.cpp]${RESET} Binari compilati presenti in ${LLAMA_CPP_DIR}/build/bin"
    fi

    echo ""
    read -p "  Premi [INVIO] per tornare al menu principale..."
}

update_components() {
    show_header
    echo -e "  ${C_YELLOW}[+] Aggiornamento componenti AMD in corso...${RESET}\n"
    if [ -d "${LLAMA_CPP_DIR}" ]; then
        cd "${LLAMA_CPP_DIR}"
        git pull
        rm -rf build
        mkdir -p build
        cd build
        cmake .. -DGGML_VULKAN=ON
        cmake --build . --config Release -j1
        echo -e "\n  ${C_GREEN}[✔] llama.cpp aggiornato e ricompilato!${RESET}"
    else
        echo -e "  ${C_YELLOW}[!] llama.cpp non risulta installato in ${LLAMA_CPP_DIR}.${RESET}"
    fi
    echo ""
    read -p "  Premi [INVIO] per tornare al menu principale..."
}

configure_sandbox() {
    show_header
    echo -e "  ${C_PURPLE}=== Helper Configurazione Sandbox ===${RESET}\n"
    read -p "  Inserisci l'IP della Sandbox da associare via SSH (oppure premi INVIO per annullare): " sandbox_ip
    if [ -n "$sandbox_ip" ]; then
        if [ ! -f /root/.ssh/id_ed25519 ]; then
            ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
        fi
        ssh-copy-id -i /root/.ssh/id_ed25519.pub "root@${sandbox_ip}" || true
    fi
    read -p "  Premi [INVIO] per tornare al menu principale..."
}

uninstall_all() {
    show_header
    echo -e "  ${C_RED}=== RIMOZIONE COMPLETA AMBIENTE ===${RESET}\n"
    read -p "  Sei sicuro di voler rimuovere i servizi, le directory ed i binari installati? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "${INSTALL_DIR}" "${UNSLOTH_ENV}" "${CODE_RUNNER_DIR}"
        echo -e "\n  ${C_GREEN}[✔] Rimozione completata!${RESET}"
    else
        echo -e "\n  ${C_YELLOW}Annullato.${RESET}"
    fi
    read -p "  Premi [INVIO] per tornare al menu principale..."
}

# --- Main Menu Loop ---
while true; do
    show_header
    echo -e "  ${C_GRAY}┌────────────────────────────────────────────────────────┐${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${BOLD}${C_CYAN}[1]${RESET} INSTALLA Servizi (ROCm / Vulkan)                    ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${BOLD}${C_GREEN}[2]${RESET} VERIFICA Stato Hardware & Servizi                  ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${BOLD}${C_YELLOW}[3]${RESET} AGGIORNA Componenti & llama.cpp                    ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${BOLD}${C_PURPLE}[4]${RESET} CONFIGURA Sandbox SSH                               ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${BOLD}${C_RED}[5]${RESET} DISINSTALLA Tutto                                   ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}│${RESET}  ${BOLD}${C_WHITE}[6]${RESET} ESCI                                                ${C_GRAY}│${RESET}"
    echo -e "  ${C_GRAY}└────────────────────────────────────────────────────────┘${RESET}\n"

    read -p "  Seleziona un'opzione [1-6]: " choice

    case $choice in
        1) install_services ;;
        2) check_status ;;
        3) update_components ;;
        4) configure_sandbox ;;
        5) uninstall_all ;;
        6) echo -e "\n  ${C_GREEN}Arrivederci!${RESET}\n"; exit 0 ;;
        *) echo -e "\n  ${C_RED}Opzione non valida!${RESET}"; sleep 1 ;;
    esac
done
