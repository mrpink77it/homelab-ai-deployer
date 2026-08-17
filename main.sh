# ------------------------------------------------------------------------------
# Pre-Flight Check: Dipendenze Minime per Auto-Router
# ------------------------------------------------------------------------------
ensure_router_deps() {
    local missing=()
    command -v lspci >/dev/null 2>&1 || missing+=("pciutils")
    command -v whiptail >/dev/null 2>&1 || missing+=("whiptail")

    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "\n[INFO] Installazione dipendenze di rilevamento e TUI (${missing[*]})..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1
    fi
}

ensure_router_deps
