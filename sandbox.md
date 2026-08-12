# 🧪 Guida Operativa & Architettura Sandbox (Unsloth Suite)

Questo documento descrive l'architettura, la configurazione e le modalità di test per l'esecuzione sicura del codice generato dall'AI tramite l'ambiente **Sandbox** e il servizio **Code Runner API** (Porta 9000).

---

## 1. Architettura di Sistema

L'architettura separa nettamente il nodo di controllo (dove risiedono i modelli LLM e le interfacce) dai nodi di esecuzione del codice (Sandbox):
