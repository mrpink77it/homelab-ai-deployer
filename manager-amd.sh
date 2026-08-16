# ------------------------------------------------------------------------------
# Compilazione llama.cpp e Orchestrazione Systemd
# ------------------------------------------------------------------------------
compile_llama() {
    local type="$1"
    
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    
    if [[ ! -d "${LLAMA_DIR}" ]]; then
        git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
    else
        git -C "${LLAMA_DIR}" pull
    fi

    rm -rf "${LLAMA_DIR}/build"

    # Estrazione Profilo GPU Dinamico
    local gpu_profile target override env_override=""
    gpu_profile=$(get_amd_gpu_profile)
    target=$(echo "$gpu_profile" | cut -d'|' -f1)
    override=$(echo "$gpu_profile" | cut -d'|' -f2)

    log_info "Avvio compilazione llama.cpp (Backend: ${type})..."
    
    # --- HACK CMAKE PER ROCM: FORZATURA PATH /OPT/ROCM ---
    # Previene l'errore "The ROCm root directory: /usr does not contain the HIP runtime"
    local ROCM_PREFIX="/opt/rocm"
    local CMAKE_ROCM_FLAGS="-DGGML_HIP=ON -DAMDGPU_TARGETS=${target} -DROCM_PATH=${ROCM_PREFIX} -DCMAKE_PREFIX_PATH=${ROCM_PREFIX}/lib/cmake"

    case "${type}" in
        "vulkan")
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_VULKAN=ON
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
        "rocm")
            # Forzatura variabili ambiente per compilatore HIP
            export PATH="${ROCM_PREFIX}/bin:${PATH}"
            export CXX="${ROCM_PREFIX}/bin/hipcc"
            
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" ${CMAKE_ROCM_FLAGS}
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
        "rocm_exp")
            # Forzatura variabili ambiente per compilatore HIP
            export PATH="${ROCM_PREFIX}/bin:${PATH}"
            export CXX="${ROCM_PREFIX}/bin/hipcc"

            if [[ -n "${override}" ]]; then
                log_warn "Applicazione Hack HSA_OVERRIDE_GFX_VERSION=${override} per architettura rilevata."
                export HSA_OVERRIDE_GFX_VERSION="${override}"
                env_override="Environment=\"HSA_OVERRIDE_GFX_VERSION=${override}\""
            fi
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" ${CMAKE_ROCM_FLAGS}
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
    esac

    log_info "Compilazione completata."
    auto_setup_systemd_service "${env_override}"
}
