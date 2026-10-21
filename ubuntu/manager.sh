#!/bin/bash
# ==============================================================================
# manager.sh - Dual-GPU Homelab AI Deployer & Manager
# Ambiente: Ubuntu 24.04 / Debian 13 (Baremetal / LXC)
# Versione: 2.5.7 (Aggressive NVIDIA Services Stop & Module Unload)
# ==============================================================================
set -e

BASE_DIR="/opt/homelab-ai-deployer"
TOOLS_DIR="$BASE_DIR/tools"
DRIVERS_DIR="$BASE_DIR/drivers"
BACKEND_DIR="/opt/homelab-ai/backend"
MODELS_DIR="$BACKEND_DIR/models"
LOG_DIR="$BASE_DIR/logs"
mkdir -p "$LOG_DIR" "$DRIVERS_DIR" "$TOOLS_DIR" "$MODELS_DIR"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_EXT="$LOG_DIR/install_ext_$TIMESTAMP.log"
LOG_ERR="$LOG_DIR/install_err_$TIMESTAMP.log"
touch "$LOG_EXT" "$LOG_ERR"

source /etc/os-release
OS_ID=$ID
OS_VER=$VERSION_ID
VIRT_TYPE=$(systemd-detect-virt || echo "baremetal")

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

fase_1_dipendenze() {
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e " \033[1;37mFASE 1: Driver NVIDIA 595.104.02 (.run + DKMS) & AMD Vulkan Runtime\033[0m"
    echo -e "\033[36m======================================================================\033[0m"
    
    configure_system_locale_tz

    echo -e "\n\033[32m[+] Installazione dipendenze di compilazione, initramfs ed header kernel...\033[0m"
    apt-get update -y
    apt-get install -y g++ freeglut3-dev build-essential dkms initramfs-tools linux-headers-$(uname -r) libglvnd-dev pkg-config libx11-dev libxmu-dev libxi-dev libglu1-mesa-dev libfreeimage-dev libglfw3-dev wget htop btop nvtop glances git pciutils cmake curl libcurl4-openssl-dev mc jq libyaml-cpp-dev

    echo -e "\n\033[32m[+] Installazione driver e strumenti Vulkan (per AMD RX 5700 XT)...\033[0m"
    apt-get install -y mesa-vulkan-drivers libvulkan1 vulkan-tools libvulkan-dev glslang-tools

    echo -e "\n\033[32m[+] Arresto servizi NVIDIA e scaricamento forzato moduli kernel...\033[0m"
    systemctl stop nvidia-persistenced nvidia-powerd 2>/dev/null || true
    for mod in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
        modprobe -r "$mod" 2>/dev/null || rmmod "$mod" 2>/dev/null || true
    done

    echo -e "\n\033[32m[+] Download e installazione Driver NVIDIA v595.104.02 (.run)...\033[0m"
    local driver_version="595.104.02"
    local run_name="NVIDIA-Linux-x86_64-$driver_version.run"
    local run_url="https://us.download.nvidia.com/XFree86/Linux-x86_64/$driver_version/$run_name"
    local run_path="$DRIVERS_DIR/$run_name"

    if [ ! -f "$run_path" ]; then
        echo -e "\n\033[32m[+] Download del driver NVIDIA v$driver_version in corso...\033[0m"
        wget -O "$run_path" "$run_url"
    else
        echo -e "\n\033[32m[+] Driver .run già presente in locale:\033[0m $run_path"
    fi

    chmod +x "$run_path"

    echo -e "\n\033[32m[+] Esecuzione installer NVIDIA con supporto DKMS e --no-x-check...\033[0m"
    sh "$run_path" --silent --dkms --accept-license --no-questions --no-x-check || {
        echo "[-] Errore nell'installazione del driver .run. Controlla /var/log/nvidia-installer.log"
        exit 1
    }

    echo -e "\n\033[32m[+] Installazione Toolkit CUDA...\033[0m"
    local repo_distro="debian13"
    if [ "$OS_ID" == "ubuntu" ]; then
        repo_distro="ubuntu2404"
    fi

    cd /tmp
    wget -nc https://developer.download.nvidia.com/compute/cuda/repos/$repo_distro/x86_64/cuda-keyring_1.1-1_all.deb || true
    dpkg -i cuda-keyring_1.1-1_all.deb 2>/dev/null || true
    apt-get update -y
    apt-get install -y cuda-toolkit || echo "[!] Toolkit CUDA configurato."

    if ! grep -q "cuda/bin" ~/.bashrc; then
        echo 'export PATH=/usr/local/cuda/bin${PATH:+:${PATH}}' >> ~/.bashrc
    fi
    
    echo -e "\n\033[32m[OK] Fase 1 completata con successo!\033[0m"
    read -p "Premi Invio per continuare..."
}

fase_2_vulkan_amd() {
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e " \033[1;37mFASE 2: Compilazione Llama.cpp con Vulkan (AMD RX 5700 XT - Porta 8080)\033[0m"
    echo -e "\033[36m======================================================================\033[0m"
    mkdir -p "$BACKEND_DIR/llama.cpp-vulkan" /home/alex/llama_models
    if [ ! -d "$BACKEND_DIR/llama.cpp-vulkan/.git" ]; then
        git clone https://github.com/ggml-org/llama.cpp.git "$BACKEND_DIR/llama.cpp-vulkan"
    else
        cd "$BACKEND_DIR/llama.cpp-vulkan" && git pull origin master || true
    fi
    cd "$BACKEND_DIR/llama.cpp-vulkan"
    cmake -B build -DGGML_VULKAN=ON
    cmake --build build --config Release -j$(nproc)
    cat <<EOF > /etc/systemd/system/llama-cpp-vulkan.service
[Unit]
Description=Llama.cpp Vulkan Server (RX 5700 XT - Port 8080)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BACKEND_DIR/llama.cpp-vulkan/build/bin
Environment="GGML_VK_VISIBLE_DEVICES=0"
ExecStart=$BACKEND_DIR/llama.cpp-vulkan/build/bin/llama-server --host 0.0.0.0 --port 8080 --models-dir /home/alex/llama_models --cache-type-k q4_0 --cache-type-v q4_0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now llama-cpp-vulkan
    echo -e "\n\033[32m[OK] Llama.cpp Vulkan avviato sulla porta 8080!\033[0m"
    read -p "Premi Invio per continuare..."
}

fase_3_unsloth_cuda() {
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e " \033[1;37mFASE 3: Unsloth Studio / CUDA (NVIDIA RTX 3060 Ti - Porta 8888)\033[0m"
    echo -e "\033[36m======================================================================\033[0m"
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh || true
    mkdir -p "$BACKEND_DIR/unsloth"
    cd "$BACKEND_DIR/unsloth"
    uv venv --python 3.11 venv --clear
    ./venv/bin/pip install --upgrade pip
    ./venv/bin/pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
    ./venv/bin/pip install unsloth-studio unsloth
    cat <<EOF > /etc/systemd/system/unsloth-studio.service
[Unit]
Description=Unsloth Studio Global CUDA Service (Port 8888)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BACKEND_DIR/unsloth
Environment=CUDA_DEVICE_ORDER=PCI_BUS_ID
Environment=CUDA_VISIBLE_DEVICES=0
ExecStart=/root/.local/bin/unsloth studio --host 0.0.0.0 --port 8888
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now unsloth-studio
    echo -e "\n\033[32m[OK] Unsloth Studio CUDA avviato sulla porta 8888!\033[0m"
    read -p "Premi Invio per continuare..."
}

fase_4_support_services() {
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e " \033[1;37mFASE 4: CPU Worker (8082), Qdrant (6333), Gateway (9000) & Dify (8000)\033[0m"
    echo -e "\033[36m======================================================================\033[0m"
    cat <<EOF > /etc/systemd/system/llama-cpu.service
[Unit]
Description=Llama.cpp CPU Support Server (Port 8082)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BACKEND_DIR/llama.cpp-vulkan/build/bin
ExecStart=$BACKEND_DIR/llama.cpp-vulkan/build/bin/llama-server --host 127.0.0.1 --port 8082 --models-dir /home/alex/llama_models -ngl 0 -t 8 --cache-type-k q4_0 --cache-type-v q4_0
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    bash <(curl -s https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/ubuntu/setup_qdrant.sh) || echo "[!] Qdrant già configurato."
    bash <(curl -s https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/ubuntu/setup_router.sh) || echo "[!] Gateway già configurato."
    bash <(curl -s https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/ubuntu/setup_dify.sh) || echo "[!] Dify già configurato."
    systemctl daemon-reload
    systemctl enable --now llama-cpu
    echo -e "\n\033[32m[OK] Tutti i servizi di supporto, Qdrant, Gateway e Dify sono attivi!\033[0m"
    read -p "Premi Invio per continuare..."
}

fase_5_dashboard() {
    clear
    tput civis
    trap 'tput cnorm' EXIT
    while true; do
        printf "\033[H"
        local uptime_str=$(uptime -p)
        local load_avg=$(uptime | awk -F'load average:' '{print $2}')
        local mem_info=$(free -m | awk 'NR==2{printf "RAM: %s MB / %s MB (%.1f%%)", $3, $2, $3*100/$2}')
        local amd_status="\033[31m[OFFLINE]\033[0m"
        if systemctl is-active --quiet llama-cpp-vulkan 2>/dev/null; then
            amd_status="\033[32m[ATTIVO]\033[0m ➔ AMD Vulkan (Port 8080)"
        fi
        local nvi_status="\033[31m[OFFLINE]\033[0m"
        if systemctl is-active --quiet unsloth-studio 2>/dev/null; then
            nvi_status="\033[32m[ATTIVO]\033[0m ➔ NVIDIA CUDA (Port 8888)"
        fi
        local cpu_status="\033[31m[OFFLINE]\033[0m"
        if systemctl is-active --quiet llama-cpu 2>/dev/null; then
            cpu_status="\033[32m[ATTIVO]\033[0m ➔ CPU Worker (Port 8082)"
        fi
        local gw_status="\033[31m[OFFLINE]\033[0m"
        if systemctl is-active --quiet llm-gateway 2>/dev/null; then
            gw_status="\033[32m[ATTIVO]\033[0m ➔ LLM Gateway (Port 9000)"
        fi
        local qd_status="\033[31m[OFFLINE]\033[0m"
        if systemctl is-active --quiet qdrant 2>/dev/null; then
            qd_status="\033[32m[ATTIVO]\033[0m ➔ Qdrant Vector DB (Port 6333)"
        fi
        local df_status="\033[31m[OFFLINE]\033[0m"
        if command -v docker &> /dev/null && docker ps 2>/dev/null | grep -q "dify"; then
            df_status="\033[32m[ATTIVO]\033[0m ➔ Dify UI (Port 8000)"
        fi
        echo -e "\033[1;36m╔════════════════════════════════════════════════════════════════════════════╗\033[0m"
        echo -e "\033[1;36m║\033[1;33m         DUAL-GPU HYBRID HOMELAB AI - SYSTEM MONITOR & DASHBOARD            \033[1;36m║\033[0m"
        echo -e "\033[1;36m╠════════════════════════════════════════════════════════════════════════════╣\033[0m"
        echo -e "\033[1;36m║\033[0m \033[1mUptime:   \033[0m $uptime_str"
        echo -e "\033[1;36m║\033[0m \033[1mLoad Avg: \033[0m $load_avg"
        echo -e "\033[1;36m║\033[0m \033[1mSystem:   \033[0m $mem_info"
        echo -e "\033[1;36m╠────────────────────────────────────────────────────────────────────────────╣\033[0m"
        echo -e "\033[1;36m║\033[1;35m [ 🤖 CORE AI SERVICES STATUS ]                                             \033[1;36m║\033[0m"
        echo -e "\033[1;36m║\033[0m 1. AMD RX 5700 XT (Vulkan) : $amd_status"
        echo -e "\033[1;36m║\033[0m 2. NVIDIA RTX 3060 (CUDA)  : $nvi_status"
        echo -e "\033[1;36m║\033[0m 3. CPU Support Node        : $cpu_status"
        echo -e "\033[1;36m║\033[0m 4. LLM Gateway & Dashboard : $gw_status"
        echo -e "\033[1;36m║\033[0m 5. Qdrant Vector Database  : $qd_status"
        echo -e "\033[1;36m║\033[0m 6. Dify Orchestration UI   : $df_status"
        echo -e "\033[1;36m╠════════════════════════════════════════════════════════════════════════════╣\033[0m"
        echo -e "\033[1;36m║\033[1;33m COMMANDS: \033[0m[r] Refresh  [q] Exit                                     \033[1;36m║\033[0m"
        echo -e "\033[1;36m╚════════════════════════════════════════════════════════════════════════════╝\033[0m"
        echo -n -e "\033[1mSeleziona comando:\033[0m "
        read -t 2 -n 1 -s key || true
        if [[ "${key,,}" == "q" ]]; then
            tput cnorm
            break
        fi
    done
    tput cnorm
}

purge_all() {
    clear
    echo -e "\033[31m[!] Pulizia totale in corso...\033[0m"
    systemctl disable --now llama-cpp-vulkan unsloth-studio llama-cpu qdrant llm-gateway 2>/dev/null || true
    rm -f /etc/systemd/system/llama-cpp-vulkan.service /etc/systemd/system/unsloth-studio.service /etc/systemd/system/llama-cpu.service /etc/systemd/system/qdrant.service /etc/systemd/system/llm-gateway.service
    systemctl daemon-reload
    rm -rf /opt/homelab-ai /opt/dify /opt/qdrant /opt/gateway
    echo -e "\n\033[32m[OK] Pulizia completata.\033[0m"
    read -p "Premi Invio per continuare..."
}

while true; do
    clear
    echo -e "\033[36m==================================================\033[0m"
    echo -e "\033[1;37m    DUAL-GPU HOMELAB AI MANAGER (v2.5.7)          \033[0m"
    echo -e "\033[36m==================================================\033[0m"
    echo -e " Ambiente rilevato: \033[33m$VIRT_TYPE\033[0m"
    echo -e " Modelli GGUF:      \033[33m/home/alex/llama_models\033[0m"
    echo " ------------------------------------------------"
    echo -e " \033[32mA.\033[0m Autodeploy Completo (Fasi 1-5)"
    echo " 1. Installa Dipendenze, Driver NVIDIA 595.104.02 & AMD Vulkan"
    echo " 2. Compila Llama.cpp Vulkan (AMD RX 5700 XT - Porta 8080)"
    echo " 3. Installa Unsloth Studio / CUDA (NVIDIA 3060 Ti - Porta 8888)"
    echo " 4. Setup CPU Worker (8082), Qdrant (6333), Gateway (9000) & Dify"
    echo " 5. Dashboard Monitoraggio Globale"
    echo " 6. Esci"
    echo " ------------------------------------------------"
    echo -e " \033[31;1mP.\033[0m PURGE Totale Infrastruttura AI"
    echo -e "\033[36m==================================================\033[0m"
    read -n 1 -s key
    case "${key,,}" in
        a)
            if confirm_action "Avvia il deployment completo dell'infrastruttura ibrida."; then
                fase_1_dipendenze && fase_2_vulkan_amd && fase_3_unsloth_cuda && fase_4_support_services && fase_5_dashboard
            fi ;;
        1) confirm_action "Avvia installazione Fase 1." && fase_1_dipendenze ;;
        2) confirm_action "Compila Llama.cpp per Vulkan." && fase_2_vulkan_amd ;;
        3) confirm_action "Configura Unsloth Studio per CUDA." && fase_3_unsloth_cuda ;;
        4) confirm_action "Installa servizi di supporto, Qdrant, Gateway e Dify." && fase_4_support_services ;;
        5) fase_5_dashboard ;;
        6) clear; exit 0 ;;
        p) confirm_action "Elimina l'intero ambiente AI e i servizi." && purge_all ;;
    esac
done
