#!/usr/bin/env python3
import os
import sys
import time
import json
import csv
import subprocess
import requests
import psutil
from datetime import datetime

OLLAMA_URL = "http://127.0.0.1:11434"
CSV_FILE = "ollama_benchmark_results.csv"

# --- HELPER FUNZIONI ---

def get_gpu_vram():
    """Restituisce la VRAM usata e totale in MB via nvidia-smi."""
    try:
        res = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=memory.used,memory.total", "--format=csv,noheader,nounits"],
            encoding="utf-8"
        )
        used, total = map(int, res.strip().split(','))
        return used, total
    except Exception:
        return 0, 0

def unload_models():
    """Forza lo scaricamento di tutti i modelli dalla VRAM/RAM."""
    try:
        running = requests.get(f"{OLLAMA_URL}/api/ps").json().get("models", [])
        for m in running:
            requests.post(f"{OLLAMA_URL}/api/generate", json={"model": m["name"], "keep_alive": 0})
        time.sleep(2)
    except Exception as e:
        print(f"[!] Errore unload: {e}")

def get_installed_models():
    """Lista i modelli disponibili su Ollama."""
    res = requests.get(f"{OLLAMA_URL}/api/tags").json()
    return [m["name"] for m in res.get("models", [])]

def log_to_csv(data):
    """Aggiunge i risultati in append sul file CSV."""
    file_exists = os.path.isfile(CSV_FILE)
    headers = [
        "Timestamp", "Modello", "Num_CTX", "Num_GPU_Layers", 
        "Prompt_Tok_Sec", "Gen_Tok_Sec", "VRAM_Used_MB", "VRAM_Free_MB", 
        "RAM_Used_GB", "Status"
    ]
    with open(CSV_FILE, mode="a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=headers)
        if not file_exists:
            writer.writeheader()
        writer.writerow(data)

# --- BENCHMARK RUNNER ---

def run_benchmark(model_name, num_ctx, num_gpu=None):
    """Esegue un singolo test di benchmark su un modello con parametri specifici."""
    unload_models()
    time.sleep(1)
    
    prompt = (
        "Scrivi una funzione Python per calcolare la sequenza di Fibonacci "
        "e spiegala in dettaglio inserendo commenti ed un esempio di refactoring."
    )
    
    payload = {
        "model": model_name,
        "prompt": prompt,
        "stream": False,
        "options": {
            "num_ctx": num_ctx,
        }
    }
    if num_gpu is not None:
        payload["options"]["num_gpu"] = num_gpu

    print(f"  └─ Testing CTX={num_ctx} | Layers GPU={num_gpu if num_gpu is not None else 'AUTO'}...")
    
    start_vram, total_vram = get_gpu_vram()
    
    try:
        start_time = time.time()
        resp = requests.post(f"{OLLAMA_URL}/api/generate", json=payload, timeout=180)
        
        if resp.status_code != 200:
            raise Exception(f"HTTP {resp.status_code}: {resp.text}")
            
        data = resp.json()
        
        peak_vram, _ = get_gpu_vram()
        ram_used_gb = round(psutil.virtual_memory().used / (1024**3), 2)
        
        # Calcolo Token / Secondo dai metadati di Ollama (convertendo da nanosecondi)
        eval_count = data.get("eval_count", 0)
        eval_duration = data.get("eval_duration", 1) / 1e9
        gen_tok_sec = round(eval_count / eval_duration, 2) if eval_duration > 0 else 0

        prompt_eval_count = data.get("prompt_eval_count", 0)
        prompt_eval_duration = data.get("prompt_eval_duration", 1) / 1e9
        prompt_tok_sec = round(prompt_eval_count / prompt_eval_duration, 2) if prompt_eval_duration > 0 else 0

        vram_free = total_vram - peak_vram

        res_data = {
            "Timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "Modello": model_name,
            "Num_CTX": num_ctx,
            "Num_GPU_Layers": num_gpu if num_gpu is not None else "AUTO",
            "Prompt_Tok_Sec": prompt_tok_sec,
            "Gen_Tok_Sec": gen_tok_sec,
            "VRAM_Used_MB": peak_vram,
            "VRAM_Free_MB": vram_free,
            "RAM_Used_GB": ram_used_gb,
            "Status": "OK"
        }
        log_to_csv(res_data)
        print(f"     [OK] Gen: {gen_tok_sec} t/s | Prompt: {prompt_tok_sec} t/s | VRAM Usata: {peak_vram}MB (Libera: {vram_free}MB)")
        return res_data

    except Exception as e:
        print(f"     [FAIL] Errore: {e}")
        fail_data = {
            "Timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "Modello": model_name,
            "Num_CTX": num_ctx,
            "Num_GPU_Layers": num_gpu if num_gpu is not None else "AUTO",
            "Prompt_Tok_Sec": 0, "Gen_Tok_Sec": 0,
            "VRAM_Used_MB": 0, "VRAM_Free_MB": 0,
            "RAM_Used_GB": 0, "Status": f"FAILED: {str(e)[:30]}"
        }
        log_to_csv(fail_data)
        return None

# --- GENERAZIONE GRAFICI & CONSLUSIONE ---

def generate_charts_and_report(model_name, results):
    """Genera grafici comparativi e raccomandazione finale per il modello."""
    valid_results = [r for r in results if r and r["Status"] == "OK"]
    if not valid_results:
        print("\n[!] Nessun dato valido raccolto per generare il report.")
        return

    import pandas as pd
    import matplotlib.pyplot as plt

    df = pd.DataFrame(valid_results)
    
    # Creo identificatore per la configurazione
    df['Config'] = "CTX:" + df['Num_CTX'].astype(str) + " GPU:" + df['Num_GPU_Layers'].astype(str)

    # Plot Grafici
    fig, axes = plt.subplots(1, 2, figsize=(14, 5))
    
    # Grafico 1: Token/s
    axes[0].bar(df['Config'], df['Gen_Tok_Sec'], color='skyblue')
    axes[0].set_title(f"Velocità di Generazione (t/s) - {model_name}")
    axes[0].set_ylabel("Tokens / sec")
    axes[0].tick_params(axis='x', rotation=30)

    # Grafico 2: VRAM Libera vs Usata
    axes[1].bar(df['Config'], df['VRAM_Used_MB'], label='VRAM Usata (MB)', color='salmon')
    axes[1].bar(df['Config'], df['VRAM_Free_MB'], bottom=df['VRAM_Used_MB'], label='VRAM Libera (MB)', color='lightgreen')
    axes[1].set_title(f"Uso VRAM (MB) - {model_name}")
    axes[1].set_ylabel("MB VRAM")
    axes[1].legend()
    axes[1].tick_params(axis='x', rotation=30)

    plt.tight_layout()
    chart_filename = f"benchmark_{model_name.replace(':', '_')}.png"
    plt.savefig(chart_filename)
    print(f"\n[+] Grafico comparativo salvato in: {chart_filename}")

    # Logica Raccomandazione Miglior Setup
    # Criterio: Il miglior compromesso con VRAM Libera >= 800MB per evitare OOM, ordinato per velocità t/s
    df_safe = df[df['VRAM_Free_MB'] >= 800]
    if not df_safe.empty:
        best = df_safe.sort_values(by='Gen_Tok_Sec', ascending=False).iloc[0]
    else:
        best = df.sort_values(by='Gen_Tok_Sec', ascending=False).iloc[0]

    print("\n" + "="*60)
    print(f" RACCOMANDAZIONE OTTIMALE PER: {model_name}")
    print("="*60)
    print(f" Configurazione migliore : CTX = {best['Num_CTX']} | GPU Layers = {best['Num_GPU_Layers']}")
    print(f" Velocità Generazione    : {best['Gen_Tok_Sec']} tok/s")
    print(f" Velocità Prompt Eval    : {best['Prompt_Tok_Sec']} tok/s")
    print(f" Margine VRAM Residuo    : {best['VRAM_Free_MB']} MB")
    print(f" Impatto RAM di Sistema  : {best['RAM_Used_GB']} GB")
    print("="*60 + "\n")

# --- MAIN CLI ---

def main():
    models = get_installed_models()
    if not models:
        print("[!] Nessun modello trovato su Ollama.")
        sys.exit(1)

    print("\n--- BENCHMARK OLLAMA AUTOMATIZZATO ---")
    for i, m in enumerate(models):
        print(f" [{i}] {m}")
    print(f" [{len(models)}] TESTA TUTTI I MODELLI")

    choice = input("\nSeleziona il numero del modello da testare: ").strip()
    
    if choice.isdigit():
        idx = int(choice)
        if idx == len(models):
            selected_models = models
        elif 0 <= idx < len(models):
            selected_models = [models[idx]]
        else:
            print("Scelta non valida.")
            sys.exit(1)
    else:
        print("Scelta non valida.")
        sys.exit(1)

    # Parametri da testare in matrice
    context_list = [4096, 8192, 16384]
    gpu_layers_list = [None, 20, 15]  # None = AUTO di Ollama

    for model in selected_models:
        print(f"\n==================================================")
        print(f" AVVIO BENCHMARK PER: {model}")
        print(f"==================================================")
        
        results = []
        for ctx in context_list:
            for gpu_layer in gpu_layers_list:
                res = run_benchmark(model, num_ctx=ctx, num_gpu=gpu_layer)
                if res:
                    results.append(res)
        
        generate_charts_and_report(model, results)

if __name__ == "__main__":
    main()
