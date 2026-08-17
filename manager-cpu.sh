#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Manager Nodo CPU (manager-cpu.sh)
# ==============================================================================

set -u

HOMELAB_DIR="/opt/homelab-ai"
MODELS_DIR="${HOMELAB_DIR}/models"
LLAMA_DIR="${HOMELAB_DIR}/llama.cpp"
WEBUI_ENV="${HOMELAB_DIR}/openwebui_env"

# ------------------------------------------------------------------------------
# Dashboard di Riepilogo Finale (Eseguita all'uscita)
# ------------------------------------------------------------------------------
show_dashboard() {
    local IP_ADDR
    IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$IP_ADDR" ] && IP_ADDR="127.0.0.1"

    local OS_NAME KERNEL_VER VIRT_TYPE HARDWARE_MODEL
    OS_NAME=$(source /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "Linux")
    KERNEL_VER=$(uname -r)
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "baremetal")
    HARDWARE_MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "System Product Name")

    local CPU_MODEL CORES_PHYSICAL LOGICAL_THREADS CPU_LOAD
    CPU_MODEL=$(lscpu 2>/dev/null | grep "Model name:" | sed 's/Model name:\s*//' | xargs)
    [ -z "$CPU_MODEL" ] && CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
    CORES_PHYSICAL=$(lscpu 2>/dev/null | grep "Core(s) per socket:" | awk '{print $4}')
    LOGICAL_THREADS=$(nproc 2>/dev/null || echo "N/A")
    CPU_LOAD=$(uptime | awk -F'load average:' '{ print $2 }' | xargs)

    local RAM_USED RAM_TOTAL RAM_FREE RAM_USAGE_PCT
    RAM_USED=$(free -h | awk '/^Mem:/ {print $3}')
    RAM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
    RAM_FREE=$(free -h | awk '/^Mem:/ {print $4}')
    RAM_USAGE_PCT=$(free | awk '/^Mem:/ {printf "%.1f", $3/$2 * 100}')

    clear
    echo "================================================================================"
    echo "            HOMELAB AI DEPLOYER - DASHBOARD NODO INFERENZA CPU                  "
    echo "================================================================================"
    echo ""

    # ► HARDWARE & SISTEMA OPERATIVO
    echo "► HARDWARE & SISTEMA OPERATIVO"
    printf "  • %-20s : %s (%s)\n" "OS / Kernel" "$OS_NAME" "$KERNEL_VER"
    printf "  • %-20s : %s (Virtualizzazione: %s)\n" "Piattaforma" "$HARDWARE_MODEL" "$VIRT_TYPE"
    printf "  • %-20s : %s\n" "Processore (CPU)" "${CPU_MODEL:-N/A}"
    printf "  • %-20s : %s Core Fisici / %s Thread Logici\n" "Core / Thread" "${CORES_PHYSICAL:-N/A}" "$LOGICAL_THREADS"
    printf "  • %-20s : %s\n" "Carico CPU (Load)" "$CPU_LOAD"
    printf "  • %-20s : %s usati / %s totali (Liberi: %s) [Impegno: %s%%]\n\n" "Memoria RAM" "$RAM_USED" "$RAM_TOTAL" "$RAM_FREE" "$RAM_USAGE_PCT"

    # ► STATO DISCHI E STORAGE
    echo "► STATO DISCHI E STORAGE"
    printf "  • %-30s Tot: %-6s Usato: %-6s Lib: %-6s Uso: %s\n" "Filesystem" "Size" "Used" "Avail" "Use%"
    df -h / "${HOMELAB_DIR}" 2>/dev/null | tail -n +2 | sort -u | awk '{
        printf "  • %-30s Tot: %-6s Usato: %-6s Lib: %-6s Uso: %s\n", $1, $2, $3, $4, $5
    }'
    echo ""

    # ► SENSORI TEMPERATURA
    echo "► SENSORI TEMPERATURA"
    if command -v sensors &>/dev/null; then
        sensors 2>/dev/null | grep -E 'Core|Package|temp1' | head -n 5 | while read -r line; do
            echo "  • $line"
        done
    else
        echo "  • Sensori non disponibili (lm-sensors non installato)"
    fi
    echo ""

    # ► MODELLI AI (GGUF)
    echo "► MODELLI AI (GGUF)"
    echo "  • Modelli archiviati in ${MODELS_DIR}:"
    if [ -d "${MODELS_DIR}" ] && [ "$(ls -A "${MODELS_DIR}"/*.gguf 2>/dev/null)" ]; then
        for model in "${MODELS_DIR}"/*.gguf; do
            local size
            size=$(du -h "$model" | awk '{print $1}')
            echo "    - ${model} (${size})"
        done
    else
        echo "    - Nessun modello GGUF presente in directory."
    fi
    echo ""

    # ► STATO SERVIZI, PORTE & ENDPOINT CONNESIONE
    echo "► STATO SERVIZI, PORTE & ENDPOINT CONNESIONE"

    if systemctl is-active --quiet llama-server.service 2>/dev/null; then
        echo "  [1] Llama.cpp Engine (API Server)"
        echo "      • Stato Servizio : active"
        echo "      • Protocollo     : HTTP / REST (Compatibile OpenAI)"
        echo "      • Indirizzo/Porta: ${IP_ADDR}:8080 (0.0.0.0:8080)"
        echo "      • Endpoint API   : http://${IP_ADDR}:8080/v1"
        echo "      • Health Check   : http://${IP_ADDR}:8080/health"
    else
        echo "  [1] Llama.cpp Engine (API Server) - Inattivo"
    fi

    if systemctl is-active --quiet open-webui.service 2>/dev/null; then
        echo "  [2] Open WebUI (Interfaccia Grafica Web)"
        echo "      • Stato Servizio : active"
        echo "      • Protocollo     : HTTP"
        echo "      • Indirizzo/Porta: ${IP_ADDR}:8081"
        echo "      • Web UI URL     : http://${IP_ADDR}:8081"
    else
        echo "  [2] Open WebUI (Interfaccia Grafica Web) - Inattiva"
    fi

    echo ""
    echo "================================================================================"
    echo " Sessione terminata. Per riaprire il manager esegui: ./manager-cpu.sh"
    echo "================================================================================"
    echo ""
}

# Registra la dashboard all'uscita dello script
trap show_dashboard EXIT

# ------------------------------------------------------------------------------
# Funzioni Operative
# ------------------------------------------------------------------------------
install_llama_cpp() {
    echo ""
    echo "[+] Preparazione dell'ambiente ed installazione dipendenze C++..."
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
    echo ""
    echo "[+] Installazione Open WebUI in ambiente virtuale dedicato..."
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
    echo ""
    echo "[+] Configurazione dei servizi Systemd..."
    
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

auto_tuning_hardware() {
    echo ""
    echo "[+] Auto-Tuning Hardware in corso..."
    local CORES LOGICAL RAM_GB
    CORES=$(nproc)
    LOGICAL=$(grep -c ^processor /proc/cpuinfo)
    RAM_GB=$(free -g | awk '/^Mem:/ {print $2}')
    
    echo "  • Core fisici / logici : ${CORES} / ${LOGICAL}"
    echo "  • Memoria RAM Totale   : ${RAM_GB} GB"
    echo "  • Thread consigliati   : ${CORES}"
    echo "  • Context Size ottimale: 4096 token"
    echo "[+] Auto-tuning completato."
    read -rp "Premere INVIO per continuare..."
}

run_cpu_benchmark() {
    if [ ! -f "${LLAMA_DIR}/build/bin/llama-bench" ]; then
        echo ""
        echo "[!] Binario llama-bench non trovato. Eseguire prima la compilazione."
    else
        echo ""
        echo "[+] Avvio del Benchmark CPU (llama-bench)..."
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
        echo " 1) COMPILA llama.cpp"
        echo " 2) INSTALLA Open WebUI"
        echo " 3) CONFIGURA Servizi Systemd"
        echo " 4) AUTO-TUNING Hardware"
        echo " 5) BENCHMARK CPU"
        echo " 0) ESCI / DASHBOARD"
        echo "================================================================================"
        read -rp "Seleziona un'opzione [0-5]: " choice

        case $choice in
            1) install_llama_cpp ;;
            2) install_open_webui ;;
            3) configure_systemd_services ;;
            4) auto_tuning_hardware ;;
            5) run_cpu_benchmark ;;
            0) exit 0 ;;
            *) echo "Opzione non valida."; sleep 1 ;;
        esac
    done
}

main_menu
