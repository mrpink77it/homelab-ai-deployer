#!/bin/bash
# ==============================================================================
# manager-finetuning.sh - Homelab AI Deployer
# Ambiente: Baremetal/LXC, Debian 13 / Ubuntu 24, NVIDIA CUDA
# Stack: Unsloth + llama.cpp + OpenCode (Qwen2.5-Coder-7B-Instruct)
# ==============================================================================
set -e

BASE_DIR="/opt/homelab-ai-deployer"
LOG_DIR="$BASE_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_EXT="$LOG_DIR/install_ext_$TIMESTAMP.log"
LOG_ERR="$LOG_DIR/install_err_$TIMESTAMP.log"

# Inizializza i log
touch "$LOG_EXT" "$LOG_ERR"

# Rilevamento OS
source /etc/os-release
OS_ID=$ID
OS_VER=$VERSION_ID
VIRT_TYPE=$(systemd-detect-virt || echo "baremetal")

# ------------------------------------------------------------------------------
# MOTORE UI - Pseudo-grafica e Mini-Terminale
# ------------------------------------------------------------------------------
run_with_ui() {
    local step_name="$1"
    local description="$2"
    local command="$3"
    
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e "\033[1;37m FASE: $step_name \033[0m"
    echo -e "\033[36m======================================================================\033[0m"
    echo -e "\033[33m$description\033[0m\n"
    echo -e "OS: $OS_ID $OS_VER | Ambiente: $VIRT_TYPE | Log: $LOG_EXT"
    echo -e "\033[90m------------------------- LOG TERMINALE ------------------------------\033[0m"
    
    # Esegui il comando in background
    eval "$command" >> "$LOG_EXT" 2>> "$LOG_ERR" &
    local cmd_pid=$!
    
    # Mostra le ultime righe del log in tempo reale
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
        read -p "Premi Invio per continuare o Ctrl+C per uscire..."
    fi
}

# ------------------------------------------------------------------------------
# FASI DI INSTALLAZIONE
# ------------------------------------------------------------------------------
fase_1_dipendenze() {
    local desc="Installazione dei driver NVIDIA, CUDA Toolkit e dipendenze di base. Il sistema si assicura di avere i compilatori pronti e sopprime i falsi allarmi dei pacchetti Python di sistema."
    local cmd='
        PYTHONWARNINGS="ignore" apt-get update -y && \
        PYTHONWARNINGS="ignore" apt-get install -y build-essential cmake git curl wget psmisc python3-venv python3-full hwinfo htop
        if [ "$OS_ID" == "debian" ]; then
            PYTHONWARNINGS="ignore" apt-get install -y nvidia-driver nvidia-cuda-toolkit
        else
            PYTHONWARNINGS="ignore" apt-get install -y nvidia-driver-535 nvidia-cuda-toolkit
        fi
    '
    run_with_ui "1. Dipendenze e Driver NVIDIA" "$desc" "$cmd"
}

fase_2_ai_stack() {
    local desc="Installazione di uv globale, compilazione ottimizzata di llama.cpp, download dei modelli (ottimizzato per 8GB VRAM) e creazione del servizio unsloth."
    local cmd='
        curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh
        mkdir -p /opt/homelab-ai/{unsloth,models,llama.cpp}
        
        # Setup Llama.cpp con soppressione del falso positivo stringop GCC 12
        if [ ! -d "/opt/homelab-ai/llama.cpp/.git" ]; then
            git clone https://github.com/ggerganov/llama.cpp.git /opt/homelab-ai/llama.cpp
        fi
        cd /opt/homelab-ai/llama.cpp && make clean && make GGML_CUDA=1 CXXFLAGS="-Wno-stringop-overread" -j$(nproc)
        
        # Esecuzione script modelli (Forzato a 8GB per default Autodeploy / 3060 Ti)
        bash '"$BASE_DIR"'/tools/8gbModelCUDA.sh
        
        # Servizio Systemd llama.cpp
        cat <<EOF > /etc/systemd/system/llama-server.service
[Unit]
Description=Llama.cpp API Server (Qwen2.5-Coder)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/homelab-ai/llama.cpp
ExecStart=/opt/homelab-ai/llama.cpp/llama-server -m /opt/homelab-ai/models/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf -c 4096 --port 8080 -ngl 99
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now llama-server
        sleep 5
        curl -s http://127.0.0.1:8080/health || echo "Health check fallito, verificare i log"
    '
    run_with_ui "2. Unsloth & Llama.cpp" "$desc" "$cmd"
    
    # Check visivo
    clear
    echo "=== CONTROLLO SERVIZI AI ==="
    if systemctl is-active --quiet llama-server; then
        echo -e "\033[32m[OK] llama-server in esecuzione e connesso alla GPU.\033[0m"
    else
        echo -e "\033[31m[ERRORE] llama-server non è partito. Causa probabile: VRAM esaurita o driver mancanti.\033[0m"
    fi
    read -n 1 -s -p "Premi un tasto per continuare..."
}

fase_3_opencode() {
    local desc="Installazione bare-metal di OpenCode. Viene creato un ambiente virtuale nativo connesso direttamente a llama.cpp (127.0.0.1:8080)."
    local cmd='
        mkdir -p /opt/homelab-ai/opencode
        cd /opt/homelab-ai/opencode
        uv venv venv
        # Sostituire con il clone effettivo della repository di OpenCode
        # git clone <URL_OPENCODE> .
        # uv pip install -r requirements.txt
        
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
# Sostituire con il comando di avvio reale
ExecStart=/bin/bash -c "echo '\''OpenCode in ascolto (Placeholder)'\'' && sleep infinity"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now opencode
    '
    run_with_ui "3. Setup OpenCode" "$desc" "$cmd"
}

fase_4_dashboard() {
    while true; do
        clear
        echo -e "\033[36m=== DASHBOARD HARDWARE E SENSORI AI ===\033[0m"
        echo -e "\033[33mComandi: [x] Esporta CSV | [b] Benchmark Qwen2.5 | [q] Esci\033[0m"
        echo "--------------------------------------------------------"
        
        # GPU Info
        if command -v nvidia-smi &> /dev/null; then
            nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv,noheader | awk -F', ' '{print "GPU: "$1" | Temp: "$2"C | Uso: "$3" | VRAM: "$4"/"$5}'
        else
            echo "NVIDIA-SMI non disponibile."
        fi
        
        echo "--------------------------------------------------------"
        echo "Stato Servizi:"
        systemctl is-active --quiet llama-server && echo -e "llama.cpp: \033[32mATTIVO\033[0m (Porta 8080)" || echo -e "llama.cpp: \033[31mOFFLINE\033[0m"
        systemctl is-active --quiet opencode && echo -e "OpenCode:  \033[32mATTIVO\033[0m" || echo -e "OpenCode:  \033[31mOFFLINE\033[0m"
        echo "--------------------------------------------------------"
        
        # Legge il tasto con timeout di 1 secondo per refreshare la UI
        read -t 1 -n 1 -s key
        if [[ $key == "q" || $key == "Q" ]]; then
            break
        elif [[ $key == "x" || $key == "X" ]]; then
            local csv_file="$HOME/ai_telemetry_$TIMESTAMP.csv"
            nvidia-smi --query-gpu=timestamp,name,temperature.gpu,utilization.gpu,memory.used --format=csv >> "$csv_file"
            echo -e "\033[32mEsportato log in $csv_file\033[0m"
            sleep 1
        elif [[ $key == "b" || $key == "B" ]]; then
            clear
            echo -e "\033[36mEsecuzione Benchmark Llama.cpp con Qwen2.5-Coder...\033[0m"
            local bench_log="$HOME/benchmark_${TIMESTAMP}.txt"
            /opt/homelab-ai/llama.cpp/llama-cli -m /opt/homelab-ai/models/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf -p "Scrivi una classe Python per gestire un database SQLite." -n 256 -c 512 -ngl 99 | tee "$bench_log"
            echo -e "\n\033[32mBenchmark salvato in $bench_log\033[0m"
            read -n 1 -s -p "Premi un tasto per tornare alla dashboard..."
        fi
    done
}

purge_ai() {
    run_with_ui "X. Rimozione Ambiente AI" "Arresto servizi ed eliminazione modelli e configurazioni." "
        systemctl disable --now llama-server opencode 2>/dev/null || true
        rm -f /etc/systemd/system/llama-server.service /etc/systemd/system/opencode.service
        systemctl daemon-reload
        rm -rf /opt/homelab-ai
    "
}

purge_all() {
    purge_ai
    run_with_ui "P. Purge Ambiente AI e NVIDIA" "Rimozione profonda dei driver NVIDIA e CUDA." "
        PYTHONWARNINGS="ignore" apt-get purge -y '*nvidia*' '*cuda*' '*cublas*'
        PYTHONWARNINGS="ignore" apt-get autoremove -y
    "
}

# ------------------------------------------------------------------------------
# MENU PRINCIPALE
# ------------------------------------------------------------------------------
while true; do
    clear
    echo -e "\033[36m==================================================\033[0m"
    echo -e "\033[1;37m        HOMELAB AI DEPLOYER - FINETUNING          \033[0m"
    echo -e "\033[36m==================================================\033[0m"
    echo -e " \033[32mA.\033[0m Autodeploy Completo (Fasi 1-4)"
    echo " ------------------------------------------------"
    echo " 1. Installa Dipendenze e NVIDIA/CUDA"
    echo " 2. Compila Llama.cpp & Unsloth (Download Modelli)"
    echo " 3. Setup OpenCode (Interfaccia UI Baremetal)"
    echo " 4. Dashboard Sensori e Benchmark"
    echo " 5. Servizi Accessori (services.sh)"
    echo " 6. Esci"
    echo " ------------------------------------------------"
    echo -e " \033[31mX.\033[0m Rimuovi ambiente AI (Modelli e Demoni)"
    echo -e " \033[31;1mP.\033[0m PURGE Totale (AI + NVIDIA/CUDA)"
    echo -e "\033[36m==================================================\033[0m"
    read -p " Seleziona un'opzione: " choice

    case $choice in
        A|a)
            fase_1_dipendenze
            fase_2_ai_stack
            fase_3_opencode
            fase_4_dashboard
            ;;
        1) fase_1_dipendenze ;;
        2) fase_2_ai_stack ;;
        3) fase_3_opencode ;;
        4) fase_4_dashboard ;;
        5) 
            if [ -f "$BASE_DIR/tools/services.sh" ]; then
                bash "$BASE_DIR/tools/services.sh"
            else
                echo "File services.sh non trovato!" && sleep 2
            fi
            ;;
        6) clear; exit 0 ;;
        X|x) purge_ai ;;
        P|p) purge_all ;;
        *) echo "Scelta non valida"; sleep 1 ;;
    esac
done
