#!/usr/bin/env bash

# ==============================================================================
# Script: manager_amd.sh
# Descrizione: Gestore deployment Homelab AI per schede grafiche AMD (ROCm / Vulkan)
# ==============================================================================

set -euo pipefail

# --- Colori per Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Variabili di Configurazione ---
INSTALL_DIR="/opt/homelab-ai"
LLAMA_CPP_DIR="${INSTALL_DIR}/llama.cpp"
BUILD_DIR="${LLAMA_CPP_DIR}/build"

# --- Funzioni di Utility ---
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Questo script richiede i permessi di root (o sudo) per installare i pacchetti."
        exit 1
    fi
}

# --- Installazione Dipendenze ---
install_dependencies() {
    log_info "Aggiornamento indici dei pacchetti..."
    apt-get update -y

    log_info "Installazione strumenti di sistema e monitoring (btop, htop, nvtop, mc)..."
    apt-get install -y \
        build-essential \
        cmake \
        git \
        curl \
        wget \
        pkg-config \
        libvulkan-dev \
        vulkan-tools \
        glslc \
        glslang-tools \
        clinfo \
        btop \
        htop \
        nvtop \
        mc

    log_success "Dipendenze di sistema e utility di monitoring installate correttamente."
}

# --- Controllo e Configurazione Driver AMD ---
setup_amd_environment() {
    log_info "Verifica rilevamento GPU AMD..."
    if lspci | grep -iE 'vga|3d|display' | grep -i 'amd\|radeon' > /dev/null; then
        log_success "GPU AMD rilevata nel sistema."
    else
        log_warn "Nessuna GPU AMD rilevata tramite lspci. Assicurati che l'hardware sia collegato."
    fi

    log_info "Configurazione variabili d'ambiente per ROCm / Vulkan..."
    
    # Export per la sessione corrente
    export GGML_VULKAN=1
    export HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION:-"10.3.0"} # Default di fallback per compatibilità ROCm
    
    # Aggiunta al profilo globale se non presente
    local env_file="/etc/profile.d/homelab_amd.sh"
    cat << 'EOF' > "$env_file"
# Homelab AI AMD Environment
export GGML_VULKAN=1
# Un-comment or adjust if using ROCm on unsupported consumer GPUs:
# export HSA_OVERRIDE_GFX_VERSION=10.3.0
EOF
    chmod +x "$env_file"
    log_success "Variabili d'ambiente salvate in $env_file"
}

# --- Setup e Compilazione llama.cpp con supporto Vulkan ---
build_llama_cpp() {
    log_info "Prepariamo la directory per llama.cpp..."
    mkdir -p "$INSTALL_DIR"
    
    if [ ! -d "$LLAMA_CPP_DIR" ]; then
        log_info "Clonazione repository llama.cpp..."
        git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_CPP_DIR"
    else
        log_info "Repository llama.cpp già presente. Aggiornamento in corso..."
        git -C "$LLAMA_CPP_DIR" pull
    fi

    log_info "Pulizia e configurazione della build CMake con Backend Vulkan..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    # Nota: Disabilitiamo l'embedding degli shader per evitare errori di compilazione SPIR-V in glslang
    cmake -S "$LLAMA_CPP_DIR" -B "$BUILD_DIR" \
        -DGGML_VULKAN=ON \
        -DGGML_VULKAN_EMBED_SHADERS=OFF \
        -DCMAKE_BUILD_TYPE=Release

    log_info "Compilazione di llama.cpp..."
    cmake --build "$BUILD_DIR" --config Release -j"$(nproc)"

    if [ -f "${BUILD_DIR}/bin/llama-cli" ] || [ -f "${BUILD_DIR}/bin/main" ]; then
        log_success "Compilazione di llama.cpp completata con successo!"
    else
        log_error "La compilazione è terminata ma i binari non sono stati trovati."
        exit 1
    fi
}

# --- Menu Principale ---
show_menu() {
    echo -e "\n=========================================="
    echo "       HOMELAB AI - MANAGER AMD"
    echo -e "=========================================="
    echo "1) Installa Dipendenze (incl. btop, htop, nvtop, mc)"
    echo "2) Configura Ambiente GPU AMD"
    echo "3) Compila / Aggiorna llama.cpp (Vulkan)"
    echo "4) Esegui Setup Completo (1 + 2 + 3)"
    echo "5) Apri Monitor di Sistema (nvtop)"
    echo "6) Esci"
    echo "=========================================="
    read -rp "Seleziona un'opzione [1-6]: " choice

    case $choice in
        1)
            check_root
            install_dependencies
            ;;
        2)
            check_root
            setup_amd_environment
            ;;
        3)
            build_llama_cpp
            ;;
        4)
            check_root
            install_dependencies
            setup_amd_environment
            build_llama_cpp
            log_success "Setup completo eseguito con successo!"
            ;;
        5)
            if command -v nvtop &> /dev/null; then
                nvtop
            else
                log_error "nvtop non risulta installato. Esegui prima l'opzione 1."
            fi
            ;;
        6)
            log_info "Uscita dal manager."
            exit 0
            ;;
        *)
            log_error "Opzione non valida."
            ;;
    esac
}

# --- Entry Point ---
main() {
    while true; do
        show_menu
    done
}

main "$@"
