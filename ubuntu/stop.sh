#!/usr/bin/env bash

sudo systemctl stop cluster-discovery.timer 
sudo systemctl stop llama-cuda-0.service 
sudo systemctl stop llama-cpu.service 
sudo systemctl stop llama-cpp-vulkan.service 
sudo systemctl stop llm-gateway.service

echo "Backend llama terminato."
