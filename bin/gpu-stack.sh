#!/usr/bin/env bash
# gpu-stack.sh — Instala mesa/vulkan/VA-API y microcode según el hardware real.
#
# Sirve para cualquier PC: AMD (APU 8600G/760M, RDNA, GCN), Intel (iGPU, Arc),
# NVIDIA (driver gestionado aparte por nvidia.sh/chwd) y ARM.
#
# Es idempotente: solo instala lo que falte y solo si pacman puede resolverlo,
# así que un nombre que no exista en los repos no aborta nada.
#
# Uso:
#   ./gpu-stack.sh            instala lo que falte
#   ./gpu-stack.sh --check    solo informa (no instala)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=omarchy-lib.sh
. "$SCRIPT_DIR/omarchy-lib.sh"

case "${1:-}" in
    --check)
        printf '\nCPU: %s  (microcode: %s)\n' \
            "$(detect_cpu_vendor)" "$(microcode_pkg)"
        printf 'GPU: %s\n' "$(detect_gpu_vendors | tr '\n' ' ')"
        printf 'multilib: %s\n' "$(multilib_enabled && echo sí || echo no)"
        printf '\nPaquetes que instalaría:\n'
        gpu_packages | sed 's/^/  /'
        printf '\n'
        ;;
    -h|--help)
        sed -n '2,13p' "$0"
        ;;
    "")
        install_gpu_stack
        ;;
    *)
        die "opción desconocida: $1 (usá --check o --help)"
        ;;
esac
