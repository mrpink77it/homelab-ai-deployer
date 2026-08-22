#!/usr/bin/env bash
# ==============================================================================
# Script: uninstall.sh
# Versione: 1.1.0
# Descrizione: Disinstallazione selettiva multi-istanza e pulizia suite
# Supporto: AMD, NVIDIA, CPU-Only (Bare-Metal & LXC)
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERRORE] Lo script richiede i privilegi di root. Avvialo con sudo.${NC}"
    exit 1
fi

# Assicurati che whiptail sia installato
if ! command -v whiptail &> /dev/null; then
    apt-get update >/dev/null && apt-get install -y whiptail >/dev/null
fi

# ------------------------------------------------------------------------------
# Rilevamento Hardware
# ------------------------------------------------------------------------------
detect_hardware() {
    local pci_info
    pci_info=$(lspci | grep -iE 'vga|3d|display' 2>/dev/null || true)
    
    if echo "$pci_info" | grep -qi 'nvidia'; then
        echo "NVIDIA"
    elif echo "$pci_info" | grep -qi 'amd'; then
        echo "AMD"
    else
        echo "CPU"
    fi
}
HW_TYPE=$(detect_hardware)

# ------------------------------------------------------------------------------
# Fase 1: Selezione e Rimozione Servizi systemd
# ------------------------------------------------------------------------------
mapfile -t SERVICE_FILES < <(find /etc/systemd/system/ -maxdepth 1 -name "homelab-ai-*.service" -printf "%f\n" 2>/dev/null || true)

if [[ ${#SERVICE_FILES[@]} -eq 0 ]]; then
    whiptail --title "Rimozione Servizi" --msgbox "Nessun servizio 'homelab-ai-*' trovato nel sistema." 8 60
else
    # Costruiamo l'array per la checklist di whiptail
    CHECKLIST_OPTIONS=()
    for srv in "${SERVICE_FILES[@]}"; do
        CHECKLIST_OPTIONS+=("$srv" "" "OFF")
    done

    # Mostra l'interfaccia di selezione multipla
    SELECTED_SERVICES=$(whiptail --title "Disinstallazione Selettiva (Hardware: $HW_TYPE)" \
        --checklist "\nSeleziona le istanze dei servizi da arrestare e rimuovere:\n(Usa SPAZIO per selezionare, INVIO per confermare)" \
        20 78 10 "${CHECKLIST_OPTIONS[@]}" 3>&1 1>&2 2>&3 || true)

    if [[ -n "$SELECTED_SERVICES" ]]; then
        echo -e "\n${GREEN}[1/3] Gestione Servizi Selezionati...${NC}"
        # Rimuove le virgolette inserite da whiptail (es. "servizio1.service" "servizio2.service")
        SELECTED_SERVICES=$(echo "$SELECTED_SERVICES" | tr -d '"')
        
        for srv in $SELECTED_SERVICES; do
            echo -e "${YELLOW} -> Arresto e disabilitazione di $srv...${NC}"
            systemctl stop "$srv" 2>/dev/null || true
            systemctl disable "$srv" 2>/dev/null || true
            rm -f "/etc/systemd/system/$srv"
        done
        systemctl daemon-reload
    else
        echo -e "\n${YELLOW}Nessun servizio selezionato per la rimozione.${NC}"
    fi
fi

# ------------------------------------------------------------------------------
# Fase 2: Pulizia Profonda (Opzionale)
# ------------------------------------------------------------------------------
if whiptail --title "Pulizia Profonda Dati" \
    --yesno "\nVuoi eliminare anche la directory di installazione (/opt/homelab-ai), i modelli scaricati, il gestore 'uv' e svuotare le cache di sistema?\n\nATTENZIONE: Procedi solo se non hai altri servizi Homelab attivi, altrimenti ne romperai le dipendenze!" \
    12 78; then
    
    echo -e "\n${GREEN}[2/3] Rimozione directory, modelli e gestori pacchetti...${NC}"
    rm -rf /opt/homelab-ai
    rm -f /var/log/homelab-ai-*.log
    
    # Rimozione UV e Cache
    rm -f /root/.cargo/bin/uv /root/.cargo/bin/uvx
    rm -f /root/.local/bin/uv /root/.local/bin/uvx
    rm -f /home/*/.cargo/bin/uv /home/*/.cargo/bin/uvx 2>/dev/null || true
    rm -f /home/*/.local/bin/uv /home/*/.local/bin/uvx 2>/dev/null || true
    rm -rf /root/.cache/ccache /root/.cache/pip /root/.cache/uv
    rm -rf /home/*/.cache/ccache /home/*/.cache/pip /home/*/.cache/uv 2>/dev/null || true

    echo -e "\n${GREEN}[3/3] Esecuzione pulizia specifica per architettura [${HW_TYPE}]...${NC}"
    case "${HW_TYPE}" in
        "AMD")
            echo -e "${YELLOW} -> Rimozione iniezioni repository ROCm...${NC}"
            rm -f /etc/apt/sources.list.d/rocm.list
            rm -f /etc/apt/sources.list.d/amdgpu.list
            rm -f /etc/apt/preferences.d/99-rocm-amd
            rm -f /etc/apt/keyrings/rocm.gpg
            ;;
        "NVIDIA")
            echo -e "${YELLOW} -> Predisposizione rimozione file NVIDIA (Attualmente vuoto)...${NC}"
            # rm -f /etc/apt/sources.list.d/cuda*.list 2>/dev/null || true
            ;;
        "CPU")
            echo -e "${YELLOW} -> Nessuna configurazione repository esterna da rimuovere.${NC}"
            ;;
    esac

    echo -e "\n${CYAN}>>> Ottimizzazione pacchetti APT...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get autoremove --purge -y
    apt-get clean

    echo -e "\n${GREEN}=================================================================${NC}"
    echo -e "${GREEN} Pulizia profonda completata con successo!${NC}"
    echo -e "${GREEN}=================================================================${NC}"
else
    echo -e "\n${GREEN}Pulizia dati saltata. Sono stati modificati esclusivamente i servizi systemd selezionati.${NC}"
fi
