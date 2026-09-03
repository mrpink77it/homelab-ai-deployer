# Benchmark Automatizzato Ollama

## Requisiti
Installa le librerie Python necessarie all'interno dell'ambiente (LXC Debian/Ubuntu o host):

```bash
pip install requests psutil pandas matplotlib
```

## Funzionalità ed Output

* **Scarico automatico e isolamento:** Invia una chiamata `keep_alive: 0` prima di ogni esecuzione per liberare completamente la VRAM ed evitare che i test si influenzino a vicenda.
* **Matrice di test automatizzata:** Valuta ogni modello variando sia la finestra di contesto (`4096`, `8192`, `16384`) sia l'offloading dei layer GPU (`AUTO`, `20`, `15`).
* **Storico permanente in CSV (`ollama_benchmark_results.csv`):** Salva i dati in modalità append (`a`), registrando timestamp, modello, parametri, velocità di generazione, prompt eval, VRAM usata/libera e RAM di sistema.
* **Grafici comparativi PNG:** Per ogni modello analizzato genera un'immagine PNG (es. `benchmark_qwen2.5-coder_14b.png`) con il confronto di tok/s e l'occupazione VRAM.
* **Report di raccomandazione automatica:** Calcola il miglior compromesso garantendo una VRAM residua libera di almeno 800 MB per prevenire crash OOM in produzione.
