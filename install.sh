#!/bin/bash
# Proxmox AI Deployer - Bootstrap Script

export DEBIAN_FRONTEND=noninteractive

echo "🚀 Inizializzazione Proxmox AI Deployer..."

apt update
apt upgrade -yq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt install -yq sudo procps pciutils whiptail ca-certificates curl wget git build-essential mc

cd /opt
echo "📥 Clonazione del repository in corso..."
rm -rf homelab-ai-deployer homelab-ai-logs
git clone https://github.com/mrpink77it/homelab-ai-deployer.git
cd homelab-ai-deployer
chmod +x *.sh

echo "✅ Ambiente pronto. Avvio di main.sh..."
./main.sh
