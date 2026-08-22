# Homelab AI Deployer

![Status](https://img.shields.io/badge/Status-Work_in_Progress-orange)
![Language](https://img.shields.io/badge/Language-Bash-4EAA25)
![License](https://img.shields.io/badge/License-MIT-blue)

> **`mrpink77it/homelab-ai-deployer`** is an automated, "zero-config" Bash script suite designed to configure, manage, and deploy a complete Generative AI (Inference), LLM Fine-Tuning, and native development environment on Linux machines, Bare-Metal servers, and **Proxmox LXC** containers. 

---

## 🏗️ Architecture & Hardware Compatibility

The project supports a **Multi-Backend** architecture capable of automatically detecting installed hardware and selecting the optimal software stack, including a native fallback for systems without a GPU:

```text
                               +-----------------------+
                               |        main.sh        |
                               | (Hardware Discovery)  |
                               +-----------+-----------+
                                           |
     +-------------------------------------+-------------------------------------+
     |                                     |                                     |
     v                                     v                                     v
[ NVIDIA GPU ]                        [ AMD GPU ]                         [ No GPU / CPU ]
     |                                     |                                     |
Runs manager-nvidia.sh                Runs manager-amd.sh                   Runs manager-cpu.sh
     |                                     |                                     |
 +---+---+            +--------------------+--------------------+            +---+---+
 | CUDA  |            |                    |                    |            | CPU   |
 | vLLM  |            v                    v                    v            | AVX2  |
 +-------+    [ Official ROCm ]   [ Vulkan / llama.cpp ]   [ ROCm Exp ]      +-------+
```

### Support Matrix

| Manufacturer | Architecture / Cards | Selected Backend | Notes & Performance |
| :--- | :--- | :--- | :--- |
| **NVIDIA** | GTX / RTX / Tesla (T4, A100, etc.) | **CUDA / vLLM** | Full native support, maximum throughput, and PyTorch acceleration. |
| **AMD** | RDNA 2 / RDNA 3 (RX 6000 / 7000) | **Official ROCm** | Native bare-metal support via PyTorch ROCm (`rocm-hip-sdk`). |
| **AMD** | RDNA 1 (RX 5000 / 5700 XT) | **Vulkan (llama.cpp)** | **Recommended:** Maximum stability via Vulkan API without crash/OOM risks. |
| **AMD** | RDNA 1 (RX 5700 / 5700 XT) | **Experimental ROCm** | Uses the `HSA_OVERRIDE_GFX_VERSION=10.3.0` override for PyTorch. |
| **CPU** | x86_64 / ARM64 (Intel/AMD) | **CPU (llama.cpp)** | Universal fallback. Pure inference on system RAM (dependent on AVX2/AVX512 instructions). |

---

## 🚀 Quick Start

### AI Controller Setup (Main Host)

Copy and paste this command to run the installation. Execute as root (`su`) or super user (`sudo`):

```bash
wget -q [https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/install.sh](https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/install.sh) && chmod +x install.sh && ./install.sh
```

---

## 🎛️ How Installers Work (Manager Scripts)

Based on the hardware detected by `main.sh`, the management interface (whiptail-based TUI) specific to your system will be launched. All managers offer a uniform interface but apply specific configurations under the hood.

### 🟢 NVIDIA Menu (`manager-nvidia.sh`)
* **`1) INSTALL Services`**: Full installation of proprietary drivers, CUDA Toolkit, and native deployment of Unsloth, OpenCode AI, and AI frontends.
* **`2) VERIFY Status & Dashboard`**: Real-time monitoring of `systemd` services and validation of CUDA hardware acceleration via PyTorch.
* **`3) MANAGE Models`**: Interface for automated downloading of GGUF/Safetensors models from HuggingFace repositories.
* **`4) UPDATE Components`**: Git pull and rebuild of virtual environments (`uv`) for all installed AI tools.
* **`5) CONFIGURE Sandbox`**: Helper for testing the remote API endpoint and SSH key pairing.
* **`6) UNINSTALL`**: Total purge of directories, cache, and removal of `systemd` services.

### 🔴 AMD Menu (`manager-amd.sh`)
Integrates a guided selection of the AMD software stack during installation:
* **`1) INSTALL Services`**: Requires choosing the acceleration method:
  1. *Official ROCm*: Installs `rocm-hip-sdk` (recommended for RX 6000/7000).
  2. *Vulkan (llama.cpp)*: Compiles binaries with `GGML_VULKAN=1` acceleration (maximum stability for RDNA 1).
  3. *Experimental ROCm*: Applies environmental hacks to force PyTorch support on legacy cards.
* *(The remaining options 2-6 replicate the same management, verification, and uninstallation logic as the NVIDIA manager, adapted for ROCm/Vulkan tools).*

### 🔵 CPU Menu (`manager-cpu.sh`)
Optimized version for environments without dedicated accelerators (e.g., Mini-PCs, NUCs, basic servers):
* **`1) INSTALL Services`**: Compiles the inference backend exclusively using OpenBLAS and native vector CPU instructions (AVX/AVX2). Does not install heavy GPU drivers, keeping the system lightweight.
* Offers the same model management, service status monitoring, and Sandbox pairing functions as the other managers, restricting execution to system RAM limits.

---

## 🔌 Network Ports & Systemd Services

The entire ecosystem is orchestrated natively (without Docker) to avoid overhead. Processes are isolated via `systemd` Unit files, and ports are strictly separated to prevent conflicts (e.g., `[Errno 98]` error).

| Service / Tool | Port | Systemd Daemon | Description |
| :--- | :--- | :--- | :--- |
| **AI Backend** | `8080` | `homelab-ai-backend.service` | Inference engine (`llama-server`) binding on `0.0.0.0` |
| **AI Frontend** | `3000` | `homelab-ai-frontend.service` | Open WebUI (forced `WEBUI_PORT` environment variables) |
| **Unsloth Studio** | `8888` | `unsloth-studio.service` | Dedicated interface for LLM Fine-Tuning operations |
| **JupyterLab** | `8889` | `jupyter.service` | Data Science environment (scales dynamically if port is busy) |
| **OpenCode AI** | `8000` | `opencode.service` | AI-assisted development platform |
| **Code Runner** | `9000` | `code-runner.service` | Local API Endpoint for remote execution proxy |

---

## 🛡️ Sandbox Architecture & Provisioning

The architecture separates the **AI Controller** (where models and GUIs run) from the **Sandbox Node** (separate LXC/VM), where generated code is executed in a confined context for security reasons.

```text
+---------------------------------+             SSH             +---------------------------------+
|          AI CONTROLLER          |---------------------------->|          SANDBOX LXC/VM         |
|  - OpenCode AI    (Port 8000)   |  Exec: python3 -c "..."     |  - Configured by                |
|  - Code Runner    (Port 9000)   |<----------------------------|    sandbox_setup.sh             |
+---------------------------------+       stdout / stderr       +---------------------------------+
```

### Sandbox Node Configuration

1. **Prepare the Sandbox Node:** Run the script directly in the container/VM intended to act as the isolated executor:
   ```bash
   curl -fsSL [https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/script/sandbox_setup.sh](https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/script/sandbox_setup.sh) | sudo bash
   ```
2. **Pair Controller -> Sandbox:** Use the manager (e.g., option 5 in the menu) or manually generate and send the SSH key:
   ```bash
   ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
   ssh-copy-id -i /root/.ssh/id_ed25519.pub root@<IP_SANDBOX>
   ```

---

## 💾 Storage & Directory Management

To avoid running out of space on the LXC/VM root disk, the filesystem is standardized:

* **GGUF Models (Inference)**: `/opt/homelab-ai/backend/models/`
* **HuggingFace Cache (Unsloth)**: `~/.cache/huggingface/hub`
* **Virtual Environment (Backend/Frontend)**: `/opt/homelab-ai/*/venv/`
* **Virtual Environment (Unsloth)**: `/root/unsloth_env`
* **Virtual Environment (Jupyter)**: `/opt/jupyter_env/`
* **Workspace Notebooks**: `/root/notebooks/`

---

## 🩺 Troubleshooting (FAQ)

<details>
<summary><b>Port 8080 conflict (Address already in use)</b></summary>

If Open WebUI fails to start and reports an `[Errno 98]` error, verify that `homelab-ai-frontend.service` is correctly exporting `Environment="WEBUI_PORT=3000"`. Restart with `systemctl daemon-reload && systemctl restart homelab-ai-frontend`.
</details>

<details>
<summary><b><code>nvidia-smi</code> or <code>rocm-smi</code> works in the LXC but PyTorch returns <code>False</code></b></summary>

Ensure that device node permissions inside the container are correct. Run:
```bash
chmod 666 /dev/nvidia*         # For NVIDIA
chmod 666 /dev/kfd /dev/dri/*  # For AMD
```
</details>

<details>
<summary><b>The RX 5700 XT causes a Segmentation Fault in ROCm mode</b></summary>

The RDNA 1 architecture is not officially supported by ROCm 6.x. If it proves unstable, rerun `./manager-amd.sh`, select **Uninstall**, reinstall, and choose the **Vulkan / llama.cpp** mode, which guarantees 100% stability.
</details>

<details>
<summary><b>Memory error when loading LLM models</b></summary>

For inference and fine-tuning, allocate at least **16 GB of RAM** to the LXC/VM container and enable a swap of at least **8 GB** in the Proxmox settings.
</details>

---

## 📋 System Requirements

* **Operating System**: Debian 13 (Trixie) or Ubuntu 24.04 LTS.
* **Privileges**: Root access or a user with `sudo` permissions.
* **GPU / CPU Hardware**: 
  * **NVIDIA:** CUDA-supported GPU (at least 8-12 GB VRAM recommended).
  * **AMD:** RDNA1, RDNA2, or RDNA3 GPU (RX 5000 / 6000 / 7000 series).
  * **CPU:** Modern processor with AVX2 instructions (minimum 16GB system RAM).
* **Virtualization**: Bare-Metal or **Proxmox LXC** Container (with active GPU Pass-Through).

---

## ⚠️ Disclaimer

All scripts are provided "AS IS". Although regularly tested, **you are strongly encouraged to read and understand the source code** before running it on your servers, especially in production. I assume no liability for any malfunctions or data loss.

## 📄 License

This project is distributed under the **MIT** license. You are free to use, modify, and distribute the code, provided you maintain the original attribution.

---

## 📂 Repository Structure

```text
homelab-ai-deployer/
├── docs/                               # Documentation and guides
│   ├── prepare_sandbox_baremetal.md
│   ├── prepare_sandbox_lxc.md
│   └── sandbox.md
├── script/                             # Secondary and utility scripts
│   ├── monitor.sh
│   ├── proxmox_lxc_sandbox_setup.sh
│   ├── purge-homelab-ai.sh
│   ├── sandbox_setup.sh
│   ├── setup_jupyter.sh
│   ├── purge-homelab-ai.sh                 # Root-level environment purge tool
│   └── uninstall.sh                        # Root-level service removal tool
├── README.md                           # General documentation (Italian)
├── README_ENG.md                       # General documentation (English)
├── install.sh                          # Quick start script
├── main.sh                             # Hardware detection router
├── manager-amd.sh                      # TUI for AMD Controller management
├── manager-cpu.sh                      # TUI for CPU fallback management
├── manager-fine-tuning-nvidia.sh       # TUI for Fine-Tuning on NVIDIA
└── manager-nvidia.sh                   # TUI for NVIDIA Controller management

```
