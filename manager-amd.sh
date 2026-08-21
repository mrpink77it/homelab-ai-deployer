#!/usr/bin/env bash
# ==============================================================================
# Script: manager-amd.sh
# Versione: 1.1.3
# Descrizione: Gestore deployment GPU AMD (Backend pulito v1.0.0 + Menu Modelli Top & Express)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configurazione Variabili Globali
# ------------------------------------------------------------------------------
VERSION="1.1.3"
INSTALL_DIR="/opt/homelab-ai"
MODELS_DIR="${INSTALL_DIR}/models"
BACKEND_DIR="${INSTALL_DIR}/backend"
FRONTEND_DIR="${INSTALL_DIR}/frontend"

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'

AMD_MODE="ROCm"

# ------------------------------------------------------------------------------
# Funzioni di Utilità
# ------------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${C_RED}[ERRORE] Questo script richiede i privilegi di root. Usa sudo.${C_RESET}"
        exit 1
    fi
}

setup_directories() {
    mkdir -p "${MODELS_DIR}" "${BACKEND_DIR}" "${FRONTEND_DIR}"
}

choose_amd_mode() {
    if ! command -v whiptail &> /dev/null; then
        apt-get update -qq && apt-get install -y whiptail
    fi

    local choice
    choice=$(whiptail --title "Homelab AI Deployer - Setup AMD" \
        --menu "\nSeleziona il tipo di driver/backend GPU da configurare:" 17 75 5 \
        "1" "Vulkan (Compatibilità universale su tutte le schede AMD)" \
        "2" "ROCm (Supportato ufficialmente - RX 6000/7000, Instinct)" \
        "3" "ROCm (Experimental - Forzato su GPU non supportate)" \
        "0" "Indietro al Menu Principale (main.sh)" \
        3>&1 1>&2 2>&3) || return 1

    case "$choice" in
        1) AMD_MODE="Vulkan" ;;
        2) AMD_MODE="ROCm" ;;
        3) AMD_MODE="ROCm-Experimental" ;;
        0) return 1 ;;
    esac
    return 0
}

# ------------------------------------------------------------------------------
# Funzioni Core (Logica pulita v1.0.0 ripristinata)
# ------------------------------------------------------------------------------
install_backend() {
    echo -e "${C_CYAN}>>> Installazione Backend (llama.cpp - Modalità: ${AMD_MODE})...${C_RESET}"
    setup_directories
    cd "${BACKEND_DIR}"
    
    LATEST_RELEASE=$(curl -sL https://api.github.com/repos/ggerganov/llama.cpp/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
    
    if [[ -z "$LATEST_RELEASE" ]]; then
        LATEST_RELEASE="b4754"
    fi
    
    local target_bin="ubuntu-x64-rocm"
    if [[ "$AMD_MODE" == "Vulkan" ]]; then
        target_bin="ubuntu-x64-vulkan"
    fi

    DOWNLOAD_URL="https://github.com/ggerganov/llama.cpp/releases/download/${LATEST_RELEASE}/llama-${LATEST_RELEASE}-bin-${target_bin}.zip"
    
    echo -e "${C_CYAN}>>> Download in corso (GitHub) per Linux (${target_bin})...${C_RESET}"
    curl -L --progress-bar -o llama-amd.zip "$DOWNLOAD_URL" || true
    
    # CONTROLLO INTEGRITÀ ZIP: Verifica magic bytes 'PK' per evitare blocchi da pagine HTML di errore
    if [[ -f "llama-amd.zip" ]] && head -c 2 "llama-amd.zip" | grep -q "PK"; then
        echo -e "${C_GREEN}[OK] Archivio ZIP valido.${C_RESET}"
    else
        echo -e "${C_YELLOW}[AVVISO] Release recente non disponibile o non valida. Uso versione stabile di fallback (b4754)...${C_RESET}"
        LATEST_RELEASE="b4754"
        DOWNLOAD_URL="https://github.com/ggerganov/llama.cpp/releases/download/${LATEST_RELEASE}/llama-${LATEST_RELEASE}-bin-${target_bin}.zip"
        curl -L --progress-bar -o llama-amd.zip "$DOWNLOAD_URL"
    fi

    if ! command -v unzip &> /dev/null; then
        apt-get install -y unzip >/dev/null || true
    fi
    
    unzip -o llama-amd.zip -d ./ >/dev/null || true
    rm -f llama-amd.zip
    
    find . -name "llama-server" -exec mv {} ./llama-server-amd \; 2>/dev/null || true
    
    if [[ -f "./llama-server-amd" ]]; then
        chmod +x llama-server-amd
        echo -e "${C_GREEN}Backend ${AMD_MODE} installato con successo.${C_RESET}"
    else
        echo -e "${C_RED}[ERRORE] Eseguibile 'llama-server' non trovato nello ZIP.${C_RESET}"
    fi
}

install_frontend() {
    echo -e "${C_CYAN}>>> Installazione Open WebUI (Python venv via uv)...${C_RESET}"
    setup_directories
    export PATH="/root/.cargo/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    
    if ! command -v uv &> /dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi

    cd "${FRONTEND_DIR}"
    uv venv .venv
    VIRTUAL_ENV="${FRONTEND_DIR}/.venv" uv pip install open-webui
    echo -e "${C_GREEN}Frontend installato.${C_RESET}"
}

setup_services() {
    echo -e "${C_CYAN}>>> Configurazione Servizi Systemd...${C_RESET}"
    
    local env_vars=""
    if [[ "$AMD_MODE" == "ROCm-Experimental" ]]; then
        env_vars="Environment=\"HSA_OVERRIDE_GFX_VERSION=10.3.0\""
    fi

    cat <<EOF > /etc/systemd/system/homelab-ai-backend.service
[Unit]
Description=Homelab AI Backend (llama.cpp - AMD)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${BACKEND_DIR}
${env_vars}
ExecStart=${BACKEND_DIR}/llama-server-amd -m ${MODELS_DIR}/model.gguf --host 127.0.0.1 --port 8080 -c 4096 -ngl 99
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > /etc/systemd/system/homelab-ai-frontend.service
[Unit]
Description=Homelab AI Frontend (Open WebUI)
After=network.target homelab-ai-backend.service

[Service]
Type=simple
User=root
WorkingDirectory=${FRONTEND_DIR}
Environment="PATH=/root/.cargo/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="OLLAMA_BASE_URL=http://127.0.0.1:8080"
Environment="WEBUI_AUTH=False"
Environment="HOST=0.0.0.0"
Environment="PORT=3000"
ExecStart=${FRONTEND_DIR}/.venv/bin/open-webui serve
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable homelab-ai-backend homelab-ai-frontend || true
    systemctl restart homelab-ai-backend homelab-ai-frontend || true
    echo -e "${C_GREEN}Servizi configurati e avviati.${C_RESET}"
    sleep 2
}

download_models_menu() {
    setup_directories
    local m_choice
    m_choice=$(whiptail --title "Download & Tuning Modelli AMD (8GB / 16GB VRAM)" \
        --menu "\nSeleziona un modello top per Vulkan, scarica tutti o inserisci URL custom:" 22 78 13 \
        "1" "[8GB] Llama 3.1 8B Instruct (Q4_K_M)" \
        "2" "[8GB] Qwen 2.5 7B Instruct (Q4_K_M)" \
        "3" "[8GB] Qwen 2.5 Coder 7B Instruct (Q4_K_M)" \
        "4" "[8GB] Google Gemma 2 9B Instruct (Q4_K_M)" \
        "5" "[8GB] Llama 3.2 3B Instruct (Q8_0)" \
        "6" "[16GB] Qwen 2.5 14B Instruct (Q4_K_M)" \
        "7" "[16GB] DeepSeek-R1-Distill-Qwen-14B (Q4_K_M)" \
        "8" "[16GB] Mistral Nemo 12B Instruct (Q4_K_M)" \
        "9" "[16GB] DeepSeek-Coder-V2-Lite-Instruct 16B (Q4_K_M)" \
        "10" "[16GB] Phi-3.5 Medium 14B Instruct (Q4_K_M)" \
        "A" "Scarica TUTTI i 10 modelli in un colpo solo" \
        "C" "Inserisci URL GGUF personalizzato (Custom)" \
        "0" "Torna indietro (Annulla)" \
        3>&1 1>&2 2>&3) || return

    cd "${MODELS_DIR}"
    local url=""
    local filename=""

    case "$m_choice" in
        1) filename="llama-3.1-8b-instruct-q4_k_m.gguf"; url="https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf" ;;
        2) filename="qwen-2.5-7b-instruct-q4_k_m.gguf"; url="https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m.gguf" ;;
        3) filename="qwen-2.5-coder-7b-instruct-q4_k_m.gguf"; url="https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf" ;;
        4) filename="gemma-2-9b-instruct-q4_k_m.gguf"; url="https://huggingface.co/bartowski/gemma-2-9b-instruct-GGUF/resolve/main/gemma-2-9b-instruct-Q4_K_M.gguf" ;;
        5) filename="llama-3.2-3b-instruct-q8_0.gguf"; url="https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q8_0.gguf" ;;
        6) filename="qwen-2.5-14b-instruct-q4_k_m.gguf"; url="https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF/resolve/main/qwen2.5-14b-instruct-q4_k_m.gguf" ;;
        7) filename="deepseek-r1-distill-qwen-14b-q4_k_m.gguf"; url="https://huggingface.co/unsloth/DeepSeek-R1-Distill-Qwen-14B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf" ;;
        8) filename="mistral-nemo-12b-instruct-q4_k_m.gguf"; url="https://huggingface.co/bartowski/Mistral-Nemo-12B-Instruct-2407-GGUF/resolve/main/Mistral-Nemo-12B-Instruct-2407-Q4_K_M.gguf" ;;
        9) filename="deepseek-coder-v2-lite-instruct-q4_k_m.gguf"; url="https://huggingface.co/bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF/resolve/main/DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf" ;;
        10) filename="phi-3.5-medium-instruct-q4_k_m.gguf"; url="https://huggingface.co/bartowski/Phi-3.5-medium-instruct-GGUF/resolve/main/Phi-3.5-medium-instruct-Q4_K_M.gguf" ;;
        A)
            echo -e "${C_CYAN}>>> Avvio download di tutti i 10 modelli top...${C_RESET}"
            local urls=(
                "https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
                "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m.gguf"
                "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf"
                "https://huggingface.co/bartowski/gemma-2-9b-instruct-GGUF/resolve/main/gemma-2-9b-instruct-Q4_K_M.gguf"
                "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q8_0.gguf"
                "https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF/resolve/main/qwen2.5-14b-instruct-q4_k_m.gguf"
                "https://huggingface.co/unsloth/DeepSeek-R1-Distill-Qwen-14B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
                "https://huggingface.co/bartowski/Mistral-Nemo-12B-Instruct-2407-GGUF/resolve/main/Mistral-Nemo-12B-Instruct-2407-Q4_K_M.gguf"
                "https://huggingface.co/bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF/resolve/main/DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf"
                "https://huggingface.co/bartowski/Phi-3.5-medium-instruct-GGUF/resolve/main/Phi-3.5-medium-instruct-Q4_K_M.gguf"
            )
            local names=(
                "llama-3.1-8b-instruct-q4_k_m.gguf"
                "qwen-2.5-7b-instruct-q4_k_m.gguf"
                "qwen-2.5-coder-7b-instruct-q4_k_m.gguf"
                "gemma-2-9b-instruct-q4_k_m.gguf"
                "llama-3.2-3b-instruct-q8_0.gguf"
                "qwen-2.5-14b-instruct-q4_k_m.gguf"
                "deepseek-r1-distill-qwen-14b-q4_k_m.gguf"
                "mistral-nemo-12b-instruct-q4_k_m.gguf"
                "deepseek-coder-v2-lite-instruct-q4_k_m.gguf"
                "phi-3.5-medium-instruct-q4_k_m.gguf"
            )
            for i in "${!urls[@]}"; do
                echo -e "${C_CYAN}Scaricamento in corso (${i}/10): ${names[$i]}...${C_RESET}"
                curl -L --progress-bar -o "${names[$i]}" "${urls[$i]}"
            done
            ln -sf "${names[0]}" model.gguf
            echo -e "${C_GREEN}Tutti i modelli sono stati scaricati! Impostato ${names[0]} come attivo.${C_RESET}"
            setup_services
            sleep 3
            return
            ;;
        C)
            local custom_url
            custom_url=$(whiptail --title "URL Custom GGUF" --inputbox "\nInserisci l'URL diretto al file .gguf:" 10 70 3>&1 1>&2 2>&3) || return
            if [[ -n "$custom_url" ]]; then
                filename=$(basename "$custom_url" | cut -d? -f1)
                [[ -z "$filename" || "$filename" == "." ]] && filename="custom-model.gguf"
                echo -e "${C_CYAN}Download custom in corso: ${filename}...${C_RESET}"
                curl -L --progress-bar -o "$filename" "$custom_url"
                ln -sf "$filename" model.gguf
                echo -e "${C_GREEN}Download custom completato e impostato come attivo.${C_RESET}"
                setup_services
                sleep 2
            fi
            return
            ;;
        0) return ;;
    esac

    if [[ -n "$url" ]]; then
        echo -e "${C_CYAN}Download di ${filename} in corso...${C_RESET}"
        curl -L --progress-bar -o "$filename" "$url"
        ln -sf "$filename" model.gguf
        echo -e "${C_GREEN}Download completato e impostato come modello attivo.${C_RESET}"
        setup_services
        sleep 2
    fi
}

show_hardware_profile() {
    clear
    echo -e "${C_CYAN}=== PROFILO HARDWARE ===${C_RESET}"
    lscpu | grep -E "Model name|Thread\(s\) per core|Core\(s\) per socket" || true
    free -h
    echo -e "\n${C_CYAN}=== SCHEDA VIDEO AMD ===${C_RESET}"
    lspci | grep -iE 'vga|3d|display' | grep -i amd || echo "Nessuna GPU AMD rilevata su bus PCI"
    echo ""
    read -n 1 -s -r -p "Premi un tasto per continuare..."
}

run_benchmark() {
    clear
    if [[ -f "${BACKEND_DIR}/llama-bench" ]]; then
        echo -e "${C_CYAN}Esecuzione llama-bench su modello caricato...${C_RESET}"
        "${BACKEND_DIR}/llama-bench" -m "${MODELS_DIR}/model.gguf" -ngl 99 || true
    else
        echo -e "${C_RED}Eseguibile llama-bench non trovato.${C_RESET}"
    fi
    echo ""
    read -n 1 -s -r -p "Premi un tasto per continuare..."
}

show_dashboard() {
    clear
    local ip_addr=$(hostname -I | awk '{print $1}')
    [[ -z "$ip_addr" ]] && ip_addr="127.0.0.1"
    local be_status="${C_RED}🔴 INATTIVO${C_RESET}"
    local fe_status="${C_RED}🔴 INATTIVO${C_RESET}"
    if systemctl is-active --quiet homelab-ai-backend; then be_status="${C_GREEN}🟢 ATTIVO${C_RESET}"; fi
    if systemctl is-active --quiet homelab-ai-frontend; then fe_status="${C_GREEN}🟢 ATTIVO${C_RESET}"; fi
    echo -e "${C_CYAN}========================================================================${C_RESET}"
    echo -e " ${C_BOLD}📊 DASHBOARD AMD v${VERSION}${C_RESET}"
    echo -e "${C_CYAN}========================================================================${C_RESET}\n"
    echo -e "  Backend AI: ${be_status} | Frontend: ${fe_status}"
    echo -e "\n  Interfaccia Web: http://${ip_addr}:3000\n"
    read -n 1 -s -r -p "Premi un tasto per tornare al menu..."
}

main_menu() {
    local DEFAULT_ITEM="A"
    while true; do
        local choice
        choice=$(whiptail --title "Homelab AI Deployer - Manager AMD (v${VERSION})" \
            --default-item "${DEFAULT_ITEM}" \
            --menu "\nSeleziona un'operazione [Modo: ${AMD_MODE}]:" 18 75 9 \
            "A" "Express Auto-Deploy (Pipeline Completa)" \
            "1" "Installa llama.cpp (Vulkan / ROCm)" \
            "2" "Installa Open WebUI (Python venv via uv)" \
            "3" "Configura & Avvia Servizi Systemd" \
            "4" "Mostra Profilo Hardware (CPU & GPU AMD)" \
            "5" "Download & Tuning Modelli AMD (8/16 GB)" \
            "6" "Esegui Benchmark GPU (llama-bench)" \
            "D" "Mostra Dashboard Sistema" \
            "0" "Indietro (Cambia Modalità GPU)" \
            3>&1 1>&2 2>&3) || return 0

        case "$choice" in
            A) install_backend; download_models_menu; install_frontend; setup_services; DEFAULT_ITEM="D" ;;
            1) install_backend; DEFAULT_ITEM="2" ;;
            2) install_frontend; DEFAULT_ITEM="3" ;;
            3) setup_services; DEFAULT_ITEM="D" ;;
            4) show_hardware_profile; DEFAULT_ITEM="5" ;;
            5) download_models_menu; DEFAULT_ITEM="3" ;;
            6) run_benchmark; DEFAULT_ITEM="D" ;;
            D) show_dashboard; DEFAULT_ITEM="A" ;;
            0) return 0 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------------------------
check_root
while true; do
    if ! choose_amd_mode; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "${SCRIPT_DIR}/main.sh" ]]; then exec "${SCRIPT_DIR}/main.sh"; else exit 0; fi
    fi
    main_menu
done
