sudo rm -rf homelab-ai-deployer
sudo rm -rf homelab-ai-logs
sudo apt install git -y
git clone https://github.com/mrpink77it/homelab-ai-deployer.git
cd homelab-ai-deployer
sudo chmod +x main.sh manager.sh manager-amd.sh sandbox_setup.sh setup_jupyter.sh monitor.sh
sudo ./main.sh
