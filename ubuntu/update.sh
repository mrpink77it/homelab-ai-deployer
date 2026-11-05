#!/usr/bin/env bash

sudo systemctl stop cluster-discovery.timer 
sudo systemctl stop llama-cuda-0.service 
sudo systemctl stop llama-cpu.service 
sudo systemctl stop llama-cpp-vulkan.service 
sudo systemctl stop llm-gateway.service

echo "Backend llama terminato."

cd /opt/homelab-ai-deployer/ && git stash && git pull && sudo chmod +x ubuntu/*.sh && cd ubuntu &&  sudo ./setup_discovery_daemon.sh && sudo ./setup_llama_cpu.sh && sudo ./setup_llama_cuda.sh && sudo ./setup_llama_vulkan.sh && sudo ./setup_cluster_gateway.sh 


px ax | grep "llama-cuda-0.service"
px ax | grep "llama-cpu.service"
px ax | grep "llama-cpp-vulkan.service" 
px ax | grep "cluster-discovery.timer" 
px ax | grep "llm-gateway.service"


echo "Back-end llama.cpp aggiornato da repo github."
echo "http://127.0.0.1:9001/"
