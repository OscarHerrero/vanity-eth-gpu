#!/usr/bin/env bash
# Vanity ETH Address Generator - Script de compilacion para Linux / macOS
# Uso: ./build.sh [ARCH=sm_XX]
#   Ejemplo: ./build.sh
#            ./build.sh ARCH=sm_86

set -e

echo "=== Vanity ETH Address Generator - Build (Linux/macOS) ==="
echo ""

# Procesar argumento ARCH si se pasa
ARCH_OVERRIDE=""
for arg in "$@"; do
    case "$arg" in
        ARCH=*)
            ARCH_OVERRIDE="${arg#ARCH=}"
            ;;
    esac
done

# 1. Verificar que nvcc esta disponible
if ! command -v nvcc &>/dev/null; then
    echo "[ERROR] nvcc no encontrado en PATH."
    echo ""
    echo "Instala CUDA Toolkit:"
    echo "  Ubuntu/Debian:"
    echo "    https://developer.nvidia.com/cuda-downloads"
    echo "    sudo apt install cuda-toolkit"
    echo ""
    echo "  Arch Linux:"
    echo "    sudo pacman -S cuda"
    echo ""
    echo "  Fedora/RHEL:"
    echo "    sudo dnf install cuda-toolkit"
    echo ""
    echo "  Despues, añade CUDA al PATH:"
    echo "    export PATH=/usr/local/cuda/bin:\$PATH"
    exit 1
fi

echo "nvcc: $(nvcc --version | grep 'release' | awk '{print $5}' | tr -d ',')"

# 2. Detectar arquitectura de la GPU
ARCH_FLAG=""
if [ -n "$ARCH_OVERRIDE" ]; then
    ARCH_FLAG="-arch=${ARCH_OVERRIDE}"
    echo "Arquitectura: ${ARCH_OVERRIDE} (manual)"
elif command -v nvidia-smi &>/dev/null; then
    COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1)
    if [ -n "$COMPUTE_CAP" ]; then
        SM_NUM="${COMPUTE_CAP//./}"
        ARCH_FLAG="-arch=sm_${SM_NUM}"
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        echo "GPU detectada: ${GPU_NAME} (compute ${COMPUTE_CAP})"
        echo "Arquitectura: sm_${SM_NUM} (auto)"
    else
        echo "[AVISO] No se pudo leer compute capability. Compilando sin -arch."
        echo "        Si hay errores, usa: ./build.sh ARCH=sm_XX"
    fi
else
    echo "[AVISO] nvidia-smi no encontrado. Compilando sin -arch."
    echo "        Si hay errores, usa: ./build.sh ARCH=sm_XX"
fi

echo ""

# 3. Compilar
CMD="nvcc -O3 ${ARCH_FLAG} -o vanity_eth src/main.cu -lcuda"
echo "Comando: ${CMD}"
echo ""

eval "$CMD"

if [ $? -eq 0 ]; then
    echo ""
    echo "=== Compilacion exitosa! ==="
    echo "Ejecutable: ./vanity_eth"
    echo ""
    echo "Uso rapido:"
    echo "  ./vanity_eth -p dead -s beef"
    echo "  ./vanity_eth -p 1337"
    echo "  ./vanity_eth -h"
else
    echo ""
    echo "[ERROR] Compilacion fallida."
    echo ""
    echo "Posibles causas:"
    echo "  - CUDA Toolkit no instalado correctamente."
    echo "  - Arquitectura incompatible: prueba con './build.sh ARCH=sm_XX'"
    echo "    Consulta la tabla de arquitecturas en el README."
    exit 1
fi
