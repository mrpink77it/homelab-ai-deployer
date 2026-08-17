# ------------------------------------------------------------------------------
# Fase 3: Installazione Frontend (Open WebUI)
# ------------------------------------------------------------------------------
install_open_webui() {
    print_header "Installazione Frontend (Open WebUI)"
    
    # 1. Assicuriamoci che python3.11 sia disponibile (Open WebUI richiede versioni specifiche)
    log_info "Verifica e installazione di Python 3.11 (versione compatibile con Open WebUI)..."
    export DEBIAN_FRONTEND=noninteractive
    
    # Aggiunge il PPA di deadsnakes se non è presente, per ottenere vecchie versioni di Python su OS nuovi
    if ! command -v python3.11 &> /dev/null; then
        log_info "Python 3.11 non trovato. Aggiunta PPA deadsnakes e installazione..."
        apt-get install -y software-properties-common
        add-apt-repository -y ppa:deadsnakes/ppa
        apt-get update -y
        apt-get install -y python3.11 python3.11-venv python3.11-dev
    fi

    log_info "Creazione ambiente virtuale Python 3.11 (venv)..."
    if [[ ! -d "${WEBUI_DIR}/venv" ]]; then
        python3.11 -m venv "${WEBUI_DIR}/venv"
    fi
    
    source "${WEBUI_DIR}/venv/bin/activate"
    log_info "Aggiornamento pip e installazione/aggiornamento pacchetto open-webui..."
    pip install --upgrade pip
    pip install open-webui
    deactivate

    log_info "Generazione servizio systemd per il frontend..."
    cat <<EOF > "${FRONTEND_SERVICE_FILE}"
[Unit]
Description=Homelab AI Frontend Service (Open WebUI)
After=network.target ${SERVICE_NAME}.service

[Service]
Type=simple
User=root
WorkingDirectory=${WEBUI_DIR}
Environment="PORT=3000"
Environment="OPENAI_API_BASE_URL=http://127.0.0.1:8080/v1"
ExecStart=${WEBUI_DIR}/venv/bin/open-webui serve
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable homelab-ai-frontend
    log_info "Servizio frontend creato. In ascolto sulla porta 3000."
    pause
}
