#!/usr/bin/env bash
# ==============================================================================
# Proxmox AI Deployer - Main Dispatcher
# Repo: mrpink77it/homelab-ai-deployer
# Version: 2.0.0
# ==============================================================================

set -e

# ------------------------------------------------------------------------------
# RIMOZIONE SCRIPT DI INSTALLAZIONE
# ------------------------------------------------------------------------------
for search_dir in "." "$HOME" "$HOME/Downloads" "/root" "/root/Downloads"; do
    if [ -f "$search_dir/install.sh" ]; then
        rm -f "$search_dir/install.sh"
    fi
done

# ------------------------------------------------------------------------------
# CONTROLLI PRELIMINARI
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo -e "\033[0;31m[ERROR] Questo script deve essere eseguito come root!\033[0m"
  exit 1
fi

if ! command -v whiptail &> /dev/null; then
    echo "Installazione dipendenze interfaccia (whiptail) in corso..."
    apt-get update -qq && apt-get install -y whiptail -qq
fi

# ------------------------------------------------------------------------------
# RISOLUZIONE PERMESSI NELLA CARTELLA 'script'
# ------------------------------------------------------------------------------
if [ -d "script" ]; then
    find script/ -type f -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
else
    find . -maxdepth 1 -type f -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# RILEVAMENTO AMBIENTE E HARDWARE
# ------------------------------------------------------------------------------
is_wsl() {
    if grep -qi microsoft /proc/version 2>/dev/null || grep -qi wsl /proc/version 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

if is_wsl; then
    VIRT_ENV="Windows WSL 2"
elif grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
    VIRT_ENV="LXC Container"
else
    VIRT_ENV="Proxmox Host / Bare-Metal"
fi

HW_DETECTED="Nessuna GPU dedicata (Fallback CPU)"
export GPU_TYPE="CPU" # Variabile esportata per gli script figli

if lspci | grep -iq "NVIDIA" || [ -d "/proc/driver/nvidia" ] || command -v nvidia-smi &> /dev/null; then
    HW_DETECTED="NVIDIA GPU (CUDA)"
    GPU_TYPE="NVIDIA"
elif lspci | grep -i "vga\|3d\|display" | grep -iq "AMD\|Radeon" || [ -d "/sys/module/amdgpu" ]; then
    HW_DETECTED="AMD GPU (ROCm)"
    GPU_TYPE="AMD"
fi

# ------------------------------------------------------------------------------
# BANNER INTRODUTTIVO OTTIMIZZATO
# ------------------------------------------------------------------------------
show_intro_banner() {
    local INFO_TEXT="
                    PROXMOX AI DEPLOYER (V.2.0.0)
        --------------------------------------------------
          Benvenuto nella Fabbrica del Software Autonoma!
        --------------------------------------------------

          Questo strumento configurerà il tuo nodo Proxmox:
          
            * Dual Mode: Server Headless o AI Workstation (KDE)
            * Orchestrazione LXC: LLM, Agenti Coder, RAG
            * Ottimizzazione GPU: Condivisione VRAM Avanzata

        --------------------------------------------------
          Ambiente : $VIRT_ENV
          Hardware : $HW_DETECTED
        --------------------------------------------------

          Premi <Ok> per procedere (avvio automatico tra 120s)."

    timeout --foreground 120 whiptail --title " Proxmox AI Deployer " --msgbox "$INFO_TEXT" 22 80 || true
}

# ------------------------------------------------------------------------------
# FUNZIONE DI ESECUZIONE 
# ------------------------------------------------------------------------------
run_script() {
    local target_script="$1"
    local script_path=""
    
    if [ -f "script/$target_script" ]; then
        script_path="script/$target_script"
    elif [ -f "./$target_script" ]; then
        script_path="./$target_script"
    fi

    if [ -n "$script_path" ]; then
        clear
        echo -e "\033[0;36mAvvio di $script_path in corso...\033[0m\n"
        sleep 1
        exec "$script_path"
    else
        whiptail --title "Errore" --msgbox "File '$target_script' non trovato!\n\nAssicurati che il file esista all'interno della cartella 'script/'." 10 60
    fi
}

# ------------------------------------------------------------------------------
# MENU GRAFICO PRINCIPALE (ROUTING)
# ------------------------------------------------------------------------------
show_menu() {
    CHOICE=$(whiptail --title "Proxmox AI - Main Dispatcher" \
        --menu "\nAmbiente: $VIRT_ENV\nHardware Rilevato: $HW_DETECTED\n\nScegli un'operazione per iniziare:" 21 80 6 \
        "1" "🛠️  Prepara Server Edition (Host Headless)" \
        "2" "🖥️  Prepara Workstation Edition (KDE + Drivers)" \
        "3" "📦  Deploy Container AI (LXC Factory)" \
        "4" "🧹  Menu Utility (Pulizia VRAM, Uninstall)" \
        "5" "🚪  Esci" \
        3>&1 1>&2 2>&3)
        
    if [ $? -ne 0 ]; then
        clear
        echo -e "\033[0;32mUscita dal deployer. A presto!\033[0m"
        exit 0
    fi
}

# ------------------------------------------------------------------------------
# AVVIO E LOOP DI GESTIONE
# ------------------------------------------------------------------------------
show_intro_banner

while true; do
    show_menu
    case $CHOICE in
        1) run_script "setup-server.sh" ;;
        2) run_script "setup-workstation.sh" ;;
        3) run_script "deploy-lxc-ai.sh" ;;
        4) run_script "utility-menu.sh" ;;
        5) 
           clear
           echo -e "\033[0;32mUscita. Esecuzione terminata.\033[0m"
           exit 0 
           ;;
    esac
done
