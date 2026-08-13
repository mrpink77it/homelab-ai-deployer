# Homelab AI Deployer

> **`mrpink77it/homelab-ai-deployer`** is an automated ("zero-config") Bash script designed to configure, manage, and deploy a complete Generative AI, LLM Fine-Tuning, and development environment on Linux machines and **Proxmox LXC** containers.

---

## Quick Start

### AI Controller Setup (Main Host)

```bash
git clone [https://github.com/mrpink77it/homelab-ai-deployer.git](https://github.com/mrpink77it/homelab-ai-deployer.git)
cd homelab-ai-deployer
chmod +x manager.sh sandbox_setup.sh setup_jupyter.sh
sudo ./manager.sh
```

---

## Sandbox Architecture & Provisioning (`sandbox_setup.sh`)

The architecture clearly separates the **AI Controller** (where AI models, web interfaces, and GPU resources reside) from the **Sandbox Node** (an isolated LXC/VM) where AI-generated code is executed safely in a confined environment.

```text
+---------------------------------+             SSH             +---------------------------------+
|          AI CONTROLLER          |---------------------------->|          SANDBOX LXC/VM         |
|  - Unsloth Studio (Port 8888)   |   Exec: python3 -c "..."    |  - Configured by                |
|  - OpenCode AI    (Port 8000)   |                             |    sandbox_setup.sh             |
|  - Code Runner    (Port 9000)   |<----------------------------|  - Python 3 / OpenSSH            |
+---------------------------------+       stdout / stderr       +---------------------------------+
```

### Sandbox Node Setup (In 2 Steps)

To prepare a new LXC container or VM to serve as an isolated Sandbox:

#### 1. Prepare the Sandbox Node
Run the `sandbox_setup.sh` script inside the target Sandbox container/VM to install minimal dependencies (Python 3, OpenSSH Server) and configure SSH rules:

```bash
# Run on the Sandbox machine:
curl -fsSL [https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/sandbox_setup.sh](https://raw.githubusercontent.com/mrpink77it/homelab-ai-deployer/main/sandbox_setup.sh) | sudo bash
```

#### 2. Link Controller -> Sandbox
From the AI Controller, generate and send the SSH key to the Sandbox IP:

```bash
# 1. Generate SSH key on Controller (if not present)
ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519

# 2. Authorize key on the Sandbox node
ssh-copy-id -i /root/.ssh/id_ed25519.pub root@<SANDBOX_IP>

# 3. Test execution via Code Runner API (:9000)
curl -X POST http://localhost:9000/execute \
  -H "Content-Type: application/json" \
  -d '{
    "code": "import sys, platform; print(f\"Sandbox active! OS: {platform.system()} - Python: {sys.version}\")",
    "sandbox_ip": "<SANDBOX_IP>"
  }'
```

---

## `manager.sh` Menu Options

Running `./manager.sh` launches the interactive TUI menu:

* **`1) INSTALL Services`**: Full automated installation (GPU Drivers, CUDA Toolkit, Unsloth, OpenCode AI, Code Runner API).
* **`2) CHECK Status`**: Check the status of `systemd` services and GPU availability via PyTorch/CUDA.
* **`3) UPDATE Components`**: Git pull and dependency updates for OpenCode AI and Unsloth.
* **`4) CONFIGURE Sandbox`**: Interactive helper for managing and testing the remote API endpoint.
* **`5) UNINSTALL`**: Complete removal of directories, configurations, and `systemd` units.

---

## Storage & Model Management

To prevent running out of disk space on the LXC root filesystem, primary working directories and model cache locations are structured as follows:

* **HuggingFace / Unsloth Model Cache**: `~/.cache/huggingface/hub`
* **Python Virtual Environment (`uv`)**: `/root/unsloth_env`
* **JupyterLab Virtual Environment**: `/opt/jupyter_env/`
* **Notebook Working Directory**: `/root/notebooks/`
* **Code Runner Service**: `/opt/code_runner/`

---

## Service Verification & Management

After setup completes, you can verify GPU and CUDA recognition by running:

```bash
/root/unsloth_env/bin/python3 -c "import torch; print('CUDA available:', torch.cuda.is_available()); print('GPU:', torch.cuda.get_device_name(0))"
```

### Systemd Management

You can monitor and manage individual services via `systemctl`:

* **JupyterLab Server**: `systemctl status jupyter.service`
* **Unsloth Studio**: `systemctl status unsloth-studio.service`
* **OpenCode AI**: `systemctl status opencode.service`
* **Code Runner API**: `systemctl status code-runner.service`

---

## Troubleshooting (FAQ)

<details>
<summary><b><code>nvidia-smi</code> works inside LXC, but PyTorch returns <code>CUDA available: False</code></b></summary>

Ensure device permissions for `/dev/nvidia*` inside the container are correct. Run:
```bash
chmod 666 /dev/nvidia*
```
If using an **Unprivileged** container, verify UID/GID mapping between Host and LXC is configured correctly for `/dev/nvidia*` nodes.
</details>

<details>
<summary><b>How to recover a lost JupyterLab token?</b></summary>

Simply re-run the `./setup_jupyter.sh` script or execute:
```bash
/opt/jupyter_env/bin/jupyter server list
```
</details>

<details>
<summary><b>SSH connection error to the Sandbox</b></summary>

Verify that `sandbox_setup.sh` was executed on the Sandbox node and that SSH service is active (`systemctl status ssh`). Ensure the Sandbox IP is reachable from the Controller via ping/SSH.
</details>

<details>
<summary><b>Out of Memory error when loading LLM models</b></summary>

For inference and fine-tuning with Unsloth, allocate at least **16 GB RAM** and enable at least **8 GB swap** in Proxmox LXC settings.
</details>

---

## Roadmap & WIP Features

- [x] Automated CUDA + NVIDIA Container Toolkit installer for LXC
- [x] Unsloth Studio + OpenCode AI integration
- [x] Idempotent `setup_jupyter.sh` management script for JupyterLab
- [x] Isolated API Runner with SSH Sandbox execution
- [x] Dedicated `sandbox_setup.sh` provisioning script for remote nodes
- [ ] Multi-node Sandbox support (managing a pool of runner containers)
- [ ] Centralized Web Dashboard for GPU/RAM monitoring
- [ ] Optional ComfyUI integration (Generative AI Image/Video)

---

## System Requirements

* **Operating System**: Debian 12+ (Bookworm / Trixie) or Ubuntu 22.04 LTS / 24.04 LTS.
* **Privileges**: Root access or a user with `sudo` privileges.
* **GPU Hardware**: Supported NVIDIA GPU (at least 12 GB VRAM recommended for Fine-Tuning/Inference).
* **Virtualization**: Bare-Metal or **Proxmox LXC** Container (Unprivileged/Privileged with active GPU Pass-Through).

---

## Repository Structure

```text
homelab-ai-deployer/
├── README.md                     # General documentation and quick start guide
├── manager.sh                    # Main TUI script for Controller management
├── prepare_sandbox_baremetal.md # Sandbox configuration guide for Bare Metal / VMs
├── prepare_sandbox_lxc.md        # Sandbox LXC configuration guide for Proxmox VE
├── proxmox_lxc_sandbox_setup.sh # Proxmox VE script for automatic LXC creation
├── sandbox.md                    # General documentation & Sandbox requirements
├── sandbox_setup.sh              # Sandbox internal setup script (UTF-8, SSH, Python)
└── setup_jupyter.sh              # Installation, verification, and management script for JupyterLab
