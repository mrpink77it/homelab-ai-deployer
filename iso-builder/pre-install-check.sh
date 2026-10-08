#!/usr/bin/env bash
# ==============================================================================
# Proxmox Auto-Installer Hook - OS Detection & Triple Confirmation Guard
# ==============================================================================

set -euo pipefail

TARGET_DISK="${1:-/dev/sda}"

echo -e "\033[0;36m[CHECK] Scansione del disco $TARGET_DISK per OS esistenti...\033[0m"

HAS_EXISTING_OS=false

# Verifica firme file system e partizioni esistenti
if parted -s "$TARGET_DISK" print | grep -qE "ntfs|fat32|ext4|btrfs|zfs|swap|Linux|Windows"; then
    HAS_EXISTING_OS=true
fi

if [ "$HAS_EXISTING_OS" = true ]; then
    echo -e "\n\033[0;31m=============================================================="
    echo "  ATTENZIONE! È STATO RILEVATO UN SISTEMA OPERATIVO ESISTENTE!"
    echo "  Disco selezionato: $TARGET_DISK"
    echo "==============================================================\033[0m\n"
    
    # 1a CONFERMA
    read -p "CONFERMA 1/3: Digita 'DISTRUGGI' per proseguire con la cancellazione: " CONF1
    if [ "$CONF1" != "DISTRUGGI" ]; then
        echo "Installazione annullata."
        exit 1
    fi

    # 2a CONFERMA
    read -p "CONFERMA 2/3: Sei DAVVERO sicuro? Tutti i dati andranno persi. Digita 'CONFERMO': " CONF2
    if [ "$CONF2" != "CONFERMO" ]; then
        echo "Installazione annullata."
        exit 1
    fi

    # 3a CONFERMA
    read -p "CONFERMA 3/3: ULTIMO AVVISO! Digita 'CANCELLA TUTTO': " CONF3
    if [ "$CONF3" != "CANCELLA TUTTO" ]; then
        echo "Installazione annullata."
        exit 1
    fi

    echo -e "\033[0;32mTripla conferma ricevuta. Procedo con la formattazione ZFS del disco $TARGET_DISK...\033[0m"
else
    echo -e "\033[0;32mDisco vergine. Procedo con l'installazione automatica ZFS...\033[0m"
fi
