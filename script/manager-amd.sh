#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Manager Script (AMD)
# Repo: mrpink77it/homelab-ai-deployer
# Version: V.1.5.5 (Uniformed Menus & 3 AMD Architectures Support)
# ==============================================================================

set -euo pipefail

trap 'echo -e "\n\033[1;31m[ERRORE FATALE] Lo script manager-amd.sh si è interrotto alla riga $LINENO. Verifica di averlo avviato con privilegi elevati (sudo).\033[0m\n"' ERR

# ------------------------------------------------------------------------------
# Risoluzione Percorsi Relativi alla Nuova Struttura
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# ------------------------------------------------------------------------------
# Configurazione Variabili Globali
# ------------------------------------------------------------------------------
VERSION="1.5.5"
LOG_FILE="/var/log/homelab-ai-amd.log"
INSTALL_DIR="/opt/homelab-ai"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
MODELS_DIR="${INSTALL_DIR}/models"
WEBUI_DIR="${INSTALL_DIR}/open-webui"

SERVICE_NAME="homelab-ai-backend"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
FRONTEND_SERVICE_FILE="/etc/systemd/system/homelab-ai-frontend.service"

# File di configurazione porte persistenti
PORT_CONFIG="/etc/homelab-ai/ports.conf"
mkdir -p /etc/homelab-ai

# Porte predefinite (se non configurate)
if [ ! -f "$PORT_CONFIG" ]; then
    cat <<EOF > "$PORT_CONFIG"
LLAMACPP_PORT=8080
OPENWEBUI_PORT=3000
EOF
fi
source "$PORT_CONFIG"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# Utility e Logging
# ------------------------------------------------------------------------------
log() {
    local level="$1"
    local msg="$2"
    if touch "${LOG_FILE}" 2>/dev/null; then
        echo -e "$(date "+%Y-%m-%d %H:%M:%S") [${level}] ${msg}" | tee -a "${LOG_FILE}"
    else
        echo -e "$(date "+%Y-%m-%d %H:%M:%S") [${level}] ${msg}"
    fi
}

log_info() { log "INFO" "${GREEN}$1${NC}"; }
log_warn() { log "WARN" "${YELLOW}$1${NC}"; }
log_err()  { log "ERROR" "${RED}$1${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Lo script richiede i privilegi di root. Avvialo con sudo."
        exit 1
    fi
}

detect_environment() {
    if [[ -f /proc/1/environ ]] && grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        echo "LXC (Proxmox)"
    else
        echo "Bare-Metal / Standard VM"
    fi
}

init_env() {
    mkdir -p "$(dirname "$LOG_FILE")" "${MODELS_DIR}" "${WEBUI_DIR}"
    touch "${LOG_FILE}" || true
}

return_to_main() {
    clear
    echo -e "${GREEN}Ritorno al menu principale...${NC}"
    sleep 1
    if [ -f "./main.sh" ]; then exec ./main.sh
    elif [ -f "../main.sh" ]; then cd .. && exec ./main.sh
    else exit 0; fi
}

# ------------------------------------------------------------------------------
# Installazione Stack Sistema
# ------------------------------------------------------------------------------
install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    export APT_LISTCHANGES_FRONTEND=none

    log_info "Verifica pacchetti base di sistema..."
    apt-get update || true
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" \
        build-essential cmake git curl wget pkg-config pciutils gnupg \
        libvulkan-dev vulkan-tools python3 python3-pip python3-venv python3-dev whiptail \
        libffi-dev libssl-dev libomp-dev || true
    
    log_info "Verifica e pulizia conflitti con pacchetti ROCm nativi..."
    apt-get remove --purge -y hipcc rocminfo "rocm-*" "libhip*" "libamdhip*" >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
}

get_amd_gpu_profile() {
    local gpu_info
    gpu_info=$(lspci | grep -iE 'vga|3d|display' | grep -i amd || true)
    
    local target="gfx1030" 
    local override=""

    if echo "$gpu_info" | grep -qiE 'navi 10|5700|5600'; then
        target="gfx1030"
        override="10.3.0"
    elif echo "$gpu_info" | grep -qiE 'navi 2|6700|6800|6900|6500'; then
        target="gfx1030"
    elif echo "$gpu_info" | grep -qiE 'navi 3|7900|7800|7600'; then
        target="gfx1100"
    elif echo "$gpu_info" | grep -qiE 'vega|radeon vii'; then
        target="gfx900,gfx906"
    elif echo "$gpu_info" | grep -qiE 'polaris|rx 580|rx 570|rx 480'; then
        target="gfx803"
        override="8.0.3"
    fi

    echo "${target}|${override}"
}

# ------------------------------------------------------------------------------
# Auto-Riparazione Toolchain ROCm
# ------------------------------------------------------------------------------
ensure_hipcc_toolchain() {
    local HIPCC_BIN="/opt/rocm/bin/hipcc"
    if [[ ! -x "$HIPCC_BIN" ]]; then
        log_warn "Compilatore hipcc non trovato. Iniezione forzata repository AMD ROCm 6.2..."
        
        mkdir -p /etc/apt/keyrings
        wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/rocm.gpg
        
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.2 noble main" > /etc/apt/sources.list.d/rocm.list
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amdgpu/6.2/ubuntu noble main" > /etc/apt/sources.list.d/amdgpu.list
        
        cat <<EOF > /etc/apt/preferences.d/99-rocm-amd
Package: *
Pin: origin repo.radeon.com
Pin-Priority: 1001
EOF
        
        export DEBIAN_FRONTEND=noninteractive
        apt-get update || true
        
        log_info "Installazione toolchain HIP/ROCm ufficiale AMD..."
        apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" rocm-dev rocm-hip-sdk || true
        
        if [[ ! -x "$HIPCC_BIN" ]]; then
            log_err "Auto-riparazione fallita. Repository non raggiungibili o pacchetti inesistenti."
            return 1
        fi
        log_info "Auto-riparazione completata: hipcc installato con successo."
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Compilazione llama.cpp & Patch FP8
# ------------------------------------------------------------------------------
compile_llama() {
    local type="$1"
    
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    
    if [[ ! -d "${LLAMA_DIR}" ]]; then
        git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
    else
        git -C "${LLAMA_DIR}" pull
    fi

    if [[ -f "${LLAMA_DIR}/ggml/src/ggml-cuda/vendors/hip.h" ]]; then
        log_info "Applicazione patch di compatibilità ROCm FP8 e fallback tipi..."
        sed -i 's/typedef __hip_fp8_e4m3 __nv_fp8_e4m3;/typedef uint8_t __nv_fp8_e4m3;/g' "${LLAMA_DIR}/ggml/src/ggml-cuda/vendors/hip.h" || true
        sed -i 's/typedef __hip_fp8_e5m2 __nv_fp8_e5m2;/typedef uint8_t __nv_fp8_e5m2;/g' "${LLAMA_DIR}/ggml/src/ggml-cuda/vendors/hip.h" || true
    fi

    log_info "Pulizia cache di compilazione..."
    rm -rf "${LLAMA_DIR}/build"
    rm -rf ~/.cache/ccache 2>/dev/null || true
    hash -r

    local gpu_profile target override
    gpu_profile=$(get_amd_gpu_profile)
    target=$(echo "$gpu_profile" | cut -d'|' -f1)
    override=$(echo "$gpu_profile" | cut -d'|' -f2)

    log_info "Avvio compilazione llama.cpp (Backend: ${type})..."

    case "${type}" in
        "vulkan")
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_VULKAN=ON
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
        "rocm"|"rocm_exp")
            if ! ensure_hipcc_toolchain; then
                return 1
            fi
            
            local ROCM_PREFIX="/opt/rocm"
            local ROCM_CLANG="${ROCM_PREFIX}/llvm/bin/clang"
            local ROCM_CLANGXX="${ROCM_PREFIX}/llvm/bin/clang++"
            local CMAKE_ROCM_FLAGS="-DGGML_HIP=ON -DAMDGPU_TARGETS=${target} -DROCM_PATH=${ROCM_PREFIX} -DCMAKE_PREFIX_PATH=${ROCM_PREFIX}/lib/cmake:${ROCM_PREFIX}/lib/x86_64-linux-gnu/cmake -DCMAKE_C_FLAGS=-Wno-pedantic -DCMAKE_CXX_FLAGS=-Wno-pedantic"
            
            export PATH="${ROCM_PREFIX}/bin:${ROCM_PREFIX}/llvm/bin:${PATH}"
            export CC="${ROCM_CLANG}"
            export CXX="${ROCM_CLANGXX}"

            if [[ "${type}" == "rocm_exp" && -n "${override}" ]]; then
                log_warn "Iniezione Hack di compatibilità: HSA_OVERRIDE_GFX_VERSION=${override}"
                export HSA_OVERRIDE_GFX_VERSION="${override}"
            fi
            
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" ${CMAKE_ROCM_FLAGS}
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
    esac

    log_info "Compilazione completata con successo."
    auto_setup_systemd_service "${type}" "${override}"
}

auto_setup_systemd_service() {
    source "$PORT_CONFIG"
    local type="$1"
    local override="$2"
    local host="0.0.0.0"
    local port="$LLAMACPP_PORT"
    local model_path="${MODELS_DIR}/model.gguf"

    local env_directives=""
    if [[ "${type}" == "rocm" || "${type}" == "rocm_exp" ]]; then
        env_directives="Environment=\"PATH=/opt/rocm/bin:/opt/rocm/llvm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\""
        env_directives+=$'\n'
        env_directives+="Environment=\"LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64\""
        if [[ -n "${override}" ]]; then
            env_directives+=$'\n'
            env_directives+="Environment=\"HSA_OVERRIDE_GFX_VERSION=${override}\""
        fi
    fi

    cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=Homelab AI Backend Service (llama.cpp)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
${env_directives}
ExecStart=${LLAMA_DIR}/build/bin/llama-server --host ${host} --port ${port} -m "${model_path}" -ngl 99
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}" || true
    log_info "Servizio ${SERVICE_NAME} configurato su porta $port e avviato."
}

# ------------------------------------------------------------------------------
# Gestione Frontend (Open WebUI)
# ------------------------------------------------------------------------------
install_open_webui() {
    source "$PORT_CONFIG"
    log_info "Installazione/Aggiornamento Open WebUI (Frontend)..."
    mkdir -p "${WEBUI_DIR}"
    
    if ! command -v uv &> /dev/null; then
        log_info "Installazione del gestore pacchetti 'uv' per l'ambiente Python..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
    fi
    
    export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
    
    if [[ ! -d "${WEBUI_DIR}/venv" ]]; then
        log_info "Creazione ambiente virtuale isolato con Python 3.11 tramite uv..."
        uv venv -p 3.11 "${WEBUI_DIR}/venv"
    fi
    
    source "${WEBUI_DIR}/venv/bin/activate"
    log_info "Aggiornamento pip e installazione di open-webui tramite uv pip..."
    uv pip install --upgrade pip
    uv pip install open-webui
    deactivate

cat <<EOF > "${FRONTEND_SERVICE_FILE}"
[Unit]
Description=Homelab AI Frontend Service (Open WebUI)
After=network.target ${SERVICE_NAME}.service

[Service]
Type=simple
User=root
WorkingDirectory=${WEBUI_DIR}
Environment="HOST=0.0.0.0"
Environment="PORT=$OPENWEBUI_PORT"
Environment="WEBUI_PORT=$OPENWEBUI_PORT"
Environment="OPENAI_API_BASE_URL=http://127.0.0.1:$LLAMACPP_PORT/v1"
ExecStart=${WEBUI_DIR}/venv/bin/open-webui serve
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable homelab-ai-frontend
    systemctl restart homelab-ai-frontend
    log_info "Open WebUI configurato con successo sulla porta $OPENWEBUI_PORT."
    whiptail --title "Successo" --msgbox "Open WebUI installato e avviato correttamente sulla porta $OPENWEBUI_PORT!" 10 60
}

# ------------------------------------------------------------------------------
# GESTIONE PORTE E STATO ATTIVO (Con Cancel uniforme)
# ------------------------------------------------------------------------------
manage_ports() {
    while true; do
        source "$PORT_CONFIG"
        
        local s_llama="CHIUSA"
        ss -tulpn | grep -q ":$LLAMACPP_PORT " && s_llama="ATTIVO"
        local s_webui="CHIUSA"
        ss -tulpn | grep -q ":$OPENWEBUI_PORT " && s_webui="ATTIVO"

        PORT_CHOICE=$(whiptail --title "Gestione Porte & Stato Servizi AMD" \
            --menu "Stato attuale e porte configurate:\n\n \
 1. llama.cpp Server  : Porta $LLAMACPP_PORT [$s_llama]\n \
 2. Open WebUI        : Porta $OPENWEBUI_PORT [$s_webui]\n" 18 75 3 \
            "CHANGE" "Modifica una porta di ascolto" \
            "RESTART" "Riavvia i servizi con le porte aggiornate" \
            "BACK" "Torna al menu principale" \
            3>&1 1>&2 2>&3)
            
        if [ $? -ne 0 ]; then break; fi

        case $PORT_CHOICE in
            "CHANGE")
                TARGET_SRV=$(whiptail --title "Cambia Porta" --menu "Seleziona il servizio da modificare:" 12 60 2 \
                    "LLAMACPP_PORT" "llama.cpp (Attuale: $LLAMACPP_PORT)" \
                    "OPENWEBUI_PORT" "Open WebUI (Attuale: $OPENWEBUI_PORT)" \
                    3>&1 1>&2 2>&3)
                
                if [ $? -ne 0 ] || [ -z "$TARGET_SRV" ]; then
                    continue
                fi

                NEW_PORT=$(whiptail --title "Nuova Porta" --inputbox "Inserisci il nuovo numero di porta per $TARGET_SRV:" 10 50 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$NEW_PORT" ]; then
                    sed -i "s/^${TARGET_SRV}=.*/${TARGET_SRV}=${NEW_PORT}/" "$PORT_CONFIG"
                    whiptail --title "Aggiornato" --msgbox "Porta modificata nel file di configurazione. Ricordati di riavviare i servizi." 10 60
                fi
                ;;
            "RESTART")
                systemctl restart "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true
                whiptail --title "Riavviati" --msgbox "Servizi riavviati con le nuove porte!" 8 50
                ;;
            "BACK")
                break
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# DASHBOARD IN BANNER WHIPTAIL
# ------------------------------------------------------------------------------
show_dashboard_banner() {
    source "$PORT_CONFIG"
    local LOCAL_IP
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    
    local st_llama="Spento"
    ss -tulpn | grep -q ":$LLAMACPP_PORT " && st_llama="In ascolto (Porta $LLAMACPP_PORT)"
    local st_webui="Spento"
    ss -tulpn | grep -q ":$OPENWEBUI_PORT " && st_webui="In ascolto (Porta $OPENWEBUI_PORT)"

    local GPU_INFO="Nessuna GPU AMD rilevata via lspci"
    GPU_INFO=$(lspci | grep -iE 'vga|3d|display' | grep -i amd | head -n 1)

    local DASH_TEXT="=== HARDWARE & GPU AMD ===\n• IP Locale : $LOCAL_IP\n• GPU       : $GPU_INFO\n\n=== STATO SERVIZI E PORTE ===\n• llama.cpp : $st_llama\n• Open WebUI: $st_webui\n\nTutti i servizi attivi operano in parallelo senza conflitti."

    whiptail --title "Dashboard di Sistema - AMD Manager" --msgbox "$DASH_TEXT" 20 75
}

# ------------------------------------------------------------------------------
# GESTIONE, DOWNLOAD E ATTIVAZIONE MODELLI (Con Cancel uniforme)
# ------------------------------------------------------------------------------
manage_models() {
    while true; do
        MODEL_CHOICE=$(whiptail --title "Gestione & Attivazione Modelli GGUF (AMD)" \
            --menu "Scegli l'operazione sui modelli:" 15 75 3 \
            "ACTIVATE_GGUF" "Seleziona e attiva un GGUF su llama.cpp" \
            "DOWNLOAD_GGUF" "Scarica file GGUF da HuggingFace" \
            "BACK"          "Torna al menu principale" \
            3>&1 1>&2 2>&3)
            
        if [ $? -ne 0 ]; then break; fi

        case "$MODEL_CHOICE" in
            "ACTIVATE_GGUF")
                mkdir -p "$MODELS_DIR"
                if [ -z "$(ls -A "$MODELS_DIR"/*.gguf 2>/dev/null)" ]; then
                    whiptail --title "Attenzione" --msgbox "Nessun file GGUF trovato in $MODELS_DIR.\nScaricalo prima usando l'opzione 'Scarica file GGUF da HuggingFace'." 10 60
                    continue
                fi
                
                GGUF_LIST=()
                while IFS= read -r file; do
                    fname=$(basename "$file")
                    fsize=$(du -h "$file" | awk '{print $1}')
                    GGUF_LIST+=("$fname" "Size: $fsize")
                done < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf")

                SELECTED_GGUF=$(whiptail --title "Attiva Modello su llama.cpp" --menu "Seleziona il GGUF da mettere in esecuzione:" 20 75 8 "${GGUF_LIST[@]}" 3>&1 1>&2 2>&3)
                
                if [ $? -ne 0 ] || [ -z "$SELECTED_GGUF" ]; then
                    continue
                fi

                ln -sf "${MODELS_DIR}/$SELECTED_GGUF" "${MODELS_DIR}/model.gguf"
                
                if [ -f "$SERVICE_FILE" ]; then
                    sed -i "s|-m \".*\"|-m \"${MODELS_DIR}/model.gguf\"|" "$SERVICE_FILE"
                    systemctl daemon-reload
                    systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
                    whiptail --title "Successo" --msgbox "Modello '$SELECTED_GGUF' attivato e servizio llama.cpp riavviato!" 10 60
                else
                    whiptail --title "Errore" --msgbox "Il servizio systemd non esiste. Configura prima il backend." 10 60
                fi
                ;;
            "DOWNLOAD_GGUF")
                URL_GGUF=$(whiptail --title "Download GGUF" --inputbox "Inserisci URL diretto del file GGUF (es. da HuggingFace):" 10 65 "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$URL_GGUF" ]; then
                    mkdir -p "$MODELS_DIR"
                    cd "$MODELS_DIR"
                    clear
                    wget -c --show-progress "$URL_GGUF"
                    local downloaded_file
                    downloaded_file=$(basename "$URL_GGUF" | cut -d? -f1)
                    if [ -f "$downloaded_file" ]; then
                        ln -sf "${MODELS_DIR}/${downloaded_file}" "${MODELS_DIR}/model.gguf"
                    fi
                    echo -ne "\nPremi INVIO per continuare..."
                    read -r
                fi
                ;;
            "BACK")
                break
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Integrazione Nuovi Task Repository
# ------------------------------------------------------------------------------
update_repo() {
    log_info "Aggiornamento Repository in corso..."
    if [[ -d "${REPO_ROOT}/.git" ]]; then
        git -C "${REPO_ROOT}" pull origin main || true
        
        chmod +x "${SCRIPT_DIR}"/*.sh 2>/dev/null || true
        [[ -f "${REPO_ROOT}/main.sh" ]] && chmod +x "${REPO_ROOT}/main.sh"
        
        log_info "Repository aggiornata. Riavvio del manager AMD in corso..."
        sleep 2
        exec "${SCRIPT_DIR}/manager-amd.sh"
    else
        log_warn "Repository non clonata tramite git. Aggiornamento manuale necessario."
        read -rp "Premi Invio per continuare..."
    fi
}

run_uninstall() {
    if [[ -x "${SCRIPT_DIR}/uninstall.sh" ]]; then
        clear
        log_warn "Avvio script di disinstallazione..."
        "${SCRIPT_DIR}/uninstall.sh"
        exit 0
    elif [[ -x "${SCRIPT_DIR}/purge-homelab-ai.sh" ]]; then
        clear
        log_warn "Avvio script di purga stack AI..."
        "${SCRIPT_DIR}/purge-homelab-ai.sh"
        exit 0
    else
        if (whiptail --title "Conferma" --yesno "Vuoi rimuovere i servizi e ripulire lo stack AMD?" 10 60); then
            systemctl stop "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true
            rm -f "${SERVICE_FILE}" "${FRONTEND_SERVICE_FILE}"
            systemctl daemon-reload
            whiptail --title "Completato" --msgbox "Servizi rimossi con successo." 8 50
        fi
    fi
}

# ------------------------------------------------------------------------------
# Gestione Servizi
# ------------------------------------------------------------------------------
manage_service_menu() {
    local action
    action=$(whiptail --title "Gestione Servizi Homelab AI" \
        --menu "\nSeleziona l'azione da compiere:" 15 78 4 \
        "1" "Avvia Servizi (Backend & Frontend)" \
        "2" "Ferma Servizi (Backend & Frontend)" \
        "3" "Riavvia Servizi (Backend & Frontend)" \
        "4" "Torna al Menu Principale" \
        3>&1 1>&2 2>&3)
    
    case "$action" in
        1) 
            systemctl start "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true
            log_info "Servizi avviati." 
            ;;
        2) 
            systemctl stop "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true
            log_info "Servizi fermati." 
            ;;
        3) 
            systemctl restart "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true
            log_info "Servizi riavviati." 
            ;;
        *) ;;
    esac
}

# ------------------------------------------------------------------------------
# Menu TUI Principale
# ------------------------------------------------------------------------------
select_backend() {
    local choice
    choice=$(whiptail --title "Selezione Backend Inferenza AMD" \
        --menu "\nSeleziona il backend grafico per la tua GPU AMD:" 18 78 3 \
        "1" "Vulkan (RACCOMANDATO per Navi / RDNA su OS Moderni)" \
        "2" "ROCm Sperimentale (Auto-fix HIPCC + Patch FP8 + Hack HSA)" \
        "3" "ROCm Ufficiale (Architetture native supportate)" \
        3>&1 1>&2 2>&3)

    case "$choice" in
        1) compile_llama "vulkan" ;;
        2) compile_llama "rocm_exp" ;;
        3) compile_llama "rocm" ;;
        *) log_warn "Operazione annullata." ;;
    esac
}

main_menu() {
    if ! command -v whiptail &> /dev/null; then apt install -y whiptail -qq; fi

    while true; do
        local choice
        choice=$(whiptail --title "Homelab AI - AMD Management Console (v${VERSION})" \
            --menu "\nAmbiente: $(detect_environment)\nScegli un'operazione:" 22 80 12 \
            "A" "Express Auto-Deploy (Tutto in un click - Vulkan)" \
            "1" "Seleziona/Compila Backend Llama.cpp (3 Architetture)" \
            "2" "Installa / Configura Open WebUI (Frontend)" \
            "3" "Scarica / Gestisci Modelli GGUF" \
            "4" "Gestione Servizi (Avvia/Ferma/Riavvia)" \
            "5" "Gestione Porte & Stato Servizi Attivi" \
            "6" "Mostra Dashboard di Sistema (Banner)" \
            "7" "Visualizza Log di Sistema" \
            "8" "Aggiorna Repository (Manager e Script)" \
            "9" "Disinstalla Stack Homelab AI" \
            "0" "Esci al Menu Principale" \
            3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then return_to_main; fi

        case "$choice" in
            "A")
                install_dependencies
                compile_llama "vulkan"
                install_open_webui
                ;;
            "1") select_backend; read -rp "Premi Invio per continuare..." ;;
            "2") install_open_webui ;;
            "3") manage_models ;;
            "4") manage_service_menu ;;
            "5") manage_ports ;;
            "6") show_dashboard_banner; read -rp "Premi Invio per continuare..." ;;
            "7") clear; tail -n 50 "${LOG_FILE}" || true; echo -ne "\nPremi INVIO per continuare..."; read -r ;;
            "8") update_repo ;;
            "9") run_uninstall ;;
            "0") return_to_main ;;
            *) return_to_main ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Avvio (Entrypoint)
# ------------------------------------------------------------------------------
check_root
init_env
install_dependencies
main_menu
