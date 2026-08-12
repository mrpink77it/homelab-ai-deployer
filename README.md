# Unsloth Suite Manager 🚀

[![Shell Script](https://img.shields.io/badge/shell_script-bash-blue.svg)](https://www.gnu.org/software/bash/)
[![Linux](https://img.shields.io/badge/OS-Debian_%2F_Ubuntu-orange.svg)](https://www.debian.org/)
[![NVIDIA CUDA](https://img.shields.io/badge/NVIDIA-CUDA-green.svg)](https://developer.nvidia.com/cuda-toolkit)

Unsloth Suite Manager è una suite avanzata progettata per automatizzare la configurazione di ambienti di intelligenza artificiale su distribuzioni Debian e Ubuntu, supportando nativamente sia macchine fisiche/VM (Bare-Metal) sia container LXC (es. Proxmox VE)[cite: 1, 2].

📐 Architettura di Automazione (Controller & Sandbox)
Per garantire la massima sicurezza e stabilità durante la generazione autonoma di codice da parte dell'IA, il sistema adotta un'architettura distribuita a due nodi:

Il Controller (Nodo Principale):

Ospita Unsloth Studio (JupyterLab per il fine-tuning dei modelli) e OpenCode AI (l'interfaccia di sviluppo)[cite: 2].

Include la Code Runner API (un servizio basato su FastAPI in ascolto sulla porta 9000), che funge da coordinatore per smistare le richieste di esecuzione del codice[cite: 2].

La Sandbox (Nodo di Esecuzione):

Una seconda macchina fisica o un container LXC isolato e "usa e getta"[cite: 2].

Esegue materialmente il codice generato dall'IA inviato tramite comandi SSH sicuri autenticati da chiavi RSA[cite: 2].

🔄 Il Processo di Installazione e Configurazione
L'intero flusso operativo si suddivide in due fasi sequenziali:

Fase 1: Configurazione del Controller
Lo script di installazione principale (manager.sh) analizza l'ambiente di esecuzione (rilevando se si tratta di un container o di un sistema Bare-Metal)[cite: 2].

Configura i repository ufficiali NVIDIA e installa i driver CUDA necessari[cite: 2].

Installa Astral UV come package manager Python ad alte prestazioni per configurare l'ambiente virtuale di Unsloth[cite: 2].

Configura e attiva i servizi di sistema (systemd) per Unsloth Studio, OpenCode AI e l'API di Code Runner[cite: 2].

Fase 2: Configurazione della Sandbox e dei Servizi
Sulla seconda macchina o container designato a fare da Sandbox, viene eseguito lo script di supporto (setup_sandbox.sh), il quale installa i prerequisiti minimi (Python3 e dipendenze di base)[cite: 2].

Viene effettuato lo scambio delle chiavi SSH tra il Controller e la Sandbox per consentire l'esecuzione remota automatica e senza interruzioni[cite: 2].

📥 Esecuzione dell'Installazione
Per procedere con l'installazione automatica sulla macchina Controller, apri il terminale ed esegui il comando seguente[cite: 2]:

Bash
sudo ./manager.sh
