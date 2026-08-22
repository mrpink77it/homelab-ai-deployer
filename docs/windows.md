# Homelab AI Deployer

Deployer automatico e modularizzato per ambienti AI locali su sistemi Linux (Bare-Metal, LXC/Proxmox) e **Windows 10/11 tramite WSL 2**. Permette di configurare rapidamente backend ottimizzati (`llama.cpp` con supporto CUDA per NVIDIA o Vulkan/ROCm per AMD) e interfacce web avanzate (`Ollama`, `Open WebUI`), oltre a moduli per OCR, Audio, Agenti e Vibe Coding.

---

## 🚀 Guida all'installazione su Windows (WSL 2)

Puoi eseguire l'intero stack `homelab-ai-deployer` su Windows sfruttando la potenza della tua GPU direttamente da un ambiente Linux nativo virtualizzato con WSL 2.

### Passo 1: Abilitare WSL 2
Apri **PowerShell** o **Windows Terminal** come **Amministratore** ed esegui:
```powershell
wsl --install

Se richiesto, riavvia il computer e completa la configurazione dell'utente Linux.

Passo 2: Verificare i Driver GPU su Windows
WSL 2 mappa automaticamente l'accelerazione hardware della tua GPU (NVIDIA CUDA o AMD Vulkan/ROCm) dall'host Windows verso l'interno di Linux. Assicurati semplicemente di avere i driver della scheda video aggiornati all'ultima versione su Windows.

Passo 3: Clonare ed Eseguire la Repository
Apri il terminale della tua distribuzione Linux (es. Ubuntu da WSL) ed esegui:

# Clona la repository nella tua home
cd ~
git clone [https://github.com/mrpink77it/homelab-ai-deployer.git](https://github.com/mrpink77it/homelab-ai-deployer.git)
cd homelab-ai-deployer

# Rendi eseguibili gli script
chmod +x *.sh

# Avvia il manager in base alla tua scheda video (con privilegi sudo)
sudo ./manager-nvidia.sh
# Oppure per AMD:
# sudo ./manager-amd.sh

💡 Note di Compatibilità su WSL 2
Systemd: Nelle versioni recenti di Windows 10/11, systemd è abilitato di default in WSL 2, permettendo ai manager di gestire i servizi di backend e frontend tramite i normali comandi di sistema (systemctl).

Accesso alle Interfacce Web: Puoi aprire Open WebUI direttamente dal browser del tuo host Windows digitando http://localhost:3000 (o la porta configurata), sfruttando il port-forwarding trasparente di WSL.
