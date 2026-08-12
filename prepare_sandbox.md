# Guida Preparazione Sandbox LXC / Server Remoto

Questa guida descrive i passaggi per preparare una macchina remota o un container LXC isolato da utilizzare come **Sandbox di Esecuzione** tramite l'Opzione 4 dell'**Homelab AI Deployer**.

---

## 📋 Requisiti Minimi
Per consentire la configurazione automatica delle chiavi SSH e l'esecuzione di codice remoto tramite l'API Code Runner (`:9000`), la Sandbox deve soddisfare i seguenti requisiti:
- Server SSH attivo (`openssh-server`)
- Accesso SSH Root abilitato (`PermitRootLogin yes`)
- Inteprete Python 3 installato (`python3`)

---

## 🚀 Comando Rapido di Preparazione (One-Liner)

Scegli **una** delle due modalità a seconda di dove stai eseguendo il comando:

### Modalità A: Esecuzione DIRETTAMENTE dentro la Sandbox / LXC
Se sei collegato alla shell della macchina o del container LXC destinato a far da sandbox:

```bash
apt update && apt install -y openssh-server python3 && sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && systemctl restart ssh
