#!/bin/bash

# Creazione cartelle organizzate
mkdir -p models/{1_LLM_Text,2_Vision_Models,3_Embeddings,4_Audio_STT_TTS}

echo "Inizio il download dei modelli LLM (Testo)..."
cd models/1_LLM_Text
wget -c --show-progress -O Qwen3.5-9B-Q4_K_M.gguf "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf"
wget -c --show-progress -O Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf "https://huggingface.co/unsloth/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
wget -c --show-progress -O Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf "https://huggingface.co/unsloth/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf"
wget -c --show-progress -O DeepSeek-R1-Distill-Llama-8B-Q4_K_M.gguf "https://huggingface.co/unsloth/DeepSeek-R1-Distill-Llama-8B-GGUF/resolve/main/DeepSeek-R1-Distill-Llama-8B-Q4_K_M.gguf"
wget -c --show-progress -O Phi-4-mini-instruct-Q4_K_M.gguf "https://huggingface.co/unsloth/Phi-4-mini-instruct-GGUF/resolve/main/Phi-4-mini-instruct-Q4_K_M.gguf"
cd ../..

echo "Inizio il download dei modelli Vision..."
cd models/2_Vision_Models
# Qwen2.5-VL
wget -c --show-progress -O Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf "https://huggingface.co/unsloth/Qwen2.5-VL-7B-Instruct-GGUF/resolve/main/Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf"
# LLaVA 1.5 + Proiettore Visivo
wget -c --show-progress -O llava-v1.5-7b-q4_k.gguf "https://huggingface.co/cjpais/llava-1.5-7b-gguf/resolve/main/llava-v1.5-7b-q4_k.gguf"
wget -c --show-progress -O llava-v1.5-7b-mmproj.gguf "https://huggingface.co/cjpais/llava-1.5-7b-gguf/resolve/main/mmproj-model-f16.gguf"
# Moondream2 + Proiettore Visivo
wget -c --show-progress -O moondream2-text-model-f16.gguf "https://huggingface.co/vikhyatk/moondream2/resolve/main/moondream2-text-model-f16.gguf"
wget -c --show-progress -O moondream2-mmproj-f16.gguf "https://huggingface.co/vikhyatk/moondream2/resolve/main/moondream2-mmproj-f16.gguf"
cd ../..

echo "Inizio il download dei modelli Embeddings..."
cd models/3_Embeddings
wget -c --show-progress -O nomic-embed-text-v1.5.Q4_K_M.gguf "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q4_K_M.gguf"
wget -c --show-progress -O bge-m3-q4_k_m.gguf "https://huggingface.co/milaboratory/bge-m3-gguf/resolve/main/bge-m3-q4_k_m.gguf"
cd ../..

echo "Inizio il download dei modelli Audio (STT & TTS)..."
cd models/4_Audio_STT_TTS
# Whisper (per Whisper.cpp)
wget -c --show-progress -O ggml-large-v3-turbo.bin "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
wget -c --show-progress -O ggml-small.bin "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
# Kokoro
wget -c --show-progress -O kokoro-v1_0.onnx "https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/kokoro-v1_0.onnx"
# Piper TTS (Voci e config in Italiano)
wget -c --show-progress -O it_IT-paola-medium.onnx "https://huggingface.co/rhasspy/piper-voices/resolve/main/it/it_IT/paola/medium/it_IT-paola-medium.onnx"
wget -c --show-progress -O it_IT-paola-medium.onnx.json "https://huggingface.co/rhasspy/piper-voices/resolve/main/it/it_IT/paola/medium/it_IT-paola-medium.onnx.json"
cd ../..

echo "🎉 Download di tutti i modelli completato con successo in ./models/"
