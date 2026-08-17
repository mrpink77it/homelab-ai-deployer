apt install sudo
sudo apt update
sudo apt upgrade -y
sudo apt install git -y
sudo rm -rf homelab-ai-deployer homelab-ai-logs && \
git clone https://github.com/mrpink77it/homelab-ai-deployer.git && \
cd homelab-ai-deployer && \
sudo chmod +x *.sh && \
sudo ./main.sh
