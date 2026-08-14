#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Proxmox LXC Sandbox Setup
# ==============================================================================

set -e

echo "===================================================="
echo "      🚀 CREAZIONE CONTAINER LXC SANDBOX           "
echo "===================================================="

# 🔄 Aggiornamento database template Proxmox
echo "🔄 Aggiornamento elenco template Proxmox..."
pveam update > /dev/null 2>&1 || true

# 1. Controllo e Richiesta ID Container LXC
echo -e "\n1) Identificativo Container (ID):"
while true; do
  read -p "   Inserisci ID LXC [es. 100, 200]: " CT_ID
  if [[ -z "$CT_ID" || ! "$CT_ID" =~ ^[0-9]+$ ]]; then
    echo "   ⚠️ Inserisci un numero di ID valido (es. 200)."
  elif pct status "$CT_ID" >/dev/null 2>&1 || qm status "$CT_ID" >/dev/null 2>&1; then
    echo "   ❌ L'ID $CT_ID è già in uso su questo nodo! Scegli un altro ID."
  else
    break
  fi
done

# 2. Hostname / Nome Container
echo -e "\n2) Nome Container / Hostname:"
read -p "   Nome [default: sandbox-ai]: " HOSTNAME
HOSTNAME=${HOSTNAME:-sandbox-ai}

# 3. Password di Root con Verifica Doppia
echo -e "\n3) Impostazione Password di ROOT:"
while true; do
  read -sp "   Inserisci Password ROOT per il container: " ROOT_PASS
  echo ""
  if [ -z "$ROOT_PASS" ]; then
    echo "   ⚠️ La password non può essere vuota."
    continue
  fi
  read -sp "   Conferma Password ROOT: " ROOT_PASS_CONFIRM
  echo ""
  if [ "$ROOT_PASS" != "$ROOT_PASS_CONFIRM" ]; then
    echo "   ❌ Le password non coincidono! Riprova."
  else
    echo "   ✅ Password impostata correttamente."
    break
  fi
done

# 4. Sistema Operativo
echo -e "\n4) Sistema Operativo:"
echo "   1) Debian 13 (Trixie)"
echo "   2) Ubuntu 24.04 (Noble)"
read -p "   Selezione [1-2, default: 1]: " OS_CHOICE
OS_CHOICE=${OS_CHOICE:-1}

# 5. Risorse Hardware
echo -e "\n5) Configurazione Risorse Hardware:"
read -p "   CPU Cores [default: 2]: " CORES
CORES=${CORES:-2}

read -p "   Memoria RAM in MB [default: 2048]: " RAM
RAM=${RAM:-2048}

read -p "   Memoria SWAP in MB [default: 512]: " SWAP
SWAP=${SWAP:-512}

read -p "   Dimensione Disco in GB [default: 8]: " DISK
DISK=${DISK:-8}

# 6. Rilevamento e Selezione Storage Proxmox
echo -e "\n6) Seleziona lo Storage Proxmox per il Disco:"
mapfile -t STORAGES < <(pvesm status 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')

if [ ${#STORAGES[@]} -eq 0 ]; then
    echo "❌ Nessuno storage attivo rilevato sul nodo Proxmox! Impossibile procedere."
    exit 1
fi

DEFAULT_STORAGE_IDX=1
for i in "${!STORAGES[@]}"; do
    idx=$((i+1))
    echo "   $idx) ${STORAGES[$i]}"
    if [[ "${STORAGES[$i]}" == "local-lvm" ]]; then
        DEFAULT_STORAGE_IDX=$idx
    fi
done

while true; do
  read -p "   Selezione [1-${#STORAGES[@]}, default: $DEFAULT_STORAGE_IDX]: " STORAGE_CHOICE
  STORAGE_CHOICE=${STORAGE_CHOICE:-$DEFAULT_STORAGE_IDX}
  if [[ "$STORAGE_CHOICE" =~ ^[0-9]+$ ]] && [ "$STORAGE_CHOICE" -ge 1 ] && [ "$STORAGE_CHOICE" -le "${#STORAGES[@]}" ]; then
    STORAGE="${STORAGES[$((STORAGE_CHOICE-1))]}"
    break
  else
    echo "   ⚠️ Selezione non valida. Scegli un numero tra 1 e ${#STORAGES[@]}."
  fi
done
echo "   👉 Storage selezionato: $STORAGE"

# 7. Rilevamento e Selezione Bridge di Rete
echo -e "\n7) Seleziona il Bridge di Rete:"
mapfile -t BRIDGES < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}')

if [ ${#BRIDGES[@]} -eq 0 ]; then
    BRIDGES=("vmbr0")
fi

DEFAULT_BRIDGE_IDX=1
for i in "${!BRIDGES[@]}"; do
    idx=$((i+1))
    echo "   $idx) ${BRIDGES[$i]}"
done

while true; do
  read -p "   Selezione [1-${#BRIDGES[@]}, default: $DEFAULT_BRIDGE_IDX]: " BRIDGE_CHOICE
  BRIDGE_CHOICE=${BRIDGE_CHOICE:-$DEFAULT_BRIDGE_IDX}
  if [[ "$BRIDGE_CHOICE" =~ ^[0-9]+$ ]] && [ "$BRIDGE_CHOICE" -ge 1 ] && [ "$BRIDGE_CHOICE" -le "${#BRIDGES[@]}" ]; then
    BRIDGE="${BRIDGES[$((BRIDGE_CHOICE-1))]}"
    break
  else
    echo "   ⚠️ Selezione non valida. Scegli un numero tra 1 e ${#BRIDGES[@]}."
  fi
done
echo "   👉 Bridge selezionato: $BRIDGE"

# 8. Configurazione Indirizzo IP
echo -e "\n8) Modalità Indirizzo IP:"
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

# 9. Selezione e Download Template
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

# 10. Creazione Container LXC
echo -e "\n📦 Creazione Container LXC ID $CT_ID ($HOSTNAME) sullo storage '$STORAGE'..."
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
