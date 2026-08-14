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

## 🚀 Installazione Rapida (Shell Proxmox VE)

Apri la shell del tuo nodo Proxmox VE e incolla il seguente comando:

```bash
wget -O setup.sh https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/proxmox_lxc_sandbox_setup.sh && bash setup.sh && rm setup.sh
