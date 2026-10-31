#!/usr/bin/env bash
set -e

PROJECT_DIR="rizzo-client-multi"

echo "Creazione struttura del repository client per endpoint remoti in '$PROJECT_DIR'..."

mkdir -p "$PROJECT_DIR/rizzo_client/web"
cd "$PROJECT_DIR"

# 1. File di configurazione delle dipendenze (Leggero, senza torch o runtimes locali)
cat << 'EOF' > pyproject.toml
[project]
name = "rizzo-client-multi"
version = "0.1.0"
description = "Orchestratore per endpoint remoti OPENAPI"
readme = "README.md"
requires-python = ">=3.10"
dependencies = [
    "fastapi>=0.110.0",
    "uvicorn>=0.28.0",
    "requests>=2.31.0",
    "pydantic>=2.6.0"
]
EOF

# 2. Configurazione dei nodi e degli endpoint remoti
cat << 'EOF' > rizzo_client/config.py
import os
from typing import Dict, List, Optional
from pydantic import BaseModel

class RemoteNode(BaseModel):
    name: str
    backend: str  # "gpu1" o "gpu2"
    endpoint_url: str  # es. http://192.168.1.50:8080/v1
    ssh_host: Optional[str] = None
    ssh_user: Optional[str] = None

# Registro dei nodi configurabili via ambiente o file di configurazione
DEFAULT_NODES: List[RemoteNode] = [
    RemoteNode(
        name="GPU1",
        backend="gpu1",
        endpoint_url=os.getenv("GPU1_ENDPOINT", "http://localhost:8080/v1")
    ),
    RemoteNode(
        name="GPU2",
        backend="gpu2",
        endpoint_url=os.getenv("GPU2_ENDPOINT", "http://localhost:8081/v1")
    )
]
EOF

# 3. Client HTTP per l'interazione con gli endpoint OpenAPI e logprobs
cat << 'EOF' > rizzo_client/client.py
import requests
from typing import Dict, List, Any

class RemoteOpenAPIClient:
    def __init__(self, endpoint_url: str):
        self.endpoint_url = endpoint_url.rstrip("/")

    def evaluate_logits(self, prompt: str, candidate_tokens: List[str]) -> Dict[str, float]:
        payload = {
            "prompt": prompt,
            "max_tokens": 1,
            "temperature": 0.0,
            "logprobs": 5,
            "echo": False
        }
        
        response = requests.post(f"{self.endpoint_url}/completions", json=payload, timeout=30)
        response.raise_for_status()
        
        data = response.json()
        logprobs_data = data.get("choices", [{}])[0].get("logprobs", {})
        top_logprobs = logprobs_data.get("top_logprobs", [])
        
        result = {}
        if top_logprobs:
            latest_probs = top_logprobs[-1] if isinstance(top_logprobs, list) else top_logprobs
            for token in candidate_tokens:
                result[token] = latest_probs.get(token, -999.0)
        return result
EOF

# 4. Server FastAPI e Dashboard Web per la gestione multi-nodo
cat << 'EOF' > rizzo_client/server.py
from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse
from pydantic import BaseModel
from rizzo_client.config import DEFAULT_NODES
from rizzo_client.client import RemoteOpenAPIClient

app = FastAPI(title="Rizzo Multi-Node Client Dashboard")

class EvaluateRequest(BaseModel):
    node_name: str
    prompt: str
    candidates: list[str]

@app.get("/api/nodes")
def get_nodes():
    return [node.dict() for node in DEFAULT_NODES]

@app.post("/api/evaluate")
def evaluate(req: EvaluateRequest):
    node = next((n for n in DEFAULT_NODES if n.name == req.node_name), None)
    if not node:
        raise HTTPException(status_code=404, detail="Nodo non trovato")
    
    try:
        client = RemoteOpenAPIClient(node.endpoint_url)
        logits = client.evaluate_logits(req.prompt, req.candidates)
        return {"node": node.name, "logits": logits}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/", response_class=HTMLResponse)
def dashboard():
    return """
    <!DOCTYPE html>
    <html lang="it">
    <head>
        <meta charset="UTF-8">
        <title>Rizzo Multi-Node Dashboard</title>
        <style>
            body { font-family: sans-serif; background: #121212; color: #e0e0e0; padding: 20px; }
            .card { background: #1e1e1e; padding: 15px; margin-bottom: 15px; border-radius: 6px; }
            button { background: #bb86fc; border: none; padding: 8px 15px; color: #121212; font-weight: bold; cursor: pointer; border-radius: 4px; }
        </style>
    </head>
    <body>
        <h1>Rizzo Flow - Multi-Node Playground</h1>
        <div class="card">
            <h3>Nodi Configurati</h3>
            <ul id="node-list">Caricamento nodi...</ul>
        </div>
        <script>
            fetch('/api/nodes').then(r => r.json()).then(nodes => {
                const ul = document.getElementById('node-list');
                ul.innerHTML = nodes.map(n => `<li><b>${n.name}</b> (${n.backend}) -> <code>${n.endpoint_url}</code></li>`).join('');
            });
        </script>
    </body>
    </html>
    """
EOF

echo "Inizializzazione completata nella cartella '$PROJECT_DIR'."
echo "Per avviare la dashboard e l'orchestratore:"
echo "  cd $PROJECT_DIR"
echo "  uv run uvicorn rizzo_client.server:app --reload --port 8000"
