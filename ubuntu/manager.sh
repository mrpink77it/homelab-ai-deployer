#!/bin/bash
# ==============================================================================
# manager-hybrid.sh - Dual-GPU Homelab AI Deployer & Manager
# Ambiente: Ubuntu 24.04 / Debian 13 (Baremetal / LXC)
# Versione: 2.5.2 (Fixed APT Dependencies & Hardened Dashboard)
# ==============================================================================
set -e

BASE_DIR="/opt/homelab-ai-deployer"
TOOLS_DIR="\$BASE_DIR/tools"
DRIVERS_DIR="\$BASE_DIR/drivers"
BACKEND_DIR="/opt/homelab-ai/backend"
MODELS_DIR="\$BACKEND_DIR/models"
LOG_DIR="\$BASE_DIR/logs"
mkdir -p "$LOG_DIR" "$DRIVERS_DIR" "$TOOLS_DIR" "$MODELS_DIR"

TIMESTAMP=\$(date +"%Y%m%d_%H%M%S")
LOG_EXT="$LOG_DIR/install_ext_$TIMESTAMP.log"
LOG_ERR="$LOG_DIR/install_err_$TIMESTAMP.log"
touch "$LOG_EXT" "$LOG_ERR"

source /etc/os-release
OS_ID=\$ID
OS_VER=\$VERSION_ID
VIRT_TYPE=\$(systemd-detect-virt || echo "baremetal")

# ------------------------------------------------------------------------------
# FUNZIONI DI SUPPORTO & UI
# ------------------------------------------------------------------------------
confirm_action() {
    local desc="\$1"
    echo -e "\n\033[33mDESCRIZIONE:\033[0m \$desc"
    read -p "Sei sicuro di voler procedere? [S/n]: " choice
    case "\$choice" in
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
# FASI DI INSTALLAZIONE DUALE & INFRASTRUTTURA
# ------------------------------------------------------------------------------
fase_1_dipendenze() {
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e " \033[1;37mFASE 1: Dipendenze, Driver NVIDIA (CUDA 13.2) & AMD Vulkan Runtime\033[0m"
    echo -e "\033[36m======================================================================\033[0m"
    
    configure_system_locale_tz

    echo -e "\n\033[32m[+] Installazione pacchetti di sistema, compilatori e tool di rete...\033[0m"
    apt install -y g++ freeglut3-dev build-essential libx11-dev libxmu-dev libxi-dev libglu1-mesa-dev libfreeimage-dev libglfw3-dev wget htop btop nvtop glances git pciutils cmake curl libcurl4-openssl-dev mc jq libyaml-cpp-dev

    echo -e "\n\033[32m[+] Installazione driver e strumenti Vulkan (per AMD RX 5700 XT)...\033[0m"
    apt install -y mesa-vulkan-drivers libvulkan1 vulkan-tools libvulkan-dev glslang-tools

    echo -e "\n\033[32m[+] Configurazione repository e toolkit NVIDIA CUDA...\033[0m"
    local driver_version="550.54.14"
    local run_name="NVIDIA-Linux-x86_64-\$driver_version.run"
    local run_url="https://us.download.nvidia.com/XFree86/Linux-x86_64/$driver_version/$run_name"
    local run_path="$DRIVERS_DIR/$run_name"

    if [ ! -f "\$run_path" ]; then
        wget -O "$run_path" "$run_url" || echo "[!] Download driver .run saltato o non necessario se gestito da apt."
    fi

    local repo_distro="debian13"
    if [ "\$OS_ID" == "ubuntu" ]; then
        repo_distro="ubuntu2404"
    fi

    cd /tmp
    wget -nc https://developer.download.nvidia.com/compute/cuda/repos/\$repo_distro/x86_64/cuda-keyring_1.1-1_all.deb || true
    dpkg -i cuda-keyring_1.1-1_all.deb 2>/dev/null || true
    apt update -y
    apt install -y nvidia-driver-550 cuda-toolkit-13-2 || echo "[!] Driver CUDA installati o già presenti."

    if ! grep -q "cuda-13.2/bin" ~/.bashrc; then
        echo 'export PATH=/usr/local/cuda-13.2/bin${PATH:+:${PATH}}' >> ~/.bashrc
    fi
    
    echo -e "\n\033[32m[OK] Fase 1 completata con successo!\033[0m"
    read -p "Premi Invio per continuare..."
}

fase_2_vulkan_amd() {
    clear
    echo -e "\033[36m======================================================================\033[0m"
    echo -e " \033[1;37mFASE 2: Compilazione Llama.cpp con Vulkan (AMD RX 5700 XT - Porta 8080)\033[0m"
    echo -e "\033[36m======================================================================\033[0m"

    mkdir -p "\$BACKEND_DIR/llama.cpp-vulkan" /home/alex/llama_models
    
    if [ ! -d "\$BACKEND_DIR/llama.cpp-vulkan/.git" ]; then
        git clone https://github.com/ggml-org/llama.cpp.git "\$BACKEND_DIR/llama.cpp-vulkan"
    else
        cd "\$BACKEND_DIR/llama.cpp-vulkan" && git pull origin master || true
    fi
    
    cd "\$BACKEND_DIR/llama.cpp-vulkan"
    cmake -B build -DGGML_VULKAN=ON
    cmake --build build --config Release -j\$(nproc)

    cat <<EOF > /etc/systemd/system/llama-cpp-vulkan.service
[Unit]
Description=Llama.cpp Vulkan Server (RX 5700 XT - Port 8080)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory
