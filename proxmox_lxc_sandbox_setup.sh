#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Proxmox LXC Sandbox Setup
# ==============================================================================

set -e

pveam update> /dev/null 2>&1

echo "===================================================="
echo "      🚀 CREAZIONE CONTAINER LXC SANDBOX           "
echo "===================================================="

# 1. ID Container
read -p "1) ID Container LXC [es. 100]: " CT_ID </dev/tty
while [ -z "$CT_ID" ]; do
  read -p "   --> Inserisci un ID valido: " CT_ID </dev/tty
done

# 2. Hostname / Nome Container
read -p "2) Nome Container / Hostname [default: sandbox-ai]: " HOSTNAME </dev/tty
HOSTNAME=${HOSTNAME:-sandbox-ai}

# 3. Sistema Operativo
echo -e "\n3) Scegli il Sistema Operativo:"
echo "   1) Debian 13 (Trixie)"
echo "   2) Ubuntu 24.04 (Noble)"
read -p "   Selezione [1-2, default: 1]: " OS_CHOICE </dev/tty
OS_CHOICE=${OS_CHOICE:-1}

# 4. Risorse Hardware
read -p "4) CPU Cores [default: 2]: " CORES </dev/tty
CORES=${CORES:-2}

read -p "5) Memoria RAM in MB [default: 2048]: " RAM </dev/tty
RAM=${RAM:-2048}

read -p "6) Memoria SWAP in MB [default: 512]: " SWAP </dev/tty
SWAP=${SWAP:-512}

read -p "7) Dimensione Disco in GB [default: 8]: " DISK </dev/tty
DISK=${DISK:-8}

# 5. Storage Proxmox
read -p "8) Storage Proxmox [default: local-lvm]: " STORAGE </dev/tty
STORAGE=${STORAGE:-local-lvm}

# 6. Configurazione Rete
read -p "9) Bridge di Rete [default: vmbr0]: " BRIDGE </dev/tty
BRIDGE=${BRIDGE:-vmbr0}

echo -e "\n10) Modalità Indirizzo IP:"
echo "   1) DHCP (Automatico)"
echo "   2) Statico (Manuale)"
read -p "   Selezione [1-2, default: 1]: " NET_CHOICE </dev/tty
NET_CHOICE=${NET_CHOICE:-1}

if [ "$NET_CHOICE" -eq "2" ]; then
    read -p "    --> Indirizzo IP con CIDR [es. 192.168.1.180/24]: " STATIC_IP </dev/tty
    while [ -z "$STATIC_IP" ]; do
      read -p "        Inserisci un IP valido con subnet (es. 192.168.1.180/24): " STATIC_IP </dev/tty
    done
    read -p "    --> IP Gateway [es. 192.168.1.1]: " GATEWAY </dev/tty
    while [ -z "$GATEWAY" ]; do
      read -p "        Inserisci il Gateway della rete: " GATEWAY </dev/tty
    done
    NET_PARAM="name=eth0,bridge=$BRIDGE,ip=$STATIC_IP,gw=$GATEWAY"
else
    NET_PARAM="name=eth0,bridge=$BRIDGE,ip=dhcp"
fi

if [ "$OS_CHOICE" -eq "2" ]; then
    OS_TYPE="ubuntu"
    SEARCH_KEY="ubuntu-24.04"
else
    OS_TYPE="debian"
    SEARCH_KEY="debian-13"
fi

echo -e "\n🔍 Ricerca template $SEARCH_KEY..."
TEMPLATE_NAME=$(pveam available | grep "$SEARCH_KEY" | head -n 1 | awk '{print $2}')

if [ -z "$TEMPLATE_NAME" ]; then
    echo "⚠️ Template $SEARCH_KEY non trovato nei repository PVE. Provo ricerca generica per $OS_TYPE..."
    TEMPLATE_NAME=$(pveam available | grep "$OS_TYPE" | head -n 1 | awk '{print $2}')
fi

if [ -z "$TEMPLATE_NAME" ]; then
    echo "❌ Impossibile trovare un template per $OS_TYPE. Annullamento."
    exit 1
fi

echo "⬇️ Downloading template: $TEMPLATE_NAME..."
pveam download local "$TEMPLATE_NAME"

echo "📦 Creazione Container LXC ID $CT_ID ($HOSTNAME)..."
pct create "$CT_ID" "local:vztmpl/$TEMPLATE_NAME" \
  --ostype "$OS_TYPE" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$RAM" \
  --swap "$SWAP" \
  --storage "$STORAGE" \
  --rootfs "$STORAGE:$DISK" \
  --net0 "$NET_PARAM" \
  --unprivileged 0 \
  --onboot 1

echo "▶️ Avvio Container LXC $CT_ID..."
pct start "$CT_ID"

echo "⏳ Attesa avvio rete e configurazione SSH/Python/UTF-8..."
sleep 5
pct exec "$CT_ID" -- bash -c "apt update && apt install -y openssh-server python3 locales && sed -i '/^# *en_US.UTF-8 UTF-8/s/^# //' /etc/locale.gen && locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 && sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && systemctl restart ssh"

echo -e "\n===================================================="
echo -ne "✅ CONFIGURAZIONE COMPLETATA!\n👉 IP della Sandbox: "
pct exec "$CT_ID" -- ip -4 addr show eth0 | grep inet | awk '{print $2}' | cut -d/ -f1
echo "===================================================="
