#!/usr/bin/env bash
# omarchy-cachyos-overrides.sh — Restaura los ajustes de CachyOS sobre Omarchy.
#
# `omarchy update` reinstala /usr/share/omarchy con `pacman -Syu --overwrite`,
# lo que devuelve los archivos originales de Arch (drivers NVIDIA de Arch,
# post-install/pacman.sh que pisa pacman.conf). Este script vuelve a dejar los
# de CachyOS en su lugar.
#
# Lo llama /etc/pacman.d/hooks/omarchy-cachyos-overrides.hook después de cada
# transacción sobre omarchy/omarchy-settings, y se puede correr a mano:
#
#   sudo omarchy-cachyos-overrides.sh
#
# Nunca falla: si algo no se puede restaurar, avisa y sale con 0 para no
# abortar la transacción de pacman.

set -uo pipefail

SHARE_SRC="${OMARCHY_OVERRIDES_DIR:-/usr/local/share/omarchy-on-cachyos}"
OMARCHY_SHARE="${OMARCHY_SHARE:-/usr/share/omarchy}"

say() { printf '[omarchy-cachyos] %s\n' "$*"; }

# 1. nvidia.sh: el de Arch instala nvidia-580xx-dkms/linux-omarchy-nvidia-open,
#    que no existen en CachyOS; el nuestro respeta el driver de CachyOS.
if [ -f "$SHARE_SRC/nvidia.sh" ] && [ -d "$OMARCHY_SHARE/install/hardware" ]; then
    if ! cmp -s "$SHARE_SRC/nvidia.sh" "$OMARCHY_SHARE/install/hardware/nvidia.sh"; then
        install -Dm 755 "$SHARE_SRC/nvidia.sh" "$OMARCHY_SHARE/install/hardware/nvidia.sh" \
            && say "nvidia.sh de CachyOS restaurado"
    fi
fi

# 2. post-install/pacman.sh: el de Arch reescribe pacman.conf y el mirrorlist.
if [ -f "$SHARE_SRC/post-install-pacman-noop.sh" ]; then
    target="$(find "$OMARCHY_SHARE/install" -maxdepth 2 -name pacman.sh -path '*post-install*' 2>/dev/null | head -n1)"
    if [ -n "$target" ] && ! cmp -s "$SHARE_SRC/post-install-pacman-noop.sh" "$target"; then
        install -Dm 755 "$SHARE_SRC/post-install-pacman-noop.sh" "$target" \
            && say "post-install/pacman.sh neutralizado"
    fi
fi

# 3. Guardias de arranque (mkinitcpio + limine): omarchy-settings instala
#    drop-ins que rompen el initramfs systemd de CachyOS y las entradas limine.
if [ -x "$SHARE_SRC/boot-guards.sh" ]; then
    if ! "$SHARE_SRC/boot-guards.sh" --quiet; then
        say "aviso: los guardias de arranque no se pudieron verificar"
    fi
fi

# 4. Fix del singleton Color de Qt 6.12 (idempotente, no-op si ya está).
if [ -x /usr/local/bin/omarchy-qt-color-fix.sh ]; then
    /usr/local/bin/omarchy-qt-color-fix.sh --no-restart >/dev/null 2>&1 || true
fi

exit 0
