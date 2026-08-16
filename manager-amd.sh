# ------------------------------------------------------------------------------
# Compilazione llama.cpp
# ------------------------------------------------------------------------------
compile_llama() {
    local type="$1"
    
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    
    if [[ ! -d "${LLAMA_DIR}" ]]; then
        git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
    else
        git -C "${LLAMA_DIR}" pull
    fi

    log_info "Pulizia profonda cache di compilazione..."
    rm -rf "${LLAMA_DIR}/build"
    rm -rf ~/.cache/ccache 2>/dev/null || true
    hash -r

    local gpu_profile target override env_override=""
    gpu_profile=$(get_amd_gpu_profile)
    target=$(echo "$gpu_profile" | cut -d'|' -f1)
    override=$(echo "$gpu_profile" | cut -d'|' -f2)

    log_info "Avvio compilazione llama.cpp (Backend: ${type})..."

    case "${type}" in
        "vulkan")
            log_info "Backend Vulkan selezionato. Ignoro ROCm..."
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_VULKAN=ON
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
        "rocm"|"rocm_exp")
            if ! ensure_hipcc_toolchain; then
                log_err "Interruzione compilazione. Ritorno al menu principale."
                return 1
            fi
            
            local ROCM_PREFIX="/opt/rocm"
            local ROCM_CLANG="${ROCM_PREFIX}/llvm/bin/clang"
            local ROCM_CLANGXX="${ROCM_PREFIX}/llvm/bin/clang++"
            
            local CMAKE_ROCM_FLAGS="-DGGML_HIP=ON -DAMDGPU_TARGETS=${target} -DROCM_PATH=${ROCM_PREFIX} -DCMAKE_PREFIX_PATH=${ROCM_PREFIX}/lib/cmake:${ROCM_PREFIX}/lib/x86_64-linux-gnu/cmake"
            
            # ANTI-MISMATCH: Forziamo l'uso del compilatore LLVM/Clang di ROCm sia per C che per C++
            # Risolve l'errore "-Wunreachable-code-break" generato da GCC
            export PATH="${ROCM_PREFIX}/bin:${ROCM_PREFIX}/llvm/bin:${PATH}"
            export CC="${ROCM_CLANG}"
            export CXX="${ROCM_CLANGXX}"

            if [[ "${type}" == "rocm_exp" && -n "${override}" ]]; then
                log_warn "Iniezione Hack di compatibilità: HSA_OVERRIDE_GFX_VERSION=${override}"
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
