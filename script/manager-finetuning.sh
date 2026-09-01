#!/bin/bash
# ==============================================================================
# manager-finetuning.sh - Homelab AI Deployer
# Ambiente: Baremetal/LXC, Debian 13 / Ubuntu 24
# Versione: 1.8 (Auto-Download Driver .run Ufficiale + CUDA 13.2)
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

# ------------------------------------------------------------------------------
# FASI DI INSTALLAZIONE (Esecuzione pulita e lineare)
# ------------------------------------------------------------------------------
fase_1_dipendenze() {
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e " \033[1;37mFASE 1: Dipendenze, Driver NVIDIA (.run) & CUDA 13.2\033[0m"
    echo -e "\033[36m======================================================================\033[0m"
    
    # 1. Installazione pacchetti di sistema e monitoraggio
    echo -e "\n\033[32m[+] Aggiornamento e installazione pacchetti base...\033[0m"
    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    apt install -y g++ freeglut3-dev build-essential libx11-dev libxmu-dev libxi-dev libglu1-mesa-dev libfreeimage-dev libglfw3-dev wget htop btop nvtop glances git pciutils cmake curl libcurl4-openssl-dev mc

    # 2. Rilevamento versione driver e download automatico da NVIDIA
    local driver_version=""
    if [ "$VIRT_TYPE" == "lxc" ]; then
        if [ -f /proc/driver/nvidia/version ]; then
            driver_version=$(cat /proc/driver/nvidia/version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
            echo -e "\033[32m[+] Rilevata versione Host Proxmox:\033[0m v$driver_version"
        fi
    fi
    
    # Fallback su versione stabile se LXC non espone il file o se sei su Baremetal
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

    # 3. Esecuzione installer driver
    if [ "$VIRT_TYPE" == "lxc" ]; then
        echo -e "\n\033[32m[+] Installazione driver in modalità LXC (--no-kernel-modules)...\033[0m"
        sh "$run_path" --no-kernel-modules --accept-license --no-questions || true
    else
        echo -e "\n\033[32m[+] Installazione driver in modalità Baremetal (--dkms)...\033[0m"
        sh "$run_path" --dkms --accept-license --no-questions || true
    fi

    # 4. Installazione CUDA Toolkit 13.2 da repository ufficiale
    echo -e "\n\033[32m[+] Configurazione repository e installazione CUDA Toolkit 13.2...\033[0m"
    local repo_distro="debian13"
    if [ "$OS_ID" == "ubuntu" ]; then
        repo_distro="ubuntu2404"
    fi

    cd /tmp
    wget -nc https://developer.download.nvidia.com/compute/cuda/repos/$repo_distro/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i cuda-keyring_1.1-1_all.deb
    apt update -y
    apt install -y cuda-toolkit-13-2

    # 5. Configurazione PATH
    if ! grep -q "cuda-13.2/bin" ~/.bashrc; then
        cp ~/.bashrc ~/.bashrc-backup
        echo 'export PATH=/usr/local/cuda-13.2/bin${PATH:+:${PATH}}' >> ~/.bashrc
    fi
    
    echo "export PATH=/usr/local/cuda-13.2/bin\${PATH:+:\${PATH}}" > /etc/profile.d/cuda.sh
    chmod +x /etc/profile.d/cuda.sh

    echo -e "\n\033[32m[OK] Fase 1 completata con successo!\033[0m"
    read -p "Premi Invio per continuare..."
}

fase_2_ai_stack() {
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e " \033[1;37mFASE 2: Compilazione Llama.cpp & Setup Modelli\033[0m"
    echo -e "\033[36m======================================================================\033[0m"

    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh
    mkdir -p "$BACKEND_DIR"/{unsloth,models,llama.cpp}
    
    if [ ! -d "$BACKEND_DIR/llama.cpp/.git" ]; then
        git clone https://github.com/ggerganov/llama.cpp.git "$BACKEND_DIR/llama.cpp"
    fi
    cd "$BACKEND_DIR/llama.cpp"
    rm -rf build
    cmake -B build -DGGML_CUDA=ON
    cmake --build build --config Release -j$(nproc)

    if [ -f "$BASE_DIR/tools/8gbModelCUDA.sh" ]; then
        bash "$BASE_DIR/tools/8gbModelCUDA.sh"
    else
        echo "Script 8gbModelCUDA.sh non trovato (saltato download modelli)."
    fi

    # Configurazione demone systemd per llama-server
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
    
    echo -e "\n\033[32m[OK] Llama.cpp compilato e servizio avviato!\033[0m"
    read -p "Premi Invio per continuare..."
}

fase_3_opencode() {
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e " \033[1;37mFASE 3: Setup OpenCode Assistant\033[0m"
    echo -e "\033[36m======================================================================\033[0m"

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
ExecStart=/bin/bash -c "echo 'OpenCode in ascolto (Placeholder)' && sleep infinity"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now opencode
    
    echo -e "\n\033[32m[OK] Servizio OpenCode configurato!\033[0m"
    read -p "Premi Invio per continuare..."
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
    clear
    echo -e "\033[31m[!] Pulizia totale in corso...\033[0m"
    systemctl disable --now llama-server opencode unsloth 2>/dev/null || true
    rm -f /etc/systemd/system/llama-server.service /etc/systemd/system/opencode.service
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
    echo -e "\033[1;37m   HOMELAB AI DEPLOYER - FINETUNING (v1.8)        \033[0m"
    echo -e "\033[36m==================================================\033[0m"
    echo -e " Ambiente rilevato: \033[33m$VIRT_TYPE\033[0m"
    echo -e " Cartella Driver:   \033[33m$DRIVERS_DIR\033[0m"
    echo " ------------------------------------------------"
    echo -e " \033[32mA.\033[0m Autodeploy Completo (Fasi 1-4)"
    echo " 1. Installa Dipendenze, Auto-Download Driver & CUDA 13.2"
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
        1) confirm_action "Avvia installazione Fase 1." && fase_1_dipendenze ;;
        2) confirm_action "Compila Llama.cpp e scarica i modelli." && fase_2_ai_stack ;;
        3) confirm_action "Crea l'ambiente per OpenCode." && fase_3_opencode ;;
        4) fase_4_dashboard ;;
        5) clear; exit 0 ;;
        p) confirm_action "Elimina l'ambiente AI e disinstalla driver/CUDA." && purge_all ;;
    esac
done
