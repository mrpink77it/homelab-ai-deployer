# Guida Preparazione Sandbox LXC / Server Remoto

Questa guida descrive i passaggi per preparare una macchina remota o un container LXC isolato da utilizzare come **Sandbox di Esecuzione** tramite l'Opzione 4 dell'**Homelab AI Deployer**.

---

## 📋 Requisiti Minimi
Per consentire la configurazione automatica delle chiavi SSH e l'esecuzione di codice remoto tramite l'API Code Runner (`:9000`), la Sandbox deve soddisfare i seguenti requisiti:
- Server SSH attivo (`openssh-server`)
- Accesso SSH Root abilitato (`PermitRootLogin yes`)
- Interprete Python 3 installato (`python3`)

---

## 🏗️ Opzione 1: Creazione e Preparazione da Zero dalla Shell Proxmox VE

Se desideri creare un nuovo container LXC Debian dedicato direttamente dalla CLI di Proxmox VE, copia ed esegui questa sequenza sulla shell del nodo Proxmox:

> 💡 *Sostituisci `100` con l'ID desiderato per il container e adatta lo storage (`local-lvm`) o il bridge di rete (`vmbr0`) se diversi dalla tua configurazione.*

```bash
# 1. Scarica l'ultimo template Debian 12 disponibile
pveam update
TEMPLATE_NAME=$(pveam available | grep debian-12 | head -n 1 | awk '{print $2}')
pveam download local "$TEMPLATE_NAME"

# 2. Crea il container LXC Sandbox (ID: 100, RAM: 2GB, CPU: 2 Core, IP: DHCP)
pct create 100 "local:vztmpl/$TEMPLATE_NAME" \
  --ostype debian \
  --hostname sandbox-ai \
  --cores 2 \
  --memory 2048 \
  --swap 512 \
  --storage local-lvm \
  --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged 0 \
  --onboot 1

# 3. Avvia il container LXC appena creato
pct start 100

# 4. Attendi l'avvio della rete e configura SSH + Python
sleep 5
pct exec 100 -- bash -c "apt update && apt install -y openssh-server python3 && sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && systemctl restart ssh"

# 5. Stampa l'IP assegnato al container
echo -ne "\n>>> IP della Sandbox creata: "
pct exec 100 -- ip -4 addr show eth0 | grep inet | awk '{print $2}' | cut -d/ -f1
