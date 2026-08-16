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

    local gpu_profile target override env_override=""
    gpu_profile=$(get_amd_gpu_profile)
    target=$(echo "$gpu_profile" | cut -d'|' -f1)
    override=$(echo "$gpu_profile" | cut -d'|' -f2)

    log_info "Avvio compilazione llama.cpp (Backend: ${type})..."
    
    # --- RILEVAMENTO DINAMICO ROCM E FIX CMAKE MULTIARCH ---
    local HIPCC_BIN
    HIPCC_BIN=$(command -v hipcc || true)
    
    if [[ -z "$HIPCC_BIN" ]]; then
        log_err "Errore: hipcc non trovato. L'installazione ROCm è assente."
        return 1
    fi
    
    local ROCM_PREFIX
    ROCM_PREFIX=$(dirname $(dirname "$HIPCC_BIN"))
    
    # Fix per le distribuzioni basate su Debian (incluso Ubuntu): CMake cerca i moduli
    # nativi in lib/cmake, ma i package manager li mettono in x86_64-linux-gnu/cmake.
    if [[ "$ROCM_PREFIX" == "/usr" ]]; then
        log_warn "Rilevato stack ROCm nativo in /usr. Applicazione fix symlink per i path CMake..."
        mkdir -p /usr/lib/cmake
        for cmake_dir in hip-lang AMDDeviceLibs amd_comgr; do
            if [[ ! -e "/usr/lib/cmake/${cmake_dir}" ]] && [[ -d "/usr/lib/x86_64-linux-gnu/cmake/${cmake_dir}" ]]; then
                ln -s "/usr/lib/x86_64-linux-gnu/cmake/${cmake_dir}" "/usr/lib/cmake/${cmake_dir}"
            fi
        done
    fi

    local CMAKE_ROCM_FLAGS="-DGGML_HIP=ON -DAMDGPU_TARGETS=${target} -DROCM_PATH=${ROCM_PREFIX} -DCMAKE_PREFIX_PATH=${ROCM_PREFIX}/lib/cmake:${ROCM_PREFIX}/lib/x86_64-linux-gnu/cmake"

    case "${type}" in
        "vulkan")
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_VULKAN=ON
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
        "rocm")
            export PATH="${ROCM_PREFIX}/bin:${PATH}"
            export CXX="${HIPCC_BIN}"
            
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" ${CMAKE_ROCM_FLAGS}
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
        "rocm_exp")
            export PATH="${ROCM_PREFIX}/bin:${PATH}"
            export CXX="${HIPCC_BIN}"

            if [[ -n "${override}" ]]; then
                log_warn "Applicazione Hack HSA_OVERRIDE_GFX_VERSION=${override} su architettura rilevata."
                export HSA_OVERRIDE_GFX_VERSION="${override}"
                env_override="Environment=\"HSA_OVERRIDE_GFX_VERSION=${override}\""
            fi
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" ${CMAKE_ROCM_FLAGS}
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
    esac

    log_info "Compilazione completata con successo."
    auto_setup_systemd_service "${env_override}"
}
