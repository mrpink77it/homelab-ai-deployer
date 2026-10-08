#!/usr/bin/env bash
# ==============================================================================
# Proxmox AI Deployer - LXC Factory & Container Orchestrator
# Repo: mrpink77it/homelab-ai-deployer
# Version: 2.0.0 (Dynamic Multi-GPU & Mixed Vulkan Support)
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} \$1"; }
log_ok() { echo -e "${GREEN}[OK]${NC} \$1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} \$1"; }
log_err() { echo -e "${RED}[ERROR]${NC} \$1"; }

if [ "\$EUID" -ne 0 ]; then
  log_err "Questo script deve essere eseguito come root su Proxmox VE!"
  exit 1
fi

if ! command -v pct &> /dev/null; then
  log_err "Comando 'pct' non trovato. Assicurati di eseguire questo script su un host Proxmox VE."
  exit 1
fi

# ------------------------------------------------------------------------------
# RILEVAMENTO STORAGE PROXMOX E TEMPLATE
# ------------------------------------------------------------------------------
STORAGE=\$(pvesm status | awk 'NR>1 && (\$2=="lvmthin" || \$2=="zfspool" || \$2=="dir") {print \$1; exit}')
STORAGE="\${STORAGE:-local-lvm}"

TEMPLATE_STORAGE=\$(pvesm status | awk 'NR>1 && \$2=="dir" {print \$1; exit}')
TEMPLATE_STORAGE="\${TEMPLATE_STORAGE:-local}"

UBUNTU_TEMPLATE="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"

ensure_template() {
  log_info "Verifica presenza template Ubuntu su storage '\$TEMPLATE_STORAGE'..."
  if ! pveam list "\$TEMPLATE_STORAGE" | grep -q "ubuntu-22.04"; then
    log_info "Download del template Ubuntu 22.04..."
    pveam update
    pveam download "$TEMPLATE_STORAGE" "$UBUNTU_TEMPLATE"
  fi
}

# ------------------------------------------------------------------------------
# FUNZIONE GENERICA PER CREAZIONE E CONFIGURAZIONE LXC (MULTI-GPU READY)
# ------------------------------------------------------------------------------
create_base_lxc() {
  local vmid="\$1"
  local hostname="\$2"
  local cores="\$3"
  local memory="\$4"
  local disk="\$5"
  local enable_gpu="\$6"

  if pct status "\$vmid" &>/dev/null; then
    log_warn "Container ID $vmid ($hostname) già esistente. Salto la creazione."
    return 0
  fi

  log_info "Creazione LXC CT \$vmid ($hostname) [CPU:$cores, RAM: ${memory}MB, Disk:${disk}GB]..."
  
  pct create "\$vmid" "${TEMPLATE_STORAGE}:vztmpl/${UBUNTU_TEMPLATE}" \
    --hostname "\$hostname" \
    --cores "\$cores" \
    --memory "\$memory" \
    --swap 2048 \
    --storage "\$STORAGE" \
    --rootfs "${STORAGE}:${disk}" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --ostype ubuntu \
    --unprivileged 0 \
    --features nesting=1 \
    --onboot 1

  CONF_FILE="/etc/pve/lxc/\${vmid}.conf"

  # INIEZIONE DINAMICA PASSTHROUGH MULTI-GPU (NVIDIA / AMD / INTEL / VULKAN)
  if [ "\$enable_gpu" = "true" ]; then
    log_info "Mappatura dinamica delle GPU disponibili per CT \$vmid..."
    
    # Check & Pass NVIDIA (Supporto Multi-GPU CUDA/Vulkan)
    if [ -d "/proc/driver/nvidia" ] || lspci | grep -iq "NVIDIA"; then
      cat <<EOF >> "\$CONF_FILE"

# Mappatura Passthrough NVIDIA Multi-GPU
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 237:* rwm
EOF
      for dev in /dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
        if [ -e "\$dev" ]; then
          echo "lxc.mount.entry: $dev${dev#/} none bind,optional,create=file" >> "\$CONF_FILE"
        fi
      done
    fi

    # Check & Pass AMD / Intel (DRI + KFD per ROCm Multi-GPU e Vulkan)
    if lspci | grep -i "vga\|3d\|display" | grep -E -iq "AMD|Radeon|Intel" || [ -d "/sys/module/amdgpu" ]; then
      cat <<EOF >> "\$CONF_FILE"

# Mappatura Passthrough DRI & ROCm KFD (AMD / Intel / Vulkan)
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 239:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
      if [ -e "/dev/kfd" ]; then
        echo "lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file" >> "\$CONF_FILE"
      fi
    fi
  fi

  pct start "\$vmid"
  sleep 3

  # Setup dipendenze base interne al container
  pct exec "\$vmid" -- bash -c "apt update && apt install -y curl wget git sudo python3 python3-pip openssh-server"
  
  # Allineamento Driver NVIDIA nel Container (se presenti schede NVIDIA sull'host)
  if [ "\$enable_gpu" = "true" ] && [ -f /proc/driver/nvidia/version ]; then
    HOST_DRIVER_VER=\$(awk '/NVRM version:/ {print \$8}' /proc/driver/nvidia/version)
    log_info "Allineamento Driver NVIDIA $HOST_DRIVER_VER dentro il CT$vmid..."
    pct exec "\$vmid" -- bash -c "cd /tmp && wget -q https://us.download.nvidia.com/XFree86/Linux-x86_64/${HOST_DRIVER_VER}/NVIDIA-Linux-x86_64-${HOST_DRIVER_VER}.run && chmod +x NVIDIA-Linux-x86_64-${HOST_DRIVER_VER}.run && ./NVIDIA-Linux-x86_64-${HOST_DRIVER_VER}.run --silent --no-kernel-modules && rm -f NVIDIA-Linux-x86_64-*.run"
  fi

  log_ok "Container $vmid ($hostname) creato e avviato con successo!"
}

# ------------------------------------------------------------------------------
# DEPLOYMENT DEI SINGOLI CONTAINER SPECIFICI
# ------------------------------------------------------------------------------
deploy_ct99_orchestrator() {
  create_base_lxc 99 "ai-orchestrator" 2 2048 16 "false"
  log_info "Installazione Orchestrator (Streamlit/FastAPI) su CT 99..."
  pct exec 99 -- bash -c "pip3 install --quiet streamlit fastapi uvicorn paramiko requests"
  log_ok "CT 99 (Orchestrator) pronto sulla porta 8501."
}

deploy_ct100_llm_worker() {
  create_base_lxc 100 "ai-llm-worker" 4 8192 32 "true"
  log_info "Installazione Ollama / LLM Worker su CT 100..."
  pct exec 100 -- bash -c "curl -fsSL https://ollama.com/install.sh | sh"
  log_ok "CT 100 (LLM Worker) pronto sulla porta 11434."
}

deploy_ct101_agent() {
  create_base_lxc 101 "ai-agent-coder" 4 4096 20 "false"
  log_info "Configurazione chiavi SSH per Agente Coder su CT 101..."
  pct exec 101 -- bash -c "mkdir -p /root/.ssh && ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519"
  log_ok "CT 101 (Agente Coder) pronto."
}

deploy_ct102_decisore() {
  create_base_lxc 102 "ai-decisore-rizzo" 2 2048 16 "true"
  log_info "Installazione Rizzo Flow su CT 102..."
  pct exec 102 -- bash -c "git clone https://github.com/Rizzo-AI-Academy/rizzo-flow /opt/rizzo-flow 2>/dev/null || true"
  pct exec 102 -- bash -c "cd /opt/rizzo-flow && pip3 install --quiet ."
  log_ok "CT 102 (Decisore - Rizzo Flow) pronto."
}

deploy_ct103_trainer() {
  create_base_lxc 103 "ai-trainer-soup" 4 4096 30 "true"
  log_info "Installazione Soup CLI Fine-Tuning su CT 103..."
  pct exec 103 -- bash -c "pip3 install --quiet pipx && pipx ensurepath && pipx install 'soup-cli[all]'"
  log_ok "CT 103 (Trainer - Soup CLI) pronto."
}

deploy_ct104_biblioteca() {
  create_base_lxc 104 "ai-rag-library" 2 409
