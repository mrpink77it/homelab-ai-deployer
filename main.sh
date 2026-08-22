#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Main Dispatcher
# Repo: mrpink77it/homelab-ai-deployer
# Version: V.1.1.9
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
# RILEVAMENTO AMBIENTE WINDOWS (WSL)
# ------------------------------------------------------------------------------
is_wsl() {
    if grep -qi microsoft /proc/version 2>/dev/null || grep -qi wsl /proc/version 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# DIAGNOSTICA HARDWARE E AMBIENTE
# ------------------------------------------------------------------------------
if is_wsl; then
    VIRT_ENV="Windows WSL 2"
elif grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
    VIRT_ENV="LXC (Proxmox)"
else
    VIRT_ENV="Bare-Metal / VM"
fi

HW_DETECTED="Nessuna GPU dedicata (Fallback CPU)"
DEFAULT_ITEM="3"

if lspci | grep -iq "NVIDIA" || [ -d "/proc/driver/nvidia" ] || command -v nvidia-smi &> /dev/null; then
    HW_DETECTED="NVIDIA GPU"
    DEFAULT_ITEM="1"
elif lspci | grep -i "vga\|3d\|display" | grep -iq "AMD\|Radeon" || [ -d "/sys/module/amdgpu" ]; then
    HW_DETECTED="AMD GPU"
    DEFAULT_ITEM="2"
fi

# ------------------------------------------------------------------------------
# BANNER INTRODUTTIVO OTTIMIZZATO (Debian/Ubuntu Fix)
# ------------------------------------------------------------------------------
show_intro_banner() {
    local INFO_TEXT="
                    HOMELAB AI DEPLOYER (V.1.1.9)
        --------------------------------------------------
          Benvenuto nell'ecosistema di orchestrazione AI!
        --------------------------------------------------

          Questo strumento analizza automaticamente il tuo hardware
          e ti guida nella configurazione dello stack:

            * Backend:  llama.cpp ottimizzato (NVIDIA/AMD/CPU)
            * Frontend: Unsloth Studio, Open WebUI, JupyterLab
            * Servizi:  Bare-Metal services via systemd

        --------------------------------------------------
          Ambiente : $VIRT_ENV
          Hardware : $HW_DETECTED
        --------------------------------------------------

          Premi <Ok> per procedere (avvio automatico tra 120s)."

    timeout --foreground 120 whiptail --title " Homelab AI Deployer " --msgbox "$INFO_TEXT" 22 80 || true
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
# MENU GRAFICO PRINCIPALE
# ------------------------------------------------------------------------------
show_menu() {
    if is_wsl; then
        CHOICE=$(whiptail --title "Homelab AI - Dispatcher Windows (WSL)" \
            --default-item "$DEFAULT_ITEM" \
            --menu "\nAmbiente: $VIRT_ENV\nHardware Rilevato: $HW_DETECTED\n\nScegli un'operazione per Windows:" 20 80 6 \
            "1" "Ambiente NVIDIA WSL (manager-wsl-nvidia.sh)" \
            "2" "Ambiente AMD WSL    (manager-wsl-amd.sh)" \
            "3" "Ambiente CPU WSL    (manager-wsl-cpu.sh)" \
            "4" "Modulo Fine-Tuning  (manager-finetuning.sh)" \
            "5" "Disinstalla Servizi (uninstall.sh)" \
            "6" "Purge Estremo       (purge-homelab-ai.sh)" \
            3>&1 1>&2 2>&3)
    else
        CHOICE=$(whiptail --title "Homelab AI - Main Dispatcher" \
            --default-item "$DEFAULT_ITEM" \
            --menu "\nAmbiente: $VIRT_ENV\nHardware Rilevato: $HW_DETECTED\n\nScegli un'operazione:" 20 80 7 \
            "1" "Ambiente NVIDIA     (manager-nvidia.sh)" \
            "2" "Ambiente AMD         (manager-amd.sh)" \
            "3" "Ambiente CPU-Only    (manager-cpu.sh)" \
            "4" "Modulo Fine-Tuning   (manager-finetuning.sh)" \
            "5" "Disinstalla Servizi  (uninstall.sh)" \
            "6" "Purge Estremo        (purge-homelab-ai.sh)" \
            3>&1 1>&2 2>&3)
    fi
        
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
    if is_wsl; then
        case $CHOICE in
            1) run_script "manager-wsl-nvidia.sh" ;;
            2) run_script "manager-wsl-amd.sh" ;;
            3) run_script "manager-wsl-cpu.sh" ;;
            4) run_script "manager-finetuning.sh" ;;
            5) run_script "uninstall.sh" ;;
            6) run_script "purge-homelab-ai.sh" ;;
        esac
    else
        case $CHOICE in
            1) run_script "manager-nvidia.sh" ;;
            2) run_script "manager-amd.sh" ;;
            3) run_script "manager-cpu.sh" ;;
            4) run_script "manager-finetuning.sh" ;;
            5) run_script "uninstall.sh" ;;
            6) run_script "purge-homelab-ai.sh" ;;
        esac
    fi
done
