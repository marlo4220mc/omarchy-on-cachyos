#!/bin/bash
# Reemplazo de /usr/share/omarchy/install/post-install/pacman.sh en CachyOS.
#
# El original reescribe /etc/pacman.conf y /etc/pacman.d/mirrorlist con los de
# Omarchy: en CachyOS eso mezcla repos de Arch con los de CachyOS y deja el
# sistema en partial-upgrade (la causa típica de "rompí el sistema tras un
# update"). Esta versión no toca nada.
#
# Instalado por omarchy-on-cachyos y restaurado tras cada update de omarchy por
# /etc/pacman.d/hooks/omarchy-cachyos-overrides.hook
echo "  [skip]  post-install/pacman.sh: CachyOS conserva su pacman.conf y su mirrorlist"
