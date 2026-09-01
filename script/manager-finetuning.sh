#!/bin/bash
# ==============================================================================
# manager-finetuning.sh - Homelab AI Deployer
# Ambiente: Baremetal/LXC, Debian 13 / Ubuntu 24
# Versione: 1.6 (Driver .run Ufficiale + CUDA Toolkit 13.2 Repo Ufficiale)
# ==============================================================================
set -e

BASE_DIR="/opt/homelab-ai-deployer"
DRIVERS_DIR="$BASE_DIR/drivers"
BACKEND_DIR="/opt/homelab-ai/backend"
LOG_DIR="$BASE_DIR/logs"
mkdir -p "$LOG_DIR" "$DRIVERS_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_EXT="$LOG_DIR/install_ext_$TIMESTAMP.log"
LOG_ERR="$LOG_DIR/install_err_$TIMESTAMP.log"

touch "$LOG_EXT" "$LOG_ERR"
source /etc/os-release
OS_ID=$ID
OS_VER=$VERSION_ID
VIRT_TYPE=$(systemd-detect-virt || echo "baremetal")

# ------------------------------------------------------------------------------
# MOTORE UI PSEUDO-GRAFICO (Barra % + Mini Terminale)
# ------------------------------------------------------------------------------
confirm_action() {
    local desc="$1"
    echo -e "\n\033[33mDESCRIZIONE:\033[0m $desc"
    read -p "Sei sicuro di voler procedere? [S/n]: " choice
    case "$choice" in
        [Nn]* ) echo -e "\033[31mOperazione annullata.\033[0m"; sleep 1; return 1 ;;
        * ) return 0 ;;
    esac
}

ui_execute() {
    local step_name="$1"
    local desc="$2"
    local cmd="$3"
    local est_time="${4:-45}" 

    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e " \033[1;37mFASE:\033[0m $step_name "
    echo -e "\033[36m======================================================================\033[0m"
    echo -e " \033[33mDESCRIZIONE:\033[0m $desc"
    echo -e "\033[36m======================================================================\033[0m"
    
    echo -e " AVANZAMENTO: [\033[32m░░░░░░░░░░░░░░░░░░░░\033[0m] 0% "
    echo -e "\033[90m--------------------------- MINI TERMINALE ---------------------------\033[0m"
    for i in {1..8}; do echo -e " \033[K"; done
    echo -e "\033[90m----------------------------------------------------------------------\033[0m"

    eval "$cmd" >> "$LOG_EXT" 2>> "$LOG_ERR" &
    local pid=$!
    local elapsed=0

    while kill -0 $pid 2>/dev/null; do
        local pct=$(( elapsed * 100 / est_time ))
        [ $pct -gt 99 ] && pct=99
        local filled=$(( pct / 5 ))
        local empty=$(( 20 - filled ))
        local bar=$(printf "%${filled}s" | tr ' ' '█')$(printf "%${empty}s" | tr ' ' '░')
        
        echo -en "\033[11A\r"
        echo -e " AVANZAMENTO: [\033[32m${bar}\033[0m] $pct% (${elapsed}s) \033[K"
        echo -e "\033[90m--------------------------- MINI TERMINALE ---------------------------\033[0m"
        
        local current_lines=0
        while IFS= read -r line; do
            printf "  %-66s\033[K\n" "${line:0:66}"
            ((current_lines++))
        done < <(tail -n 8 "$LOG_EXT")
        
        for ((i=current_lines; i<8; i++)); do echo -e " \033[K"; done
        
        echo -en "\033[1B\r"
        sleep 1
        elapsed=$((elapsed + 1))
    done

    wait $pid
    local exit_code=$?

    echo -en "\033[11A\r"
    if [ $exit_code -eq 0 ]; then
        echo -e " AVANZAMENTO: [\033[32m████████████████████\033[0m] 100% \033[32m[OK]\033[0m \033[K"
    else
        echo -e " AVANZAMENTO: [\033[31m████████████████████\033[0m] 100% \033[31m[ERRORE]\033[0m \033[K"
    fi
    echo -e "\033[90m--------------------------- MINI TERMINALE ---------------------------\033[0m"
    local current_lines=0
    while IFS= read -r line; do
        printf "  %-66s\033[K\n" "${line:0:66}"
        ((current_lines++))
    done < <(tail -n 8 "$LOG_EXT")
    for ((i=current_lines; i<8; i++)); do echo -e " \033[K"; done
    echo -e "\033[90m----------------------------------------------------------------------\033[0m"

    if [ $exit_code -ne 0 ]; then
        echo -e "\n\033[31m[ERRORE CRITICO]\033[0m Operazione fallita. Controlla $LOG_ERR."
        read -p "Premi Invio per tornare al menu..."
    else
        sleep 1.5
    fi
}

# ------------------------------------------------------------------------------
# FASI DI INSTALLAZIONE
# ------------------------------------------------------------------------------
fase_1_dipendenze() {
    # 1. Controllo presenza file .run del driver
    local run_file=$(find "$DRIVERS_DIR" -maxdepth 1 -name "NVIDIA-Linux-x86_64-*.run" | head -n 1)
    if [ -z "$run_file" ]; then
        echo -e "\n\033[31m[ATTENZIONE]\033[0m Nessun file driver .run trovato in $DRIVERS_DIR!"
        echo -e "Copia il file NVIDIA-Linux-x86_64-*.run nella cartella \033[33m$DRIVERS_DIR\033[0m prima di procedere."
        read -p "Premi Invio per tornare al menu..."
        return 1
    }

    # 2. Definizione comando driver in base a LXC o Baremetal
    local driver_install_cmd=""
    if [ "$VIRT_TYPE" == "lxc" ]; then
        driver_install_cmd="sh \"$run_file\" --no-kernel-modules --accept-license --no-questions"
    else
        driver_install_cmd="sh \"$run_file\" --dkms --accept-license --no-questions"
    fi

    # 3. Determinazione repository CUDA in base alla distro (Debian 13 o Ubuntu 24)
    local repo_distro="debian13"
    if [ "$OS_ID" == "ubuntu" ]; then
        repo_distro="ubuntu2404"
    fi

    # 4. Comando cumulativo Fase 1
    local cmd_all='
        export DEBIAN_FRONTEND=noninteractive
        apt update -y
        apt install -y g++ freeglut3-dev build-essential libx11-dev libxmu-dev libxi-dev libglu1-mesa-dev libfreeimage-dev libglfw3-dev wget htop btop nvtop glances git pciutils cmake curl libcurl4-openssl-dev mc
        
        # Esecuzione installer driver .run
        '"$driver_install_cmd"'
        
        # Installazione CUDA Toolkit 13.2 da repo ufficiale NVIDIA
        cd /tmp
        wget -nc https://developer.download.nvidia.com/compute/cuda/repos/'"$repo_distro"'/x86_64/cuda-keyring_1.1-1_all.deb
        dpkg -i cuda-keyring_1.1-1_all.deb
        apt update -y
        apt install -y cuda-toolkit-13-2
        
        # Configurazione .bashrc e profile globale
        if ! grep -q "cuda-13.2/bin" ~/.bashrc; then
            cp ~/.bashrc ~/.bashrc-backup
            echo '\''export PATH=/usr/local/cuda-13.2/bin${PATH:+:${PATH}}'\'' >> ~/.bashrc
        fi
        
        cat <<EOF > /etc/profile.d/cuda.sh
export PATH=/usr/local/cuda-13.2/bin\${PATH:+:\${PATH}}
EOF
        chmod +x /etc/profile.d/cuda.sh
    '
    
    ui_execute "1. Dipendenze, Driver .run ($VIRT_TYPE) & CUDA 13.2" "Installazione pacchetti, driver NVIDIA personalizzato e CUDA Toolkit 13.2" "$cmd_all" 120
}

fase_2_ai_stack() {
    local cmd_compile='
        curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh
        mkdir -p '"$BACKEND_DIR"'/{unsloth,models,llama.cpp}
        
        if [ ! -d "'"$BACKEND_DIR"'/llama.cpp/.git" ]; then
            git clone https://github.com/ggerganov/llama.cpp.git '"$BACKEND_DIR"'/llama.cpp
        fi
        cd '"$BACKEND_DIR"'/llama.cpp
        rm -rf build
        cmake -B build -DGGML_CUDA=ON
        cmake --build build --config Release -j$(nproc)
    '
    ui_execute "2.A Compilazione Llama.cpp" "Fetch repo ufficiale e build CMake con accelerazione CUDA" "$cmd_compile" 180
    
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e "\033[1;37m 2.B DOWNLOAD MODELLI AI (8gbModelCUDA.sh) \033[0m"
    echo -e "\033[36m======================================================================\033[0m"
    if [ -f "$BASE_DIR/tools/8gbModelCUDA.sh" ]; then
        bash "$BASE_DIR/tools/8gbModelCUDA.sh"
    else
        echo "Script 8gbModelCUDA.sh non trovato in $BASE_DIR/tools/ (saltato)."
    fi
    echo -e "\n\033[32m[OK]\033[0m Download modelli completato."
    sleep 1.5

    local cmd_service='
        cat <<EOF > /etc/systemd/system/llama-server.service
[Unit]
Description=Llama.cpp API Server (Qwen2.5-Coder)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory='"$BACKEND_DIR"'/llama.cpp
ExecStart='"$BACKEND_DIR"'/llama.cpp/build/bin/llama-server -m '"$BACKEND_DIR"'/models/1_LLM_Text/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf -c 4096 --port 8080 -ngl 99
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now llama-server
        sleep 3
    '
    ui_execute "2.C Configurazione Servizio" "Creazione demone systemd per llama-server" "$cmd_service" 10
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
    ui_execute "3. Setup OpenCode" "Creazione virtual environment e demone per l'UI" "$cmd" 15
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
            echo "NVIDIA-SMI non disponibile o errore librerie."
        fi
        echo "--------------------------------------------------------"
        systemctl is-active --quiet llama-server && echo -e "llama.cpp: \033[32mATTIVO\033[0m (Porta 8080)" || echo -e "llama.cpp: \033[31mOFFLINE\033[0m"
        systemctl is-active --quiet opencode && echo -e "OpenCode:  \033[32mATTIVO\033[0m" || echo -e "OpenCode:  \033[31mOFFLINE\033[0m"
        echo "--------------------------------------------------------"
        
        read -t 1 -n 1 -s key
        if [[ "${key,,}" == "q" ]]; then break;
        elif [[ "${key,,}" == "x" ]]; then
            local csv_file="$HOME/ai_telemetry_$TIMESTAMP.csv"
            nvidia-smi --query-gpu=timestamp,name,temperature.gpu,utilization.gpu,memory.used --format=csv >> "$csv_file" 2>/dev/null || echo "Errore export."
            echo -e "\033[32mEsportato log in $csv_file\033[0m"
            sleep 1
        elif [[ "${key,,}" == "b" ]]; then
            clear
            echo -e "\033[36mEsecuzione Benchmark Qwen2.5-Coder...\033[0m"
            "$BACKEND_DIR"/llama.cpp/build/bin/llama-cli -m "$BACKEND_DIR"/models/1_LLM_Text/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf -p "Scrivi una classe Python." -n 256 -c 512 -ngl 99
            read -n 1 -s -p "Premi un tasto per tornare alla dashboard..."
        fi
    done
}

purge_all() {
    local cmd="
        systemctl disable --now llama-server opencode unsloth 2>/dev/null || true
        rm -f /etc/systemd/system/llama-server.service /etc/systemd/system/opencode.service
        systemctl daemon-reload
        rm -rf /opt/homelab-ai
        apt-get purge -y '*nvidia*' '*cuda*' '*cublas*' || true
        apt-get autoremove -y
    "
    ui_execute "P. PURGE AMBIENTE" "Eliminazione stack AI e disinstallazione driver/librerie NVIDIA" "$cmd" 45
}

# ------------------------------------------------------------------------------
# MENU PRINCIPALE
# ------------------------------------------------------------------------------
while true; do
    clear
    echo -e "\033[36m==================================================\033[0m"
    echo -e "\033[1;37m   HOMELAB AI DEPLOYER - FINETUNING (v1.6)        \033[0m"
    echo -e "\033[36m==================================================\033[0m"
    echo -e " Ambiente rilevato: \033[33m$VIRT_TYPE\033[0m"
    echo -e " Cartella Driver:   \033[33m$DRIVERS_DIR\033[0m"
    echo " ------------------------------------------------"
    echo -e " \033[32mA.\033[0m Autodeploy Completo (Fasi 1-4)"
    echo " 1. Installa Dipendenze, Driver .run & CUDA 13.2"
    echo " 2. Compila Llama.cpp & Modelli"
    echo " 3. Setup OpenCode"
    echo " 4. Dashboard Sensori e Benchmark"
    echo " 5. Esci"
    echo " ------------------------------------------------"
    echo -e " \033[31;1mP.\033[0m PURGE Totale (AI + Driver/CUDA)"
    echo -e "\033[36m==================================================\033[0m"
    read -n 1 -s key

    case "${key,,}" in
        a)
            if confirm_action "Avvia l'installazione completa."; then
                fase_1_dipendenze && fase_2_ai_stack && fase_3_opencode && fase_4_dashboard
            fi ;;
        1) confirm_action "Installa dipendenze, driver .run ($VIRT_TYPE) e CUDA 13.2." && fase_1_dipendenze ;;
        2) confirm_action "Compila Llama.cpp e scarica i modelli." && fase_2_ai_stack ;;
        3) confirm_action "Crea l'ambiente per OpenCode." && fase_3_opencode ;;
        4) fase_4_dashboard ;;
        5) clear; exit 0 ;;
        p) confirm_action "Elimina l'ambiente AI e disinstalla driver/CUDA." && purge_all ;;
    esac
done
