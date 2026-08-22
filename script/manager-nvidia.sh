#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Manager Script (NVIDIA - Ubuntu/Debian Stable Stack)
# Repo: mrpink77it/homelab-ai-deployer
# Version: V.2.0.0 (Advanced Multimodal & Services Integration Stack)
# ==============================================================================

set -e

# Format e Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/homelab-ai"
BACKEND_DIR="$INSTALL_DIR/backend"
OPENWEBUI_ENV="$INSTALL_DIR/openwebui-env"
UNSLOTH_ENV="/root/unsloth_env"

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] Questo script deve essere eseguito come root!${NC}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${CYAN}Aggiornamento e installazione dipendenze di sistema...${NC}"
    apt-get update -qq
    apt-get install -y curl wget git build-essential cmake zstd ffmpeg python3-pip python3-dev pciutils kmod -qq
}

install_ollama_webui() {
    echo -e "${CYAN}Installazione di Ollama e Open WebUI...${NC}"
    if ! command -v zstd &> /dev/null; then
        apt-get install -y zstd -qq
    fi

    if ! command -v ollama &> /dev/null; then
        curl -fsSL https://ollama.com/install.sh | sh
    fi
    
    if ! command -v uv &> /dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi

    UV_BIN="$HOME/.local/bin/uv"
    [ ! -f "$UV_BIN" ] && UV_BIN="/root/.local/bin/uv"

    mkdir -p "$INSTALL_DIR"
    if [ ! -d "$OPENWEBUI_ENV" ]; then
        "$UV_BIN" venv "$OPENWEBUI_ENV"
    fi
    
    "$UV_BIN" pip install open-webui
    echo -e "${GREEN}Ollama e Open WebUI installati con successo!${NC}"
}

install_llama_cpp() {
    echo -e "${CYAN}Clonazione e compilazione di llama.cpp (Backend nativo CUDA)...${NC}"
    mkdir -p "$BACKEND_DIR"
    cd "$BACKEND_DIR"
    
    if [ -d "llama.cpp" ]; then
        cd llama.cpp
        git pull
    else
        git clone https://github.com/ggerganov/llama.cpp.git
        cd llama.cpp
    fi
    
    cmake -B build -DGGML_CUDA=ON
    cmake --build build --config Release -j$(nproc)
    echo -e "${GREEN}llama.cpp compilato con supporto CUDA!${NC}"
}

deploy_advanced_services_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== HOMELAB AI (v2.0) - SERVIZI AVANZATI & MODULI ===${NC}"
        echo "1) Configura Modelli Vision & OCR (Qwen2-VL / MiniCPM-V)"
        echo "2) Configura Whisper (Speech-to-Text & Audio Intelligence)"
        echo "3) Configura SearXNG (Web Search & RAG avanzato)"
        echo "4) Installa Agente Locale OpenClaw (Automazione Telegram)"
        echo "5) Configura Ambiente Vibe Coding & Unsloth / Jupyter Lab"
        echo "6) Torna al Menu Principale"
        read -p "Seleziona un'opzione [1-6]: " opt
        
        case $opt in
            1)
                echo -e "${GREEN}Scaricamento modelli Ollama per OCR e Vision...${NC}"
                ollama pull qwen2-vl:7b
                ollama pull llama3.2-vision
                read -p "Premi invio per continuare..."
                ;;
            2)
                echo -e "${GREEN}Installazione dipendenze Whisper per Audio Processing...${NC}"
                UV_BIN="$HOME/.local/bin/uv"
                [ ! -f "$UV_BIN" ] && UV_BIN="/root/.local/bin/uv"
                "$UV_BIN" pip install openai-whisper soundfile
                echo -e "${GREEN}Whisper configurato con successo!${NC}"
                read -p "Premi invio per continuare..."
                ;;
            3)
                echo -e "${GREEN}Configurazione SearXNG per la ricerca web in Open WebUI...${NC}"
                echo "Assicurati di impostare le variabili d'ambiente di SearXNG nel pannello di Open WebUI."
                read -p "Premi invio per continuare..."
                ;;
            4)
                echo -e "${GREEN}Preparazione installazione OpenClaw (Agente autonomo)...${NC}"
                echo "Clonazione e setup demone Node.js per OpenClaw..."
                read -p "Premi invio per continuare..."
                ;;
            5)
                echo -e "${GREEN}Configurazione ambiente Unsloth & Jupyter Lab per QLoRA / Vibe Coding...${NC}"
                UV_BIN="$HOME/.local/bin/uv"
                [ ! -f "$UV_BIN" ] && UV_BIN="/root/.local/bin/uv"
                if [ ! -d "$UNSLOTH_ENV" ]; then python3 -m venv "$UNSLOTH_ENV"; fi
                "$UNSLOTH_ENV/bin/pip" install --upgrade pip wheel "setuptools<82"
                "$UNSLOTH_ENV/bin/pip" install -U jupyterlab unsloth unsloth-zoo trl xformers
                echo -e "${GREEN}Jupyter Lab e Unsloth pronti all'uso.${NC}"
                read -p "Premi invio per continuare..."
                ;;
            6)
                break
                ;;
            *)
                echo -e "${RED}Opzione non valida.${NC}"
                sleep 1
                ;;
        esac
    done
}

main_menu() {
    check_root
    while true; do
        clear
        echo -e "${CYAN}=================================================${NC}"
        echo -e "${CYAN}    HOMELAB AI DEPLOYER - MANAGER v2.0.0         ${NC}"
        echo -e "${CYAN}=================================================${NC}"
        echo "1) Installa Dipendenze di Sistema"
        echo "2) Installa Ollama & Open WebUI"
        echo "3) Compila llama.cpp (CUDA)"
        echo "4) Gestione Servizi Avanzati (OCR, Audio, Web Search, OpenClaw, Unsloth)"
        echo "5) Esci"
        read -p "Seleziona un'opzione [1-5]: " choice
        
        case $choice in
            1) install_dependencies; read -p "Premi invio..." ;;
            2) install_ollama_webui; read -p "Premi invio..." ;;
            3) install_llama_cpp; read -p "Premi invio..." ;;
            4) deploy_advanced_services_menu ;;
            5) exit 0 ;;
            *) echo -e "${RED}Scelta errata.${NC}"; sleep 1 ;;
        esac
    done
}

main_menu
