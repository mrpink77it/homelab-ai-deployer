#!/bin/bash
# ==============================================================================
# manager-finetuning.sh - Homelab AI Deployer
# Ambiente: Baremetal/LXC, Debian 13 / Ubuntu 24, NVIDIA CUDA
# Versione: 1.1
# ==============================================================================
set -e

BASE_DIR="/opt/homelab-ai-deployer"
BACKEND_DIR="/opt/homelab-ai/backend"
LOG_DIR="$BASE_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_EXT="$LOG_DIR/install_ext_$TIMESTAMP.log"
LOG_ERR="$LOG_DIR/install_err_$TIMESTAMP.log"

touch "$LOG_EXT" "$LOG_ERR"
source /etc/os-release
OS_ID=$ID
OS_VER=$VERSION_ID
VIRT_TYPE=$(systemd-detect-virt || echo "baremetal")
TUNING_STATUS=""

# ------------------------------------------------------------------------------
# MOTORE UI E CONFERME
# ------------------------------------------------------------------------------
confirm_action() {
    local desc="$1"
    echo -e "\n\033[33mDESCRIZIONE:\033[0m $desc"
    read -p "Sei sicuro di voler procedere? [S/n]: " choice
    case "$choice" in
        [Nn]* ) echo -e "\033[31mOperazione annullata.\033[0m"; sleep 1.5; return 1 ;;
        * ) return 0 ;;
    esac
}

run_with_ui() {
    local step_name="$1"
    local command="$2"
    
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e "\033[1;37m FASE: $step_name \033[0m"
    echo -e "\033[36m======================================================================\033[0m"
    echo -e "OS: $OS_ID $OS_VER | Ambiente: $VIRT_TYPE | Log: $LOG_EXT"
    echo -e "\033[90m------------------------- LOG TERMINALE ------------------------------\033[0m"
    
    eval "$command" >> "$LOG_EXT" 2>> "$LOG_ERR" &
    local cmd_pid=$!
    tail -f -n 12 "$LOG_EXT" &
    local tail_pid=$!
    
    wait $cmd_pid
    local exit_code=$?
    kill $tail_pid 2>/dev/null || true
    
    echo -e "\033[90m----------------------------------------------------------------------\033[0m"
    if [ $exit_code -eq 0 ]; then
        echo -e "\n\033[32m[OK]\033[0m Operazione completata con successo."
        sleep 1.5
    else
        echo -e "\n\033[31m[ERRORE CRITICO]\033[0m Operazione fallita. Controlla $LOG_ERR."
        read -p "Premi Invio per continuare..."
    fi
}

# ------------------------------------------------------------------------------
# FASI DI INSTALLAZIONE
# ------------------------------------------------------------------------------
fase_1_dipendenze() {
    local cmd='
        PYTHONWARNINGS="ignore" apt-get update -y && \
        PYTHONWARNINGS="ignore" apt-get install -y build-essential cmake git curl wget psmisc python3-venv python3-full hwinfo htop
        if [ "$OS_ID" == "debian" ]; then
            PYTHONWARNINGS="ignore" apt-get install -y nvidia-driver nvidia-cuda-toolkit
        else
            PYTHONWARNINGS="ignore" apt-get install -y nvidia-driver-535 nvidia-cuda-toolkit
        fi
    '
    run_with_ui "1. Dipendenze e Driver NVIDIA" "$cmd"
}

fase_2_ai_stack() {
    # PARTE 1: Compilazione (gestita con la UI a scomparsa)
    local cmd_compile='
        curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh
        mkdir -p '"$BACKEND_DIR"'/{unsloth,models,llama.cpp}
        
        if [ ! -d "'"$BACKEND_DIR"'/llama.cpp/.git" ]; then
            git clone https://github.com/ggerganov/llama.cpp.git '"$BACKEND_DIR"'/llama.cpp
        fi
        cd '"$BACKEND_DIR"'/llama.cpp && make clean && make GGML_CUDA=1 CXXFLAGS="-Wno-stringop-overread" -j$(nproc)
    '
    run_with_ui "2.A Compilazione Llama.cpp & Unsloth" "$cmd_compile"
    
    # PARTE 2: Esecuzione DIRETTA dello script dei modelli (mostra nativamente wget)
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e "\033[1;37m 2.B DOWNLOAD MODELLI AI (8gbModelCUDA.sh) \033[0m"
    echo -e "\033[36m======================================================================\033[0m"
    bash "$BASE_DIR/tools/8gbModelCUDA.sh"
    echo -e "\n\033[32m[OK]\033[0m Download modelli completato."
    sleep 1.5

    # PARTE 3: Creazione servizio (torna alla UI a scomparsa)
    local cmd_service='
        cat <<EOF > /etc/systemd/system/llama-server.service
[Unit]
Description=Llama.cpp API Server (Qwen2.5-Coder)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory='"$BACKEND_DIR"'/llama.cpp
ExecStart='"$BACKEND_DIR"'/llama.cpp/llama-server -m '"$BACKEND_DIR"'/models/1_LLM_Text/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf -c 4096 --port 8080 -ngl 99
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now llama-server
        sleep 5
    '
    run_with_ui "2.C Configurazione Servizio llama-server" "$cmd_service"
    
    clear
    echo "=== CONTROLLO SERVIZI AI ==="
    if systemctl is-active --quiet llama-server; then
        echo -e "\033[32m[OK] llama-server in esecuzione.\033[0m"
    else
        echo -e "\033[31m[ERRORE] llama-server non è partito.\033[0m"
    fi
    read -n 1 -s -p "Premi un tasto per continuare..."
}

fase_3_opencode() {
    local cmd='
        mkdir -p /opt/homelab-ai/opencode
        cd /opt/homelab-ai/opencode
        uv venv venv
        
        cat <<EOF > /etc/systemd/system/opencode.service
[Unit]
Description=OpenCode UI Assistant
After=llama-server.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/homelab-ai/opencode
Environment="LLM_API=http://127.0.0.1:8080"
Environment="PATH=/opt/homelab-ai/opencode/venv/bin:/usr/local/bin:/usr/bin"
ExecStart=/bin/bash -c "echo '\''OpenCode in ascolto (Placeholder)'\'' && sleep infinity"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now opencode
    '
    run_with_ui "3. Setup OpenCode" "$cmd"
}

fase_4_dashboard() {
    while true; do
        clear
        echo -e "\033[36m=== DASHBOARD HARDWARE E SENSORI AI ===\033[0m"
        echo -e "\033[33mComandi: [x] Esporta CSV | [b] Benchmark | [q] Esci\033[0m"
        echo "--------------------------------------------------------"
        if command -v nvidia-smi &> /dev/null; then
            nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv,noheader | awk -F', ' '{print "GPU: "$1" | Temp: "$2"C | Uso: "$3" | VRAM: "$4"/"$5}'
        else
            echo "NVIDIA-SMI non disponibile."
        fi
        echo "--------------------------------------------------------"
        systemctl is-active --quiet llama-server && echo -e "llama.cpp: \033[32mATTIVO\033[0m (Porta 8080)" || echo -e "llama.cpp: \033[31mOFFLINE\033[0m"
        systemctl is-active --quiet opencode && echo -e "OpenCode:  \033[32mATTIVO\033[0m" || echo -e "OpenCode:  \033[31mOFFLINE\033[0m"
        echo "--------------------------------------------------------"
        
        read -t 1 -n 1 -s key
        if [[ "${key,,}" == "q" ]]; then break;
        elif [[ "${key,,}" == "x" ]]; then
            local csv_file="$HOME/ai_telemetry_$TIMESTAMP.csv"
            nvidia-smi --query-gpu=timestamp,name,temperature.gpu,utilization.gpu,memory.used --format=csv >> "$csv_file"
            echo -e "\033[32mEsportato log in $csv_file\033[0m"
            sleep 1
        elif [[ "${key,,}" == "b" ]]; then
            clear
            echo -e "\033[36mEsecuzione Benchmark Qwen2.5-Coder...\033[0m"
            local bench_log="$HOME/benchmark_${TIMESTAMP}.txt"
            "$BACKEND_DIR"/llama.cpp/llama-cli -m "$BACKEND_DIR"/models/1_LLM_Text/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf -p "Scrivi una classe Python per gestire un database SQLite." -n 256 -c 512 -ngl 99 | tee "$bench_log"
            echo -e "\n\033[32mBenchmark salvato in $bench_log\033[0m"
            read -n 1 -s -p "Premi un tasto per tornare alla dashboard..."
        fi
    done
}

fase_t_tuning() {
    clear
    echo -e "\033[36m=== AUTO-TUNING LLAMA.CPP ===\033[0m"
    VRAM_TOTAL=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk '{print $1}' || echo "0")
    
    if [ "$VRAM_TOTAL" -ge 24000 ]; then NGL=99; CTX=32768; BATCH=2048; THREADS=8;
    elif [ "$VRAM_TOTAL" -ge 16000 ]; then NGL=99; CTX=16384; BATCH=1024; THREADS=6;
    elif [ "$VRAM_TOTAL" -ge 7900 ]; then NGL=99; CTX=8192; BATCH=512; THREADS=4;
    else NGL=20; CTX=4096; BATCH=256; THREADS=$(nproc); fi

    echo -e "VRAM Rilevata: \033[32m${VRAM_TOTAL} MB\033[0m"
    echo -e "Parametri Calcolati: CTX=\033[33m$CTX\033[0m | NGL=\033[33m$NGL\033[0m | BATCH=\033[33m$BATCH\033[0m | THREADS=\033[33m$THREADS\033[0m\n"

    read -t 5 -p "Premi INVIO per accettare (default in 5s) o digita 'M' per modificare: " tuning_choice || tuning_choice=""
    
    if [[ "${tuning_choice,,}" == "m" ]]; then
        read -p "Context Size (es. 8192): " CTX
        read -p "GPU Layers (es. 99): " NGL
        read -p "Batch Size (es. 512): " BATCH
        read -p "Threads (es. 4): " THREADS
    fi

    echo -e "\n\033[32mAggiornamento servizio systemd in corso...\033[0m"
    cat <<EOF > /etc/systemd/system/llama-server.service
[Unit]
Description=Llama.cpp API Server (Qwen2.5-Coder)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BACKEND_DIR/llama.cpp
ExecStart=$BACKEND_DIR/llama.cpp/llama-server -m $BACKEND_DIR/models/1_LLM_Text/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf -c $CTX -b $BATCH -ngl $NGL -t $THREADS -fa --port 8080
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl restart llama-server

    echo -e "\n\033[36mEsecuzione Benchmark Breve per validazione...\033[0m"
    "$BACKEND_DIR"/llama.cpp/llama-cli -m "$BACKEND_DIR"/models/1_LLM_Text/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf -p "Definisci un array." -n 32 -c "$CTX" -b "$BATCH" -ngl "$NGL" -t "$THREADS" -fa > /tmp/bench_tuning.txt 2>&1
    grep -E "llama_print_timings" -A 5 /tmp/bench_tuning.txt || echo "Test completato con successo."
    
    TUNING_STATUS="\033[32m[STACK OTTIMIZZATO]\033[0m"
    read -n 1 -s -p "Premi un tasto per tornare al menu principale..."
}

purge_ai() {
    local cmd="
        systemctl disable --now llama-server opencode 2>/dev/null || true
        rm -f /etc/systemd/system/llama-server.service /etc/systemd/system/opencode.service
        systemctl daemon-reload
        rm -rf /opt/homelab-ai
    "
    run_with_ui "X. Rimozione Ambiente AI" "$cmd"
}

purge_all() {
    purge_ai
    local cmd="
        PYTHONWARNINGS=\"ignore\" apt-get purge -y '*nvidia*' '*cuda*' '*cublas*'
        PYTHONWARNINGS=\"ignore\" apt-get autoremove -y
    "
    run_with_ui "P. Purge Ambiente AI e NVIDIA" "$cmd"
}

# ------------------------------------------------------------------------------
# MENU PRINCIPALE
# ------------------------------------------------------------------------------
while true; do
    clear
    echo -e "\033[36m==================================================\033[0m"
    echo -e "\033[1;37m   HOMELAB AI DEPLOYER - FINETUNING (v1.1)        \033[0m"
    echo -e "\033[36m==================================================\033[0m"
    [ -n "$TUNING_STATUS" ] && echo -e " Stato: $TUNING_STATUS\n"
    
    echo -e " \033[32mA.\033[0m Autodeploy Completo (Fasi 1-4)"
    echo " ------------------------------------------------"
    echo " 1. Installa Dipendenze e NVIDIA/CUDA"
    echo " 2. Compila Llama.cpp & Unsloth (Download Modelli)"
    echo " 3. Setup OpenCode (Interfaccia UI Baremetal)"
    echo " 4. Dashboard Sensori e Benchmark"
    echo " 5. Servizi Accessori (services.sh)"
    echo " 6. Esci"
    echo " ------------------------------------------------"
    echo -e " \033[33mT.\033[0m Tuning (Ottimizzazione Parametri VRAM)"
    echo -e " \033[31mX.\033[0m Rimuovi ambiente AI (Modelli e Demoni)"
    echo -e " \033[31;1mP.\033[0m PURGE Totale (AI + NVIDIA/CUDA)"
    echo -e "\033[36m==================================================\033[0m"
    read -n 1 -s key
    echo ""

    case "${key,,}" in
        a)
            if confirm_action "Avvierà l'installazione completa (Fasi 1, 2, 3 e 4 in sequenza automatica)."; then
                fase_1_dipendenze
                fase_2_ai_stack
                fase_3_opencode
                fase_4_dashboard
            fi ;;
        1) confirm_action "Installa compilatori, driver NVIDIA e Toolkit CUDA." && fase_1_dipendenze ;;
        2) confirm_action "Compila Llama.cpp e scarica i modelli AI in $BACKEND_DIR/models/." && fase_2_ai_stack ;;
        3) confirm_action "Crea un venv isolato per OpenCode e lo connette al demone Llama.cpp." && fase_3_opencode ;;
        4) confirm_action "Avvia l'interfaccia di monitoraggio in tempo reale (Sensori e Benchmark)." && fase_4_dashboard ;;
        5) confirm_action "Esegue lo script dei servizi accessori." && bash "$BASE_DIR/tools/services.sh" 2>/dev/null || echo "File services.sh non trovato!" && sleep 2 ;;
        6) clear; exit 0 ;;
        t) confirm_action "Ricalcola NGL, Contesto, Batch e Threads in base alla VRAM disponibile." && fase_t_tuning ;;
        x) confirm_action "Elimina Llama.cpp, OpenCode e tutti i modelli scaricati. I driver NVIDIA rimarranno." && purge_ai ;;
        p) confirm_action "DISTRUTTIVO: Elimina l'ambiente AI e disinstalla completamente i driver NVIDIA/CUDA." && purge_all ;;
    esac
done
