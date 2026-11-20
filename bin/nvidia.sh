#!/bin/bash
# nvidia.sh — Configuración de NVIDIA para Omarchy sobre CachyOS.
#
# Filosofía: usar el driver que CachyOS ya instaló. Solo instala uno si no hay
# ninguno, y siempre a través de chwd (la herramienta de CachyOS), nunca con los
# paquetes de Arch que trae Omarchy (nvidia-580xx-dkms, linux-omarchy-nvidia-open
# no existen en CachyOS y harían fallar todo el paso de hardware).
#
# Este archivo reemplaza /usr/share/omarchy/install/hardware/nvidia.sh y el hook
# omarchy-cachyos-overrides lo restaura después de cada update de omarchy.
#
# Nunca aborta: si algo falla, avisa y sigue (el resto del hardware importa).

say() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# Sin GPU NVIDIA no hay nada que hacer (APUs AMD/Intel: salida limpia).
if ! command -v lspci >/dev/null 2>&1; then
    say "lspci no disponible; se omite la configuración de NVIDIA"
    exit 0
fi
if ! lspci -nn -d 10de: 2>/dev/null | grep -qE "VGA|3D|Display"; then
    say "No hay GPU NVIDIA. Se omite."
    exit 0
fi

GPU_NAME="$(lspci -d 10de: 2>/dev/null | grep -E "VGA|3D|Display" | head -n1 | sed 's/.*: //')"
say "GPU NVIDIA detectada: $GPU_NAME"

# Driver ya instalado: respetarlo tal cual (incluye nvidia-open y dkms).
DRIVER="$(pacman -Qq 2>/dev/null | grep -E '^nvidia(-open|-580xx)?(-dkms|-utils)?$' | grep -E 'dkms|open' | head -n1 || true)"
if [ -z "$DRIVER" ]; then
    DRIVER="$(pacman -Qq 2>/dev/null | grep -E '^nvidia-(open-)?utils$' | head -n1 || true)"
fi

if [ -n "$DRIVER" ]; then
    say "Driver NVIDIA de CachyOS en uso: $DRIVER $(pacman -Q "$DRIVER" 2>/dev/null | awk '{print $2}')"
else
    if command -v chwd >/dev/null 2>&1; then
        say "Sin driver NVIDIA instalado; se instala con chwd (CachyOS)…"
        as_root chwd -a || warn "chwd no pudo instalar el driver; se continúa sin él"
    else
        warn "sin driver NVIDIA y sin chwd; instalá el driver desde CachyOS"
    fi
fi

# Utilidades de VA-API (diagnóstico: vainfo)
as_root pacman -S --needed --noconfirm --disable-download-timeout libva-utils >/dev/null 2>&1 \
    || warn "no se pudo instalar libva-utils"

# Variables de sesión para UWSM/Hyprland. En v4 el paso de hardware corre como
# root, así que el HOME correcto es el del usuario de escritorio.
TARGET_HOME="${HOME:-/root}"
if [ -n "${OMARCHY_INSTALL_USER:-}" ] && [ "$(id -u)" -eq 0 ]; then
    resolved="$(getent passwd "$OMARCHY_INSTALL_USER" 2>/dev/null | cut -d: -f6)"
    [ -n "$resolved" ] && TARGET_HOME="$resolved"
fi
[ -n "$TARGET_HOME" ] || TARGET_HOME="/root"

ENV_FILE="$TARGET_HOME/.config/uwsm/env"
mkdir -p "$(dirname "$ENV_FILE")"
if [ -f "$ENV_FILE" ] && grep -q "GBM_BACKEND=nvidia-drm" "$ENV_FILE" 2>/dev/null; then
    say "Variables de NVIDIA ya presentes en $ENV_FILE"
else
    cat >>"$ENV_FILE" <<'EOF'

# NVIDIA
export LIBVA_DRIVER_NAME=nvidia
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export NVD_BACKEND=direct
export MOZ_DISABLE_RDD_SANDBOX=1
export CUDA_DISABLE_PERF_BOOST=1
EOF
    say "Variables de NVIDIA escritas en $ENV_FILE"
    if [ "$(id -u)" -eq 0 ] && [ -n "${OMARCHY_INSTALL_USER:-}" ]; then
        chown -R "$OMARCHY_INSTALL_USER":"$OMARCHY_INSTALL_USER" \
            "$TARGET_HOME/.config/uwsm" 2>/dev/null || true
    fi
fi

say "Configuración de NVIDIA completa."
exit 0
