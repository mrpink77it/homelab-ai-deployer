#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Proxmox LXC Sandbox Setup
# ==============================================================================

set -e

pveam update > /dev/null 2>&1

echo "===================================================="
echo "      🚀 CREAZIONE CONTAINER LXC SANDBOX           "
echo "===================================================="

# 1. ID Container
read -p "1) ID Container LXC [es. 100]: " CT_ID
while [ -z "$CT_ID" ]; do
  read -p "   --> Inserisci un ID valido: " CT_ID
done

# 2. Hostname / Nome Container
read -p "2) Nome Container / Hostname [default: sandbox-ai]: " HOSTNAME
HOSTNAME=${HOSTNAME:-sandbox-ai}

# 3. Password di Root
read -sp "3) Imposta Password di ROOT per il Container: " ROOT_PASS
echo ""
while [ -z "$ROOT_PASS" ]; do
  read -sp "   --> La password non può essere vuota. Reinserisci: " ROOT_PASS
  echo ""
done

# 4. Sistema Operativo
echo -e "\n4) Scegli il Sistema Operativo:"
echo "   1) Debian 13 (Trixie)"
echo "   2) Ubuntu 24.04 (Noble)"
read -p "   Selezione [1-2, default: 1]: " OS_CHOICE
OS_CHOICE=${OS_CHOICE:-1}

# 5. Risorse Hardware
read -p "5) CPU Cores [default: 2]: " CORES
CORES=${CORES:-2}

read -p "6) Memoria RAM in MB [default: 2048]: " RAM
RAM=${RAM:-2048}

read -p "7) Memoria SWAP in MB [default: 512]: " SWAP
SWAP=${SWAP:-512}

read -p "8) Dimensione Disco in GB [default: 8]: " DISK
DISK=${DISK:-8}

# 6. Storage Proxmox
read -p "9) Storage Proxmox [default: local-lvm]: " STORAGE
STORAGE=${STORAGE:-local-lvm}

# 7. Configurazione Rete
read -p "10) Bridge di Rete [default: vmbr0]: " BRIDGE
BRIDGE=${BRIDGE:-vmbr0}

echo -e "\n11) Modalità Indirizzo IP:"
echo "   1) DHCP (Automatico)"
echo "   2) Statico (Manuale)"
read -p "   Selezione [1-2, default: 1]: " NET_CHOICE
NET_CHOICE=${NET_CHOICE:-1}

if [ "$NET_CHOICE" -eq "2" ]; then
    read -p "    --> Indirizzo IP con CIDR [es. 192.168.1.180/24]: " STATIC_IP
    while [ -z "$STATIC_IP" ]; do
      read -p "        Inserisci un IP valido con subnet (es. 192.168.1.180/24): " STATIC_IP
    done
    read -p "    --> IP Gateway [es. 192.168.1.1]: " GATEWAY
    while [ -z "$GATEWAY" ]; do
      read -p "        Inserisci il Gateway della rete: " GATEWAY
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
  --nameserver "8.8.8.8 1.1.1.1" \
  --features nesting=1 \
  --password "$ROOT_PASS" \
  --unprivileged 0 \
  --onboot 1

echo "▶️ Avvio Container LXC $CT_ID..."
pct start "$CT_ID"

echo "⏳ Attesa assegnazione rete e IP (fino a 20 secondi)..."
IP=""
for i in {1..20}; do
  IP=$(pct exec "$CT_ID" -- ip -4 addr show eth0 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 || true)
  if [ -n "$IP" ]; then
    break
  fi
  sleep 1
done

echo "⚙️ Configurazione SSH, Python3 e Locales..."
pct exec "$CT_ID" -- bash -c "apt update && apt install -y openssh-server python3 locales && sed -i '/^# *en_US.UTF-8 UTF-8/s/^# //' /etc/locale.gen && locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 && sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && systemctl restart ssh"

echo -e "\n===================================================="
echo -e "✅ CONFIGURAZIONE COMPLETATA!"
if [ -n "$IP" ]; then
    echo "👉 IP della Sandbox: $IP"
else
    echo "⚠️ Non è stato possibile rilevare l'IP automaticamente. Verificare il server DHCP."
fi
echo "===================================================="
