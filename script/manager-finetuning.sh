#!/bin/bash
# ==============================================================================
# manager-finetuning.sh - Homelab AI Deployer
# Ambiente: Baremetal/LXC, Debian 13 / Ubuntu 24
# Versione: 1.9.0 (Dashboard Moderna, API Guide, Unsloth Reintegrated & Bugfix)
# ==============================================================================
set -e

BASE_DIR="/opt/homelab-ai-deployer"
TOOLS_DIR="$BASE_DIR/tools"
DRIVERS_DIR="$BASE_DIR/drivers"
BACKEND_DIR="/opt/homelab-ai/backend"
LOG_DIR="$BASE_DIR/logs"
mkdir -p "$LOG_DIR" "$DRIVERS_DIR" "$TOOLS_DIR" "$BACKEND_DIR"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_EXT="$LOG_DIR/install_ext_$TIMESTAMP.log"
LOG_ERR="$LOG_DIR/install_err_$TIMESTAMP.log"
touch "$LOG_EXT" "$LOG_ERR"

source /etc/os-release
OS_ID=$ID
OS_VER=$VERSION_ID
VIRT_TYPE=$(systemd-detect-virt || echo "baremetal")

# ------------------------------------------------------------------------------
# FUNZIONI DI SUPPORTO & UI
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

configure_system_locale_tz() {
    echo -e "\n\033[32m[+] Configurazione automatica Timezone (Europe/Rome) e Locales UTF-8...\033[0m"
    export DEBIAN_FRONTEND=noninteractive

    ln -snf /usr/share/zoneinfo/Europe/Rome /etc/localtime
    echo "Europe/Rome" > /etc/timezone
    dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true

    apt-get update -y && apt-get install -y locales
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
    sed -i '/it_IT.UTF-8/s/^# //g' /etc/locale.gen
    locale-gen
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
}

# ------------------------------------------------------------------------------
# FASI DI INSTALLAZIONE
# ------------------------------------------------------------------------------
fase_1_dipendenze() {
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e " \033[1;37mFASE 1: Timezone, Locales, Driver NVIDIA (.run Silent) & CUDA 13.2\033[0m"
    echo -e "\033[36m======================================================================\033[0m"
    
    configure_system_locale_tz

    echo -e "\n\033[32m[+] Aggiornamento e installazione pacchetti base...\033[0m"
    apt install -y g++ freeglut3-dev build-essential libx11-dev libxmu-dev libxi-dev libglu1-mesa-dev libfreeimage-dev libglfw3-dev wget htop btop nvtop glances git pciutils cmake curl libcurl4-openssl-dev mc

    local driver_version=""
    if [ "$VIRT_TYPE" == "lxc" ]; then
        if [ -f /proc/driver/nvidia/version ]; then
            driver_version=$(cat /proc/driver/nvidia/version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
            echo -e "\033[32m[+] Rilevata versione Host Proxmox:\033[0m v$driver_version"
        fi
    fi
    
    if [ -z "$driver_version" ]; then
        driver_version="550.54.14"
        echo -e "\033[33m[!] Versione driver di fallback impostata:\033[0m v$driver_version"
    fi

    local run_name="NVIDIA-Linux-x86_64-$driver_version.run"
    local run_url="https://us.download.nvidia.com/XFree86/Linux-x86_64/$driver_version/$run_name"
    local run_path="$DRIVERS_DIR/$run_name"

    if [ ! -f "$run_path" ]; then
        echo -e "\n\033[32m[+] Download automatico driver NVIDIA v$driver_version in corso...\033[0m"
        wget -O "$run_path" "$run_url"
    else
        echo -e "\n\033[32m[+] Driver .run già presente in locale:\033[0m $run_path"
    fi

    chmod +x "$run_path"

    if [ "$VIRT_TYPE" == "lxc" ]; then
        sh "$run_path" --silent --no-kernel-modules --accept-license --no-questions || true
    else
        sh "$run_path" --silent --dkms --accept-license --no-questions || true
    fi

    local repo_distro="debian13"
    if [ "$OS_ID" == "ubuntu" ]; then
        repo_distro="ubuntu2404"
    fi

    cd /tmp
    wget -nc https://developer.download.nvidia.com/compute/cuda/repos/$repo_distro/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i cuda-keyring_1.1-1_all.deb
    apt update -y
    apt install -y cuda-toolkit-13-2

    if ! grep -q "cuda-13.2/bin" ~/.bashrc; then
        echo 'export PATH=/usr/local/cuda-13.2/bin${PATH:+:${PATH}}' >> ~/.bashrc
    fi
    
    echo "export PATH=/usr/local/cuda-13.2/bin\${PATH:+:\${PATH}}" > /etc/profile.d/cuda.sh
    chmod +x /etc/profile.d/cuda.sh

    export PATH="/usr/local/cuda-13.2/bin:/usr/local/cuda/bin:$PATH"
    export CUDACXX="/usr/local/cuda/bin/nvcc"

    echo -e "\n\033[32m[OK] Fase 1 completata con successo!\033[0m"
    read -p "Premi Invio per continuare..."
}

fase_2_ai_stack() {
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e " \033[1;37mFASE 2: Compilazione Llama.cpp (ggml-org) & Setup Modelli\033[0m"
    echo -e "\033[36m======================================================================\033[0m"

    export PATH="/usr/local/cuda-13.2/bin:/usr/local/cuda/bin:$PATH"
    export CUDACXX="/usr/local/cuda/bin/nvcc"

    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh
    mkdir -p "$BACKEND_DIR"/{unsloth,models,llama.cpp}
    
    if [ ! -d "$BACKEND_DIR/llama.cpp/.git" ]; then
        git clone https://github.com/ggml-org/llama.cpp.git "$BACKEND_DIR/llama.cpp"
    else
        cd "$BACKEND_DIR/llama.cpp" && git pull origin master || true
    fi
    
    cd "$BACKEND_DIR/llama.cpp"
    rm -rf build
    cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc
    cmake --build build --config Release -j$(nproc)

    if [ -f "$TOOLS_DIR/8gbModelCUDA.sh" ]; then
        bash "$TOOLS_DIR/8gbModelCUDA.sh"
    else
        echo -e "\n\033[33m[!] Script 8gbModelCUDA.sh non trovato in $TOOLS_DIR (saltato download automatico).\033[0m"
    fi

    cat <<EOF > /etc/systemd/system/llama-server.service
[Unit]
Description=Llama.cpp API Server (Qwen2.5-Coder)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BACKEND_DIR/llama.cpp
ExecStart=$BACKEND_DIR/llama.cpp/build/bin/llama-server -m $BACKEND_DIR/models/1_LLM_Text/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf -c 4096 --port 8080 -ngl 99
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now llama-server
    
    echo -e "\n\033[32m[OK] Llama.cpp compilato e servizio avviato sulla porta 8080!\033[0m"
    read -p "Premi Invio per continuare..."
}

fase_3_unsloth_studio() {
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e " \033[1;37mFASE 3: Setup Unsloth Environment & Fine-Tuning Studio\033[0m"
    echo -e "\033[36m======================================================================\033[0m"

    mkdir -p "$BACKEND_DIR/unsloth"
    cd "$BACKEND_DIR/unsloth"

    echo -e "\n\033[32m[+] Creazione virtual environment con UV e installazione Unsloth...\033[0m"
    uv venv --python 3.11 venv --clear
    source venv/bin/activate
    
    # Installazione pacchetti essenziali per PyTorch CUDA 12.x / 13 compatibile
    pip install --upgrade pip
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
    pip install "unsloth[colab-new] @ git+https://github.com/unslothai/unsloth.git" xformers

    cat <<EOF > /etc/systemd/system/unsloth-studio.service
[Unit]
Description=Unsloth Fine-Tuning & Training Worker
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BACKEND_DIR/unsloth
Environment="PATH=$BACKEND_DIR/unsloth/venv/bin:/usr/local/bin:/usr/bin"
ExecStart=/bin/bash -c "source venv/bin/activate && python3 -c 'import unsloth; print(\"Unsloth Studio pronto per il fine-tuning.\")' && sleep infinity"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now unsloth-studio

    echo -e "\n\033[32m[OK] Unsloth Studio integrato e configurato in /opt/homelab-ai/backend/unsloth!\033[0m"
    read -p "Premi Invio per continuare..."
}

fase_4_dashboard() {
    clear
    tput civis
    trap 'tput cnorm' EXIT

    while true; do
        printf "\033[H"

        local uptime_str=$(uptime -p)
        local load_avg=$(uptime | awk -F'load average:' '{print $2}')
        local mem_info=$(free -m | awk 'NR==2{printf "RAM: %s MB / %s MB (%.1f%%)", $3, $2, $3*100/$2}')
        local disk_info=$(df -h / | awk 'NR==2{printf "Disk /: %s / %s (%s)", $3, $2, $5}')

        local gpu_name="N/A" gpu_temp="N/A" gpu_util="N/A" gpu_mem_used="N/A" gpu_mem_total="N/A" gpu_power="N/A" gpu_fan="N/A"
        if command -v nvidia-smi &> /dev/null; then
            gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo "N/A")
            gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null || echo "0")
            gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader 2>/dev/null || echo "0")
            gpu_mem_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null || echo "0")
            gpu_mem_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null || echo "0")
            gpu_power=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader 2>/dev/null || echo "0 W")
            gpu_fan=$(nvidia-smi --query-gpu=fan.speed --format=csv,noheader 2>/dev/null || echo "0%")
        fi

        local llama_status="\033[31m[OFFLINE]\033[0m"
        if systemctl is-active --quiet llama-server; then
            llama_status="\033[32m[ATTIVO]\033[0m  ➔ API: http://127.0.0.1:8080/v1"
        fi

        local unsloth_status="\033[31m[OFFLINE]\033[0m"
        if systemctl is-active --quiet unsloth-studio; then
            unsloth_status="\033[32m[ATTIVO]\033[0m  ➔ Workspace: /opt/homelab-ai/backend/unsloth"
        fi

        echo -e "\033[1;36m╔════════════════════════════════════════════════════════════════════════════╗\033[0m"
        echo -e "\033[1;36m║\033[1;33m             HOMELAB AI - ADVANCED HARDWARE & SERVICES MONITOR              \033[1;36m║\033[0m"
        echo -e "\033[1;36m╠════════════════════════════════════════════════════════════════════════════╣\033[0m"
        echo -e "\033[1;36m║\033[0m \033[1mUptime:   \033[0m $uptime_str"
        echo -e "\033[1;36m║\033[0m \033[1mLoad Avg: \033[0m $load_avg"
        echo -e "\033[1;36m║\033[0m \033[1mSystem:   \033[0m $mem_info | $disk_info"
        echo -e "\033[1;36m╠────────────────────────────────────────────────────────────────────────────╣\033[0m"
        echo -e "\033[1;36m║\033[1;35m [ 🎮 NVIDIA GPU TELEMETRY & SENSORS ]                                      \033[1;36m║\033[0m"
        echo -e "\033[1;36m║\033[0m Model: \033[1;37m$gpu_name\033[0m"
        echo -e "\033[1;36m║\033[0m Temp:  \033[1;31m${gpu_temp}°C\033[0m  | Fan Speed: \033[36m${gpu_fan}\033[0m | Power Draw: \033[33m${gpu_power}\033[0m"
        echo -e "\033[1;36m║\033[0m Core:  \033[1;32m${gpu_util}\033[0m    | VRAM Used: \033[1;32m${gpu_mem_used} / ${gpu_mem_total}\033[0m"
        echo -e "\033[1;36m╠────────────────────────────────────────────────────────────────────────────╣\033[0m"
        echo -e "\033[1;36m║\033[1;35m [ 🤖 AI STACK SERVICES & API ENDPOINTS ]                                   \033[1;36m║\033[0m"
        echo -e "\033[1;36m║\033[0m 1. llama.cpp (Inference):  $llama_status"
        echo -e "\033[1;36m║\033[0m 2. Unsloth (Fine-Tuning): $unsloth_status"
        echo -e "\033[1;36m╠────────────────────────────────────────────────────────────────────────────╣\033[0m"
        echo -e "\033[1;36m║\033[1;33m QUICK API TEST (Curl):                                                     \033[1;36m║\033[0m"
        echo -e "\033[1;36m║\033[0m curl http://127.0.0.1:8080/v1/chat/completions -d '{\"model\":\"qwen\",\"messages\":[{\"role\":\"user\",\"content\":\"Ciao\"}]}'\033[0m"
        echo -e "\033[1;36m╠════════════════════════════════════════════════════════════════════════════╣\033[0m"
        echo -e "\033[1;36m║\033[1;33m COMMANDS: \033[0m[x] CSV Export  [b] Benchmark  [r] Refresh  [q] Exit      \033[1;36m║\033[0m"
        echo -e "\033[1;36m╚════════════════════════════════════════════════════════════════════════════╝\033[0m"
        echo -n -e "\033[1mSeleziona comando:\033[0m "

        # FIX CRITICO: Aggiunto '|| true' per evitare che il timeout di read chiuda lo script con set -e
        read -t 2 -n 1 -s key || true

        if [[ "${key,,}" == "q" ]]; then
            tput cnorm
            break
        elif [[ "${key,,}" == "x" ]]; then
            tput cnorm
            local csv_file="$HOME/ai_telemetry_$TIMESTAMP.csv"
            nvidia-smi --query-gpu=timestamp,name,temperature.gpu,utilization.gpu,memory.used,power.draw --format=csv >> "$csv_file" 2>/dev/null || echo "Errore export."
            echo -e "\n\033[32m[OK] Esportato log telemetria in $csv_file\033[0m"
            read -p "Premi un tasto per tornare alla dashboard..."
            tput civis
        elif [[ "${key,,}" == "b" ]]; then
            tput cnorm
            clear
            echo -e "\033[36m======================================================================\033[0m"
            echo -e " \033[1;37mBENCHMARK QWEN2.5-CODER IN CORSO...\033[0m"
            echo -e "\033[36m======================================================================\033[0m"
            "$BACKEND_DIR"/llama.cpp/build/bin/llama-cli -m "$BACKEND_DIR"/models/1_LLM_Text/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf -p "Scrivi una classe Python per la gestione di un inventario." -n 256 -c 512 -ngl 99
            echo -e "\n\033[32m[OK] Benchmark completato!\033[0m"
            read -n 1 -s -p "Premi un tasto per tornare alla dashboard..."
            tput civis
        fi
    done
    tput cnorm
}

purge_all() {
    clear
    echo -e "\033[31m[!] Pulizia totale in corso...\033[0m"
    systemctl disable --now llama-server unsloth-studio 2>/dev/null || true
    rm -f /etc/systemd/system/llama-server.service /etc/systemd/system/unsloth-studio.service
    systemctl daemon-reload
    rm -rf /opt/homelab-ai
    apt-get purge -y '*nvidia*' '*cuda*' '*cublas*' || true
    apt-get autoremove -y
    echo -e "\n\033[32m[OK] Sistema pulito.\033[0m"
    read -p "Premi Invio per continuare..."
}

# ------------------------------------------------------------------------------
# MENU PRINCIPALE
# ------------------------------------------------------------------------------
while true; do
    clear
    echo -e "\033[36m==================================================\033[0m"
    echo -e "\033[1;37m   HOMELAB AI DEPLOYER - FINETUNING (v1.9.0)      \033[0m"
    echo -e "\033[36m==================================================\033[0m"
    echo -e " Ambiente rilevato: \033[33m$VIRT_TYPE\033[0m"
    echo -e " Cartella Tools:    \033[33m$TOOLS_DIR\033[0m"
    echo " ------------------------------------------------"
    echo -e " \033[32mA.\033[0m Autodeploy Completo (Fasi 1-4)"
    echo " 1. Installa Dipendenze, Locales/TZ, Driver & CUDA 13.2"
    echo " 2. Compila Llama.cpp & Modelli (Porta 8080)"
    echo " 3. Setup Unsloth Studio & Fine-Tuning Environment"
    echo " 4. Dashboard Sensori, API Guide & Benchmark"
    echo " 5. Esci"
    echo " ------------------------------------------------"
    echo -e " \033[31;1mP.\033[0m PURGE Totale (AI + Driver/CUDA)"
    echo -e "\033[36m==================================================\033[0m"
    read -n 1 -s key

    case "${key,,}" in
        a)
            if confirm_action "Avvia l'installazione completa."; then
                fase_1_dipendenze && fase_2_ai_stack && fase_3_unsloth_studio && fase_4_dashboard
            fi ;;
        1) confirm_action "Avvia installazione Fase 1." && fase_1_dipendenze ;;
        2) confirm_action "Compila Llama.cpp e scarica i modelli." && fase_2_ai_stack ;;
        3) confirm_action "Configura Unsloth Studio." && fase_3_unsloth_studio ;;
        4) fase_4_dashboard ;;
        5) clear; exit 0 ;;
        p) confirm_action "Elimina l'ambiente AI e disinstalla driver/CUDA." && purge_all ;;
    esac
done
