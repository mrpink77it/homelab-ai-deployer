#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Manager Nodo CPU (manager-cpu.sh)
# ==============================================================================

set -u

# Directory di lavoro di sistema
HOMELAB_DIR="/opt/homelab-ai"
MODELS_DIR="${HOMELAB_DIR}/models"
LLAMA_DIR="${HOMELAB_DIR}/llama.cpp"
WEBUI_ENV="${HOMELAB_DIR}/openwebui_env"

# ------------------------------------------------------------------------------
# Dashboard di Riepilogo Finale (Eseguita all'uscita)
# ------------------------------------------------------------------------------
show_dashboard() {
    # Colori ANSI per terminale standard
    local BOLD='\033[1m'
    local CYAN='\033[1;36m'
    local GREEN='\033[1;32m'
    local YELLOW='\033[1;33m'
    local RED='\033[1;31m'
    local RESET='\033[0m'

    # Indirizzo IP Principale
    local IP_ADDR
    IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$IP_ADDR" ] && IP_ADDR="127.0.0.1"

    # OS e Virtualizzazione
    local OS_NAME KERNEL_VER VIRT_TYPE HARDWARE_MODEL
    OS_NAME=$(source /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "Linux")
    KERNEL_VER=$(uname -r)
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "baremetal")
    HARDWARE_MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "System Product Name")

    # CPU Metrics
    local CPU_MODEL CORES_PHYSICAL LOGICAL_THREADS CPU_LOAD
    CPU_MODEL=$(lscpu 2>/dev/null | grep "Model name:" | sed 's/Model name:\s*//' | xargs)
    [ -z "$CPU_MODEL" ] && CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
    CORES_PHYSICAL=$(lscpu 2>/dev/null | grep "Core(s) per socket:" | awk '{print $4}')
    LOGICAL_THREADS=$(nproc 2>/dev/null || echo "N/A")
    CPU_LOAD=$(uptime | awk -F'load average:' '{ print $2 }' | xargs)

    # RAM Metrics
    local RAM_USED RAM_TOTAL RAM_FREE RAM_USAGE_PCT
    RAM_USED=$(free -h | awk '/^Mem:/ {print $3}')
    RAM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
    RAM_FREE=$(free -h | awk '/^Mem:/ {print $4}')
    RAM_USAGE_PCT=$(free | awk '/^Mem:/ {printf "%.1f", $3/$2 * 100}')

    clear
    echo -e "================================================================================"
    echo -e "            HOMELAB AI DEPLOYER - DASHBOARD NODO INFERENZA CPU                  "
    echo -e "================================================================================"
    echo ""

    # 1. HARDWARE & SISTEMA OPERATIVO
    echo -e "► HARDWARE & SISTEMA OPERATIVO"
    printf "  • %-20s : %s (%s)\n" "OS / Kernel" "$OS_NAME" "$KERNEL_VER"
    printf "  • %-20s : %s (Virtualizzazione: %s)\n" "Piattaforma" "$HARDWARE_MODEL" "$VIRT_TYPE"
    printf "  • %-20s : %s\n" "Processore (CPU)" "${CPU_MODEL:-N/A}"
    printf "  • %-20s : %s Core Fisici / %s Thread Logici\n" "Core / Thread" "${CORES_PHYSICAL:-N/A}" "$LOGICAL_THREADS"
    printf "  • %-20s : %s\n" "Carico CPU (Load)" "$CPU_LOAD"
    printf "  • %-20s : %s usati / %s totali (Liberi: %s) [Impegno: %s%%]\n\n" "Memoria RAM" "$RAM_USED" "$RAM_TOTAL" "$RAM_FREE" "$RAM_USAGE_PCT"

    # 2. STATO DISCHI E STORAGE
    echo -e "► STATO DISCHI E STORAGE"
    printf "  %-35s Tot: %-8s Usato: %-8s Lib: %-8s Uso: %s\n" "Filesystem" "Size" "Used" "Avail" "Use%"
    df -h / "${HOMELAB_DIR}" 2>/dev/null | tail -n +2 | sort -u | awk '{
        printf "  %-35s Tot: %-8s Usato: %-8s Lib: %-8s Uso: %s\n", $1, $2, $3, $4, $5
    }'
    echo ""

    # 3. SENSORI TEMPERATURA
    echo -e "► SENSORI TEMPERATURA"
    if command -v sensors &>/dev/null; then
        sensors 2>/dev/null | grep -E 'Core|Package|temp1' | head -n 5 | while read -r line; do
            echo -e "  • $line"
        done
    else
        echo -e "  • Sensori non disponibili (lm-sensors non presente)"
    fi
    echo ""

    # 4. MODELLI AI (GGUF)
    echo -e "► MODELLI AI (GGUF)"
    echo -e "  • Modelli archiviati in ${MODELS_DIR}:"
    if [ -d "${MODELS_DIR}" ] && [ "$(ls -A "${MODELS_DIR}"/*.gguf 2>/dev/null)" ]; then
        for model in "${MODELS_DIR}"/*.gguf; do
            local size
            size=$(du -h "$model" | awk '{print $1}')
            echo -e "    - ${model} (${size})"
        done
    else
        echo -e "    - Nessun modello GGUF presente in directory."
    fi
    echo ""

    # 5. STATO SERVIZI, PORTE & ENDPOINT CONNESIONE
    echo -e "► STATO SERVIZI, PORTE & ENDPOINT CONNESIONE"

    if systemctl is-active --quiet llama-server.service 2>/dev/null; then
        echo -e "  [1] Llama.cpp Engine (API Server)"
        echo -e "      • Stato Servizio : active"
        echo -e "      • Protocollo     : HTTP / REST (Compatibile OpenAI)"
        echo -e "      • Indirizzo/Porta: ${IP_ADDR}:8080 (0.0.0.0:8080)"
        echo -e "      • Endpoint API   : http://${IP_ADDR}:8080/v1"
        echo -e "      • Health Check   : http://${IP_ADDR}:8080/health"
    else
        echo -e "  [1] Llama.cpp Engine (API Server) - Inattivo"
    fi

    if systemctl is-active --quiet open-webui.service 2>/dev/null; then
        echo -e "  [2] Open WebUI (Interfaccia Grafica Web)"
        echo -e "      • Stato Servizio : active"
        echo -e "      • Protocollo     : HTTP"
        echo -e "      • Indirizzo/Porta: ${IP_ADDR}:8081"
        echo -e "      • Web UI URL     : http://${IP_ADDR}:8081"
    else
        echo -e "  [2] Open WebUI (Interfaccia Grafica Web) - Inattiva"
    fi

    echo ""
    echo -e "================================================================================"
    echo -e " Sessione terminata. Per riaprire il manager esegui: ./manager-cpu.sh"
    echo -e "================================================================================"
    echo ""
}

# Registra la dashboard per l'esecuzione automatica all'uscita dello script
trap show_dashboard EXIT

# ------------------------------------------------------------------------------
# Funzioni Operative del Manager
# ------------------------------------------------------------------------------
install_llama_cpp() {
    echo -e "\n[+] Preparazione dell'ambiente ed installazione dipendenze C++..."
    mkdir -p "${HOMELAB_DIR}" "${MODELS_DIR}"
    apt-get update && apt-get install -y build-essential cmake git libopenblas-dev lm-sensors
    
    if [ ! -d "${LLAMA_DIR}" ]; then
        git clone https://github.com/ggerganov/llama.cpp "${LLAMA_DIR}"
    else
        echo "[+] Repository llama.cpp già presente. Aggiornamento in corso..."
        cd "${LLAMA_DIR}" && git pull
    fi

    cd "${LLAMA_DIR}"
    echo "[+] Compilazione nativa con accelerazione BLAS e ottimizzazioni CPU..."
    cmake -B build -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS
    cmake --build build --config Release -j"$(nproc)"
    echo "[+] Compilazione completata con successo."
    read -rp "Premere INVIO per continuare..."
}

install_open_webui() {
    echo -e "\n[+] Installazione Open WebUI in ambiente virtuale dedicato..."
    mkdir -p "${HOMELAB_DIR}"
    apt-get update && apt-get install -y python3-venv python3-pip
    
    if [ ! -d "${WEBUI_ENV}" ]; then
        python3 -m venv "${WEBUI_ENV}"
    fi

    "${WEBUI_ENV}/bin/pip" install --upgrade pip
    "${WEBUI_ENV}/bin/pip" install open-webui
    echo "[+] Open WebUI installato correttamente."
    read -rp "Premere INVIO per continuare..."
}

configure_systemd_services() {
    echo -e "\n[+] Configurazione dei servizi Systemd..."
    
    # Servizio Llama Server
    cat <<EOF > /etc/systemd/system/llama-server.service
[Unit]
Description=Llama.cpp HTTP API Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${HOMELAB_DIR}
ExecStart=${LLAMA_DIR}/build/bin/llama-server --host 0.0.0.0 --port 8080 -m ${MODELS_DIR}/default.gguf -c 4096 --threads $(nproc)
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Servizio Open WebUI
    cat <<EOF > /etc/systemd/system/open-webui.service
[Unit]
Description=Open WebUI Service
After=network.target llama-server.service

[Service]
Type=simple
User=root
Environment="DATA_DIR=${HOMELAB_DIR}/open-webui-data"
Environment="OPENAI_API_BASE_URL=http://127.0.0.1:8080/v1"
ExecStart=${WEBUI_ENV}/bin/open-webui serve --port 8081
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now llama-server.service open-webui.service 2>/dev/null || true
    echo "[+] Servizi Systemd creati ed avviati."
    read -rp "Premere INVIO per continuare..."
}

run_cpu_benchmark() {
    if [ ! -f "${LLAMA_DIR}/build/bin/llama-bench" ]; then
        echo -e "\n[!] Binario llama-bench non trovato. Eseguire prima la compilazione."
    else
        echo -e "\n[+] Avvio del Benchmark CPU (llama-bench)..."
        "${LLAMA_DIR}/build/bin/llama-bench" -t "$(nproc)"
    fi
    read -rp "Premere INVIO per continuare..."
}

# ------------------------------------------------------------------------------
# Menu Interattivo Principale
# ------------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "================================================================================"
        echo "               HOMELAB AI DEPLOYER - MANAGER NODO CPU                           "
        echo "================================================================================"
        echo " 1) COMPILA llama.cpp (Nativo C++ con OpenBLAS/AVX)"
        echo " 2) INSTALLA Open WebUI (Python venv)"
        echo " 3) CONFIGURA Servizi Systemd (llama-server & open-webui)"
        echo " 4) BENCHMARK CPU (llama-bench)"
        echo " 0) ESCI E MOSTRA DASHBOARD"
        echo "================================================================================"
        read -rp "Seleziona un'opzione [0-4]: " choice

        case $choice in
            1) install_llama_cpp ;;
            2) install_open_webui ;;
            3) configure_systemd_services ;;
            4) run_cpu_benchmark ;;
            0) exit 0 ;;
            *) echo "Opzione non valida."; sleep 1 ;;
        esac
    done
}

# Avvio del menu
main_menu
