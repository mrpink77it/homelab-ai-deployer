#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - AMD Management Script (manager-amd.sh)
# Compatible with: Baremetal & Proxmox LXC | AMD GPUs (ROCm / Vulkan)
# ==============================================================================

set -e

# Configuration Paths
INSTALL_DIR="/opt/homelab-ai"
UNSLOTH_ENV="/root/unsloth_env"
CODE_RUNNER_DIR="/opt/code_runner"
LLAMA_CPP_DIR="${INSTALL_DIR}/llama.cpp"

# Colors for TUI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Check root privileges
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Errore: Esegui lo script come root (sudo ./manager-amd.sh)${NC}"
  exit 1
fi

show_header() {
    clear
    echo -e "${CYAN}====================================================================${NC}"
    echo -e "${CYAN}             Homelab AI Deployer - Controller AMD                   ${NC}"
    echo -e "${CYAN}====================================================================${NC}"
    echo ""
}

install_vulkan_dependencies() {
    echo -e "${YELLOW}[+] Installazione dipendenze di sistema e SDK Vulkan/Shaderc...${NC}"
    apt-get update -qq
    apt-get install -y -qq \
        build-essential \
        cmake \
        git \
        curl \
        wget \
        pkg-config \
        libvulkan-dev \
        vulkan-tools \
        mesa-vulkan-drivers \
        glslc \
        shaderc \
        python3 \
        python3-pip \
        python3-venv \
        clinfo \
        rocm-smi-lib 2>/dev/null || true

    # Verifica presenza glslc per CMake
    if ! command -v glslc &> /dev/null; then
        echo -e "${RED}[!] Attenzione: 'glslc' non trovato direttamente nel PATH.${NC}"
        if [ -f "/usr/bin/glslc" ]; then
            export PATH=$PATH:/usr/bin
        fi
    fi
}

install_services() {
    show_header
    echo -e "${YELLOW}=== Selezione Backend d'Inferenza per GPU AMD ===${NC}"
    echo "1) ROCm Ufficiale (Consigliato per RX 6000 / RX 7000 Series)"
    echo "2) Vulkan / llama.cpp (Raccomandato per RX 5000 / RDNA1 - RX 5700 XT)"
    echo "3) ROCm Sperimentale (Override HSA_OVERRIDE_GFX_VERSION=10.3.0 per PyTorch)"
    echo ""
    read -p "Seleziona il backend [1-3]: " amd_choice

    install_vulkan_dependencies
    mkdir -p "${INSTALL_DIR}"

    case $amd_choice in
        1)
            echo -e "${BLUE}[+] Installazione stack ROCm Ufficiale...${NC}"
            apt-get install -y -qq rocm-hip-sdk
            mkdir -p "${UNSLOTH_ENV}"
            python3 -m venv "${UNSLOTH_ENV}"
            "${UNSLOTH_ENV}/bin/pip" install --upgrade pip
            "${UNSLOTH_ENV}/bin/pip" install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm6.0
            ;;
        2)
            echo -e "${BLUE}[+] Compilazione nativa di llama.cpp con accelerazione Vulkan...${NC}"
            cd "${INSTALL_DIR}"
            if [ -d "${LLAMA_CPP_DIR}" ]; then
                echo -e "${YELLOW}[*] Aggiornamento sorgenti llama.cpp esistenti...${NC}"
                cd "${LLAMA_CPP_DIR}"
                git pull
            else
                git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_CPP_DIR}"
                cd "${LLAMA_CPP_DIR}"
            fi

            mkdir -p build
            cd build
            
            # Passaggio esplicito di glslc a CMake se disponibile
            GLSLC_PATH=$(which glslc || echo "/usr/bin/glslc")
            
            echo -e "${YELLOW}[*] Configurazione CMake con GGML_VULKAN=ON...${NC}"
            cmake .. -DGGML_VULKAN=ON -DVulkan_GLSLC_EXECUTABLE="${GLSLC_PATH}"
            
            echo -e "${YELLOW}[*] Compilazione in corso con $(nproc) thread...${NC}"
            cmake --build . --config Release -j$(nproc)

            echo -e "${GREEN}[✓] Compilazione llama.cpp (Vulkan) completata con successo!${NC}"
            ;;
        3)
            echo -e "${BLUE}[+] Configurazione ROCm Sperimentale con GFX Override (gfx1030)...${NC}"
            apt-get install -y -qq rocm-hip-sdk
            mkdir -p "${UNSLOTH_ENV}"
            python3 -m venv "${UNSLOTH_ENV}"
            "${UNSLOTH_ENV}/bin/pip" install --upgrade pip
            "${UNSLOTH_ENV}/bin/pip" install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm6.0
            
            # Applicazione dell'override permanente per l'ambiente
            echo "export HSA_OVERRIDE_GFX_VERSION=10.3.0" >> /root/.bashrc
            export HSA_OVERRIDE_GFX_VERSION=10.3.0
            ;;
        *)
            echo -e "${RED}Scelta non valida! Annullamento...${NC}"
            return 1
            ;;
    esac

    echo -e "${GREEN}\n[✓] Installazione completata per l'ambiente AMD!${NC}"
    read -p "Premi [INVIO] per tornare al menu principale..."
}

check_status() {
    show_header
    echo -e "${YELLOW}=== Verifico Stato Hardware & Servizi AMD ===${NC}\n"

    # Controllo Vulkan
    if command -v vulkaninfo &> /dev/null; then
        echo -e "${GREEN}[Vulkan] Supporto rilevato nel sistema.${NC}"
    else
        echo -e "${RED}[Vulkan] Strumenti non installati.${NC}"
    fi

    # Controllo ROCm
    if command -v rocm-smi &> /dev/null; then
        echo -e "${GREEN}[ROCm] ROCm SMI disponibile:${NC}"
        rocm-smi --showid || true
    else
        echo -e "${YELLOW}[ROCm] Driver o utility ROCm non rilevati.${NC}"
    fi

    # Controllo llama.cpp
    if [ -f "${LLAMA_CPP_DIR}/build/bin/llama-cli" ] || [ -f "${LLAMA_CPP_DIR}/build/bin/main" ]; then
        echo -e "${GREEN}[llama.cpp] Binario compilato con supporto Vulkan presente in ${LLAMA_CPP_DIR}/build/bin${NC}"
    fi

    echo ""
    read -p "Premi [INVIO] per tornare al menu principale..."
}

update_components() {
    show_header
    echo -e "${YELLOW}[+] Aggiornamento componenti AMD in corso...${NC}"
    if [ -d "${LLAMA_CPP_DIR}" ]; then
        cd "${LLAMA_CPP_DIR}"
        git pull
        cd build
        cmake --build . --config Release -j$(nproc)
        echo -e "${GREEN}[✓] llama.cpp aggiornato e ricompilato!${NC}"
    fi
    read -p "Premi [INVIO] per tornare al menu principale..."
}

configure_sandbox() {
    show_header
    echo -e "${YELLOW}=== Helper Configurazione Sandbox ===${NC}"
    if [ -f "./sandbox_setup.sh" ]; then
        echo -e "Per configurare un nodo remoto LXC/VM Sandbox, esegui al suo interno:"
        echo -e "${CYAN}curl -fsSL https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/sandbox_setup.sh | sudo bash${NC}\n"
    fi
    read -p "Inserisci l'IP della Sandbox da associare via SSH (oppure premi INVIO per annullare): " sandbox_ip
    if [ -n "$sandbox_ip" ]; then
        if [ ! -f /root/.ssh/id_ed25519 ]; then
            ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
        fi
        ssh-copy-id -i /root/.ssh/id_ed25519.pub "root@${sandbox_ip}" || true
    fi
    read -p "Premi [INVIO] per tornare al menu principale..."
}

uninstall_all() {
    show_header
    echo -e "${RED}=== RIMOZIONE COMPLETA AMBIENTE ===${NC}"
    read -p "Sei sicuro di voler rimuovere i servizi, le directory ed i binari installati? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "${INSTALL_DIR}" "${UNSLOTH_ENV}" "${CODE_RUNNER_DIR}"
        echo -e "${GREEN}[✓] Rimozione completata!${NC}"
    else
        echo -e "${YELLOW}Annullato.${NC}"
    fi
    read -p "Premi [INVIO] per tornare al menu principale..."
}

# --- Main Menu Loop ---
while true; do
    show_header
    echo "1) INSTALLA Servizi (ROCm / Vulkan)"
    echo "2) VERIFICA Stato Hardware & Servizi"
    echo "3) AGGIORNA Componenti & llama.cpp"
    echo "4) CONFIGURA Sandbox SSH"
    echo "5) DISINSTALLA Tutto"
    echo "6) ESCI"
    echo ""
    read -p "Seleziona un'opzione [1-6]: " choice

    case $choice in
        1) install_services ;;
        2) check_status ;;
        3) update_components ;;
        4) configure_sandbox ;;
        5) uninstall_all ;;
        6) echo -e "${GREEN}Arrivederci!${NC}"; exit 0 ;;
        *) echo -e "${RED}Opzione non valida!${NC}"; sleep 1 ;;
    esac
done
