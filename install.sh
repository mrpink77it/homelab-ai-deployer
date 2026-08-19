apt update
apt upgrade -y
apt install git -y
rm -rf homelab-ai-deployer homelab-ai-logs
git clone https://github.com/mrpink77it/homelab-ai-deployer.git
cd homelab-ai-deployer
chmod +x *.sh
./main.sh
