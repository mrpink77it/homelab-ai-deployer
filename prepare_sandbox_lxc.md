# Guida Preparazione Sandbox

Questa guida descrive i passaggi per preparare un container LXC isolato da utilizzare come **Sandbox di Esecuzione** tramite l'Opzione 4 dell'**Homelab AI Deployer**.

---

## 📋 Requisiti Minimi
Per consentire la configurazione automatica delle chiavi SSH e l'esecuzione di codice remoto tramite l'API Code Runner (`:9000`), la Sandbox deve soddisfare i seguenti requisiti:
- Sistema Operativo: **Debian 13 (Trixie)** o **Ubuntu 24.04 LTS (Noble)**
- Server SSH attivo (`openssh-server`)
- Accesso SSH Root abilitato (`PermitRootLogin yes`)
- Interprete Python 3 installato (`python3`)
- Connettività di rete raggiungibile dal Controller Homelab AI

---


Esegui questo script interattivo direttamente sulla shell del tuo nodo **Proxmox VE**. Ti permetterà di scegliere l'OS (**Debian 13** o **Ubuntu 24.04**) e personalizzare le risorse hardware (ID, RAM, CPU, Disco, Storage e Bridge).

```bash
bash -c '$(cat << "EOF"
pveam update > /dev/null 2>&1

echo "===================================================="
echo "      🚀 CREAZIONE CONTAINER LXC SANDBOX           "
echo "===================================================="

read -p "1) ID Container LXC [es. 100]: " CT_ID
while [ -z "$CT_ID" ]; do
  read -p "   --> Inserisci un ID valido: " CT_ID
done

echo -e "\n2) Scegli il Sistema Operativo:"
echo "   1) Debian 13 (Trixie)"
echo "   2) Ubuntu 24.04 (Noble)"
read -p "   Selezione [1-2, default: 1]: " OS_CHOICE
OS_CHOICE=${OS_CHOICE:-1}

read -p "3) CPU Cores [default: 2]: " CORES
CORES=${CORES:-2}

read -p "4) Memoria RAM in MB [default: 2048]: " RAM
RAM=${RAM:-2048}

read -p "5) Dimensione Disco in GB [default: 8]: " DISK
DISK=${DISK:-8}

read -p "6) Storage Proxmox [default: local-lvm]: " STORAGE
STORAGE=${STORAGE:-local-lvm}

read -p "7) Bridge di Rete [default: vmbr0]: " BRIDGE
BRIDGE=${BRIDGE:-vmbr0}

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

echo "📦 Creazione Container LXC ID $CT_ID..."
pct create "$CT_ID" "local:vztmpl/$TEMPLATE_NAME" \
  --ostype "$OS_TYPE" \
  --hostname "sandbox-ai" \
  --cores "$CORES" \
  --memory "$RAM" \
  --swap 512 \
  --storage "$STORAGE" \
  --rootfs "$STORAGE:$DISK" \
  --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
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
EOF
)'
