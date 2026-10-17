#!/bin/bash

# Interrompi lo script in caso di errore
set -e

# --- CONFIGURAZIONE ---
TEMPLATE_STORAGE="local"       # Storage standard per i template LXC
CONTAINER_STORAGE="local-zfs"  # Storage ZFS per i dischi dei container
OSTYPE="ubuntu"                # ubuntu o debian
OS_VERSION="26.04"             # 24.04 per Ubuntu / 13 per Debian 13
ROOT_PASSWORD="proxmox"        # Password di root fissa
DNS_SERVERS="1.1.1.1 9.9.9.9 8.8.8.8"
BRIDGE="vmbr0"                 # Bridge di rete predefinito

echo "=== Avvio creazione automatica Container LXC con Nesting Forzato ==="

# 1. Trova il primo ID disponibile a partire da 300
VMS=$(pct list | awk 'NR>1 {print $1}')
CTID=300
while echo "$VMS" | grep -q "^$CTID$"; do
    CTID=$((CTID + 1))
done
echo "-> ID assegnato al container: $CTID"

# 2. Trova il progressivo 'n' basato sull'ultimo container denominato APPx
LAST_APP_NAME=$(pct list | awk 'NR>1 {print $3}' | grep -E '^APP[0-9]+$' | sort -V | tail -n 1)

if [ -z "$LAST_APP_NAME" ]; then
    NEXT_NUM=1
    echo "-> Nessun container APP esistente trovato. Partiamo da APP1."
else
    LAST_NUM=$(echo "$LAST_APP_NAME" | sed 's/APP//')
    NEXT_NUM=$((LAST_NUM + 1))
    echo "-> Ultimo container trovato: $LAST_APP_NAME. Assegnato il successivo."
fi

HOSTNAME="APP${NEXT_NUM}"
while pct list | awk 'NR>1 {print $3}' | grep -q "^${HOSTNAME}$"; do
    NEXT_NUM=$((NEXT_NUM + 1))
    HOSTNAME="APP${NEXT_NUM}"
done

echo "-> Nome finale del container: $HOSTNAME"

# 3. Gestione e download del Template LXC su 'local'
pveam update > /dev/null 2>&1
TEMPLATE_FILE=$(pveam available -section system | grep -E "${OSTYPE}-${OS_VERSION}" | tail -n 1 | awk '{print $2}')

if [ -z "$TEMPLATE_FILE" ]; then
    echo "Errore: Impossibile trovare un template valido per ${OSTYPE} ${OS_VERSION}."
    exit 1
fi

if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE_FILE"; then
    echo "-> Download del template $TEMPLATE_FILE su storage '$TEMPLATE_STORAGE' in corso..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_FILE"
else
    echo "-> Template $TEMPLATE_FILE già presente su '$TEMPLATE_STORAGE'."
fi

# 4. Creazione del Container LXC su local-zfs con rete temporanea in DHCP
echo "-> Creazione del container su $CONTAINER_STORAGE in corso..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" \
    -storage "$CONTAINER_STORAGE" \
    -hostname "$HOSTNAME" \
    -ostype "$OSTYPE" \
    -cores 2 \
    -memory 2048 \
    -swap 512 \
    -rootfs "${CONTAINER_STORAGE}:8" \
    -net0 "name=eth0,bridge=${BRIDGE},firewall=1,ip=dhcp,ip6=auto" \
    -password "$ROOT_PASSWORD" \
    -unprivileged 1 \
    -features nesting=1 \
    -start 1

# 5. Abilitazione forzata del Nesting post-creazione
echo "-> Abilitazione esplicita del Nesting (nesting=1)..."
pct set "$CTID" -features nesting=1

echo "-> Attesa acquisizione indirizzo IP DHCP..."
sleep 5

# 6. Recupero dell'IP DHCP e trasformazione in IP Statico + SLAAC
CONTAINER_IP=""
for i in {1..10}; do
    CONTAINER_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')
    if [ -n "$CONTAINER_IP" ]; then
        break
    fi
    sleep 2
done

if [ -z "$CONTAINER_IP" ]; then
    echo "Attenzione: Impossibile rilevare l'IP DHCP automaticamente. Il container rimarrà configurato con DHCP."
else
    echo "-> IP DHCP rilevato: $CONTAINER_IP"
    
    GATEWAY_IP=$(pct exec "$CTID" -- ip route show default | awk '{print $3}')
    CIDR_MASK=$(pct exec "$CTID" -- ip -o -4 addr show eth0 | awk '{print $4}')
    
    if [ -z "$CIDR_MASK" ]; then
        CIDR_MASK="${CONTAINER_IP}/24"
    fi

    echo "-> Conversione della configurazione di rete in IP Statico ($CIDR_MASK) e IPv6 SLAAC..."
    
    if [ -n "$GATEWAY_IP" ]; then
        pct set "$CTID" -net0 "name=eth0,bridge=${BRIDGE},firewall=1,ip=${CIDR_MASK},gw=${GATEWAY_IP},ip6=auto"
    else
        pct set "$CTID" -net0 "name=eth0,bridge=${BRIDGE},firewall=1,ip=${CIDR_MASK},ip6=auto"
    fi

    pct set "$CTID" -nameserver "$DNS_SERVERS"
    
    # Applicazione corretta della rete per Ubuntu 24.04 (Netplan / systemd-networkd)
    #pct exec "$CTID" -- netplan apply || pct exec "$CTID" -- systemctl restart systemd-networkd || true
    echo "-> Rete configurata in modo statico con successo."
fi

echo "========================================================"
echo "Container ID:   $CTID"
echo "Nome Host:      $HOSTNAME"
echo "Features:       nesting=1 (Attivo)"
echo "IP Statico:     $CONTAINER_IP"
echo "Password Root:  $ROOT_PASSWORD"
echo "========================================================"
