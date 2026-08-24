#!/bin/bash
# ==============================================================================
# Homelab AI - NVIDIA Management Console
# Ambiente: Bare-Metal / LXC (Proxmox)
# ==============================================================================

set -euo pipefail

# Variabili Globali e Path
CONFIG_DIR="/etc/homelab-ai"
PORT_CONFIG="$CONFIG_DIR/ports.conf"
WEBUI_DIR="/opt/open-webui"
VENV_DIR="$WEBUI_DIR/venv"
VERSION="2.2.1"

# Assicuriamoci di essere root
if [[ $EUID -ne 0 ]]; then
   echo "Questo script deve essere eseguito come root (usa sudo)." 
   exit 1
fi

# Inizializza la directory di configurazione
mkdir -p "$CONFIG_DIR"

# ==============================================================================
# FUNZIONI DI SUPPORTO
# ==============================================================================

# Caricamento sicuro delle configurazioni
load_ports() {
    if [[ -f "$PORT_CONFIG" ]]; then
        # Usa 'set +u' temporaneamente per il source di file esterni potenzialmente incompleti
        set +u
        source "$PORT_CONFIG"
        set -u
    fi
    # Fallback garantiti
    SAFE_OLLAMA_PORT="${OLLAMA_PORT:-11434}"
    SAFE_WEBUI_PORT="${OPENWEBUI_PORT:-8080}"
}

# Installazione dipendenze di base
install_base_deps() {
    whiptail --title "Dipendenze" --infobox "Aggiornamento pacchetti e installazione dipendenze base..." 5 60
    apt-get update -y
    apt-get install -y whiptail curl wget git python3 python3-venv python3-pip pciutils
}

# ==============================================================================
# FUNZIONI PRINCIPALI (Voci del Menu)
# ==============================================================================

install_dependencies() {
    install_base_deps
    
    if ! command -v nvidia-smi &> /dev/null; then
        whiptail --title "NVIDIA Drivers" --msgbox "NVIDIA-SMI non trovato.\n\nSe sei su LXC, assicurati di aver configurato il passthrough dei device (/dev/nvidia*) dal nodo Proxmox host e di aver installato gli stessi driver del nodo host." 10 70
    else
        whiptail --title "NVIDIA Drivers" --msgbox "Driver NVIDIA rilevati correttamente nel container!" 8 60
    fi
}

install_stack_baremetal() {
    load_ports
    
    # 1. Installazione Ollama
    whiptail --title "Installazione" --infobox "Installazione di Ollama in corso..." 5 50
    curl -fsSL https://ollama.com/install.sh | sh
    systemctl enable --now ollama
    
    # 2. Installazione Open WebUI (Bare-Metal via Python VENV)
    whiptail --title "Installazione" --infobox "Configurazione Open WebUI (Bare-Metal) in corso...\nQuesto richiederà qualche minuto." 6 60
    
    mkdir -p "$WEBUI_DIR"
    if [ ! -d "$VENV_DIR" ]; then
        python3 -m venv "$VENV_DIR"
    fi
    
    # Attiva venv e installa
    bash -c "source $VENV_DIR/bin/activate && pip install --upgrade pip && pip install open-webui"
    
    # Crea servizio systemd per WebUI
    cat <<EOF > /etc/systemd/system/homelab-ai-frontend.service
[Unit]
Description=Open WebUI (Homelab AI)
After=network.target ollama.service

[Service]
Type=simple
User=root
Environment="PORT=$SAFE_WEBUI_PORT"
Environment="OLLAMA_BASE_URL=http://127.0.0.1:$SAFE_OLLAMA_PORT"
WorkingDirectory=$WEBUI_DIR
ExecStart=$VENV_DIR/bin/open-webui serve
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now homelab-ai-frontend
    
    # Salva configurazione porte
    cat <<EOF > "$PORT_CONFIG"
OLLAMA_PORT=$SAFE_OLLAMA_PORT
OPENWEBUI_PORT=$SAFE_WEBUI_PORT
EOF

    whiptail --title "Installazione Completata" --msgbox "Stack Bare-Metal installato con successo!\nOllama: Porta $SAFE_OLLAMA_PORT\nWebUI: Porta $SAFE_WEBUI_PORT" 8 60
}

download_models() {
    local MODELS=$(whiptail --title "Download Modelli" --checklist \
        "Seleziona i modelli da scaricare (Ottimizzati per 8GB VRAM, es. RTX 3060 Ti):" 15 70 5 \
        "qwen2.5-coder:7b" "Codice e logica (Qwen)" ON \
        "llama3:8b" "Generale (Meta)" OFF \
        "phi3:mini" "Leggero e veloce (Microsoft)" OFF 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ]; then
        # Rimuove le virgolette dalla stringa restituita da whiptail
        MODELS=$(echo "$MODELS" | tr -d '"')
        for MODEL in $MODELS; do
            whiptail --title "Download in corso" --infobox "Scaricamento di $MODEL tramite Ollama...\nAttendi prego." 5 60
            ollama pull "$MODEL"
        done
        whiptail --title "Successo" --msgbox "Tutti i modelli selezionati sono stati scaricati e sono pronti all'uso." 8 50
    fi
}

manage_service_dashboard() {
    while true; do
        load_ports

        local IP=$(hostname -I | awk '{print $1}')
        [[ -z "$IP" ]] && IP="127.0.0.1"

        local OS_INFO="Sistema Sconosciuto"
        [[ -f /etc/os-release ]] && OS_INFO=$(grep -w "PRETTY_NAME" /etc/os-release | cut -d"=" -f2 | tr -d '"')
        
        local GPU_INFO="Driver NVIDIA non rilevati o inattivi"
        if command -v nvidia-smi &> /dev/null; then
            GPU_INFO=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1)
        fi

        check_status() {
            systemctl is-active --quiet "$1" 2>/dev/null && echo "ATTIVO" || echo "INATTIVO"
        }

        local st_ollama=$(check_status "ollama")
        local st_webui=$(check_status "homelab-ai-frontend")

        local DASH_TEXT="--- Informazioni Hardware e Sistema ---\n"
        DASH_TEXT+="Sistema Operativo: $OS_INFO\n"
        DASH_TEXT+="Scheda Video     : $GPU_INFO\n"
        DASH_TEXT+="Indirizzo IP     : $IP\n\n"
        DASH_TEXT+="--- Endpoint e Stato Servizi ---\n"
        DASH_TEXT+="Ollama     [$st_ollama] : http://$IP:$SAFE_OLLAMA_PORT\n"
        DASH_TEXT+="Open WebUI [$st_webui] : http://$IP:$SAFE_WEBUI_PORT\n\n"
        DASH_TEXT+="Seleziona un'azione rapida:"

        SRV_CHOICE=$(whiptail --title "Dashboard Servizi & Controllo" \
            --menu "$DASH_TEXT" 22 85 7 \
            "1" "Riavvia Ollama" \
            "2" "Riavvia Open WebUI" \
            "3" "Ferma Ollama" \
            "4" "Ferma Open WebUI" \
            "5" "Avvia Ollama" \
            "6" "Avvia Open WebUI" \
            "BACK" "Torna al Menu Principale" 3>&1 1>&2 2>&3) || true

        [[ -z "$SRV_CHOICE" || "$SRV_CHOICE" == "BACK" ]] && break

        case "$SRV_CHOICE" in
            1) systemctl restart ollama ; whiptail --msgbox "Ollama riavviato." 8 40 ;;
            2) systemctl restart homelab-ai-frontend ; whiptail --msgbox "Open WebUI riavviato." 8 40 ;;
            3) systemctl stop ollama ; whiptail --msgbox "Ollama fermato." 8 40 ;;
            4) systemctl stop homelab-ai-frontend ; whiptail --msgbox "Open WebUI fermato." 8 40 ;;
            5) systemctl start ollama ; whiptail --msgbox "Ollama avviato." 8 40 ;;
            6) systemctl start homelab-ai-frontend ; whiptail --msgbox "Open WebUI avviato." 8 40 ;;
        esac
    done
}

view_logs() {
    local LOG_CHOICE=$(whiptail --title "Log di Sistema" --menu "Quale log vuoi ispezionare?" 15 50 2 \
        "1" "Log di Ollama" \
        "2" "Log di Open WebUI" 3>&1 1>&2 2>&3) || true

    case "$LOG_CHOICE" in
        1) journalctl -u ollama -n 50 --no-pager | less ;;
        2) journalctl -u homelab-ai-frontend -n 50 --no-pager | less ;;
    esac
}

uninstall_stack() {
    if whiptail --title "Attenzione" --yesno "Sei sicuro di voler rimuovere Ollama, Open WebUI e tutti i modelli? L'operazione è irreversibile." 10 60; then
        systemctl stop ollama homelab-ai-frontend 2>/dev/null || true
        systemctl disable ollama homelab-ai-frontend 2>/dev/null || true
        rm -f /etc/systemd/system/homelab-ai-frontend.service
        rm -rf "$WEBUI_DIR"
        rm -rf /usr/share/ollama
        rm -f /usr/local/bin/ollama
        systemctl daemon-reload
        whiptail --title "Disinstallazione" --msgbox "Stack completamente rimosso dal sistema." 8 50
    fi
}

# ==============================================================================
# MENU PRINCIPALE
# ==============================================================================

while true; do
    CHOICE=$(whiptail --title "Homelab AI - NVIDIA Management Console (v$VERSION)" \
        --menu "Ambiente: LXC (Proxmox)\n\nScegli un'operazione:" 22 80 8 \
        "A" "Express Auto-Deploy (Installa tutto)" \
        "1" "Installa Dipendenze, Driver NVIDIA & CUDA" \
        "2" "Installa Ollama & Open WebUI (Bare-Metal)" \
        "3" "Download Modelli Ollama (Max 8GB VRAM)" \
        "5" "Dashboard Servizi (Stato, Info Sistema, Gestione)" \
        "9" "Visualizza Log di Sistema" \
        "10" "Aggiorna Repository" \
        "0" "Disinstalla Stack / Esci" 3>&1 1>&2 2>&3) || true

    [[ -z "$CHOICE" ]] && exit 0

    case "$CHOICE" in
        "A") install_dependencies ; install_stack_baremetal ; download_models ;;
        "1") install_dependencies ;;
        "2") install_stack_baremetal ;;
        "3") download_models ;;
        "5") manage_service_dashboard ;;
        "9") view_logs ;;
        "10") git pull origin main || whiptail --msgbox "Impossibile aggiornare. Esegui in una repository Git." 8 50 ;;
        "0") 
            if whiptail --title "Esci / Disinstalla" --yesno "Vuoi DISINSTALLARE lo stack (Sì) o solo USCIRE (No)?" 10 60; then
                uninstall_stack
            fi
            clear
            exit 0
            ;;
    esac
done
