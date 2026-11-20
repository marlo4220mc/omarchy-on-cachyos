#!/usr/bin/env bash
# install-omarchy-on-cachyos.sh — Instala Omarchy (con la capa en Español/omarchy-es) en CachyOS
#
# Soporta Omarchy v3.x (clon de fuente) y v4.x (paquetes pacman), aplica los
# parches de compatibilidad con CachyOS, los guardias de arranque, el stack
# gráfico que corresponda al hardware real, y al final la capa de idioma
# "Omarchy en Español" desde el repo marlo4220mc/omarchy-es.
#
# Uso:
#   ./install-omarchy-on-cachyos.sh              instala (pide confirmaciones)
#   ./install-omarchy-on-cachyos.sh --check      solo informa el estado del sistema
#   ./install-omarchy-on-cachyos.sh --help
#   ./install-omarchy-on-cachyos.sh --fix-qt     solo el fix de Qt 6.12
#   ./install-omarchy-on-cachyos.sh --fix-mirrors  solo reordena los mirrors
#
# Variables de entorno:
#   OMARCHY_YES=1              sin preguntas (instalación desatendida)
#   OMARCHY_USER_NAME=usuario  usuario de escritorio
#   OMARCHY_USER_EMAIL=email   email para git
#   OMARCHY_LOG=archivo        log (por defecto ~/omarchy-on-cachyos-FECHA.log)
#   OMARCHY_SKIP_PREFLIGHT=1   ignora los avisos bloqueantes del preflight
#   OMARCHY_SKIP_HARDWARE=1    no corre el paso de hardware de Omarchy
#   OMARCHY_ALLOW_ROOT=1       permite ejecutar como root (no recomendado)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARCHY_DIR="$SCRIPT_DIR/../../omarchy"
ES_REPO_URL="https://github.com/marlo4220mc/omarchy-es"
OMARCHY_SHARE="/usr/share/omarchy"

# OMARCHY_YES=1 evita las pausas interactivas (instalación desatendida por SSH).
ASSUME_YES="${OMARCHY_YES:-0}"

if [ ! -f "$SCRIPT_DIR/omarchy-lib.sh" ]; then
    echo "Error: falta $SCRIPT_DIR/omarchy-lib.sh (cloná el repo completo)." >&2
    exit 1
fi
# shellcheck source=omarchy-lib.sh
. "$SCRIPT_DIR/omarchy-lib.sh"

# ============================================================================
# Helpers
# ============================================================================

# Instala el fix de Qt 6.12 + su hook de pacman y lo aplica ahora.
install_qt_color_fix() {
    if [ ! -f "$SCRIPT_DIR/omarchy-qt-color-fix.sh" ]; then
        skip "omarchy-qt-color-fix.sh no existe en este repo"
        return 0
    fi
    as_root install -m 755 "$SCRIPT_DIR/omarchy-qt-color-fix.sh" \
        /usr/local/bin/omarchy-qt-color-fix.sh
    as_root install -Dm 644 "$SCRIPT_DIR/omarchy-qt-color-fix.hook" \
        /etc/pacman.d/hooks/omarchy-qt-color-fix.hook
    as_root /usr/local/bin/omarchy-qt-color-fix.sh \
        || aviso "el fix de Qt 6.12 no se pudo aplicar (se reintenta tras el próximo update)"
    ok "fix Qt 6.12 + hook de pacman instalados"
}

# Instala el reordenador de mirrors (script + servicio + drop-in + hook).
install_mirror_order() {
    if [ ! -f "$SCRIPT_DIR/cachyos-mirror-order.sh" ]; then
        skip "cachyos-mirror-order.sh no existe en este repo"
        return 0
    fi
    as_root install -m 755 "$SCRIPT_DIR/cachyos-mirror-order.sh" \
        /usr/local/bin/cachyos-mirror-order.sh
    as_root install -Dm 644 "$SCRIPT_DIR/omarchy-mirror-order.service" \
        /etc/systemd/system/omarchy-mirror-order.service
    as_root install -Dm 644 "$SCRIPT_DIR/omarchy-mirror-order.hook" \
        /etc/pacman.d/hooks/omarchy-mirror-order.hook
    as_root install -Dm 644 "$SCRIPT_DIR/cachyos-rate-mirrors.service.d/omarchy-mirror-order.conf" \
        /etc/systemd/system/cachyos-rate-mirrors.service.d/omarchy-mirror-order.conf
    as_root systemctl daemon-reload || true
    as_root /usr/local/bin/cachyos-mirror-order.sh \
        || aviso "no se pudo medir/reordenar mirrors ahora (se hará tras cachyos-rate-mirrors)"
    ok "reordenador de mirrors instalado"
}

# Deja en el sistema los archivos que tienen que sobrevivir a `omarchy update`:
# nvidia.sh propio, post-install/pacman.sh neutralizado, guardias de arranque y
# el hook que los restaura tras cada actualización de omarchy.
install_system_overrides() {
    local share="/usr/local/share/omarchy-on-cachyos"

    msg "Instalando los ajustes permanentes de CachyOS sobre Omarchy…"
    as_root install -Dm 755 "$SCRIPT_DIR/omarchy-cachyos-overrides.sh" \
        /usr/local/bin/omarchy-cachyos-overrides.sh
    as_root install -Dm 644 "$SCRIPT_DIR/omarchy-cachyos-overrides.hook" \
        /etc/pacman.d/hooks/omarchy-cachyos-overrides.hook
    as_root install -Dm 755 "$SCRIPT_DIR/boot-guards.sh" "$share/boot-guards.sh"
    as_root install -Dm 755 "$SCRIPT_DIR/nvidia.sh" "$share/nvidia.sh"
    as_root install -Dm 644 "$SCRIPT_DIR/post-install-pacman-noop.sh" \
        "$share/post-install-pacman-noop.sh"
    as_root /usr/local/bin/omarchy-cachyos-overrides.sh \
        || aviso "el hook de overrides devolvió un error (los archivos igual quedaron instalados)"
    ok "ajustes permanentes instalados (se restauran tras cada update de omarchy)"
}

# En una VM instala las guest tools; en un equipo real no hace nada.
install_guest_tools() {
    local virt
    virt="$(systemd-detect-virt 2>/dev/null || true)"
    case "$virt" in
        vmware)
            msg "Virtualización detectada: VMware"
            if ! pkg_installed open-vm-tools; then
                as_root pacman -S --needed --noconfirm --disable-download-timeout \
                    open-vm-tools || aviso "no se pudo instalar open-vm-tools"
            fi
            if pkg_installed open-vm-tools; then
                as_root systemctl enable --now vmtoolsd.service 2>/dev/null || true
                ok "open-vm-tools activo (vmtoolsd)"
            fi
            ;;
        kvm|qemu)
            msg "Virtualización detectada: QEMU/KVM"
            if ! pkg_installed qemu-guest-agent; then
                as_root pacman -S --needed --noconfirm --disable-download-timeout \
                    qemu-guest-agent || true
            fi
            pkg_installed qemu-guest-agent \
                && as_root systemctl enable --now qemu-guest-agent.service 2>/dev/null || true
            ;;
        *)
            skip "sin guest tools que instalar (${virt:-bare metal})"
            ;;
    esac
    return 0
}

# Pide un dato solo si no vino por entorno y hay terminal; si no, usa el default.
ask_value() {
    local prompt="$1" default="$2" answer=""
    if [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then
        printf '%s' "$default"
        return 0
    fi
    read -r -p "$prompt [$default]: " answer || true
    printf '%s' "${answer:-$default}"
}

# patch <file> <detect-regex> <descripción> <sed-expression>
#   archivo ausente   -> [skip]  y sigue
#   patrón ausente    -> [aviso] y sigue (upstream cambió)
#   patrón presente   -> [ok]    y aplica el sed
patch() {
    local file="$1" detect="$2" desc="$3" sedexpr="$4"

    if [ ! -f "$file" ]; then
        skip "$desc -- $file no existe en esta versión"
        return 0
    fi
    if ! grep -qE -- "$detect" "$file"; then
        aviso "$desc -- upstream lo cambió, patrón no encontrado en $file"
        return 0
    fi
    sed -i -E "$sedexpr" "$file"
    ok "$desc"
}

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
}

# ============================================================================
# Argumentos (después de definir las funciones que usan)
# ============================================================================

case "${1:-}" in
    --help|-h)
        usage
        exit 0
        ;;
    --fix-qt)
        if [ ! -f "$SCRIPT_DIR/omarchy-qt-color-fix.sh" ]; then
            die "$SCRIPT_DIR/omarchy-qt-color-fix.sh no existe"
        fi
        msg "Aplicando fix del singleton Color de Qt 6.12 (omarchy#14469)…"
        sudo_init
        install_qt_color_fix
        msg "Listo."
        exit 0
        ;;
    --fix-mirrors)
        if [ ! -f "$SCRIPT_DIR/cachyos-mirror-order.sh" ]; then
            die "$SCRIPT_DIR/cachyos-mirror-order.sh no existe"
        fi
        msg "Instalando el reordenador de mirrors…"
        sudo_init
        install_mirror_order
        msg "Listo."
        exit 0
        ;;
    --check)
        if preflight_report; then
            msg ""
            msg "Estado: listo para instalar."
            exit 0
        fi
        msg ""
        msg "Estado: hay avisos (ver arriba)."
        exit 1
        ;;
    "")
        ;;
    *)
        die "opción desconocida: $1 (usá --help)"
        ;;
esac

# ============================================================================
# Log: todo queda en un archivo para poder revisarlo después
# ============================================================================

if [ -z "${OMARCHY_LOG:-}" ]; then
    OMARCHY_LOG="${HOME:-/tmp}/omarchy-on-cachyos-$(date +%Y%m%d-%H%M%S).log"
fi
if touch "$OMARCHY_LOG" 2>/dev/null; then
    OMARCHY_LOG="$(cd "$(dirname "$OMARCHY_LOG")" && pwd)/$(basename "$OMARCHY_LOG")"
    exec > >(tee -a "$OMARCHY_LOG") 2>&1
    msg "Log de la instalación: $OMARCHY_LOG"
else
    aviso "no se pudo crear el log en $OMARCHY_LOG (se sigue sin log)"
    OMARCHY_LOG=""
fi

# ============================================================================
# Preflight
# ============================================================================

if [ "${OMARCHY_SKIP_PREFLIGHT:-0}" != "1" ]; then
    if ! preflight_report; then
        msg ""
        die "corregí los avisos de arriba y volvé a intentar (OMARCHY_SKIP_PREFLIGHT=1 para ignorarlos)"
    fi
fi

# ============================================================================
# sudo
# ============================================================================

sudo_init
trap 'sudo_stop' EXIT

# ============================================================================
# Omarchy: código/paquetes
# ============================================================================

msg ""
msg "Obteniendo el código de Omarchy…"
if [ -f "$SCRIPT_DIR/fetch-omarchy.sh" ]; then
    chmod +x "$SCRIPT_DIR/fetch-omarchy.sh"
    "$SCRIPT_DIR/fetch-omarchy.sh"
else
    msg "fetch-omarchy.sh no existe; clonando la rama por defecto…"
    git clone https://www.github.com/basecamp/omarchy "$OMARCHY_DIR"
fi

[ -d "$OMARCHY_DIR" ] || die "no se pudo obtener Omarchy en $OMARCHY_DIR"

# La versión elegida en fetch-omarchy.sh se pierde si ese script corre como
# subproceso (export no vuelve al padre), así que fetch deja un archivo y acá
# se lee. Sin archivo, se deduce del propio clon: v3 trae install.sh, v4 no.
OMARCHY_VERSION_MAJOR="${OMARCHY_VERSION_MAJOR:-}"
if [ -z "$OMARCHY_VERSION_MAJOR" ] && [ -f "$OMARCHY_DIR/.cachyos-omarchy-version" ]; then
    OMARCHY_VERSION_MAJOR="$(tr -dc '0-9' < "$OMARCHY_DIR/.cachyos-omarchy-version" | head -c 1)"
fi
if [ "$OMARCHY_VERSION_MAJOR" != "3" ] && [ "$OMARCHY_VERSION_MAJOR" != "4" ]; then
    if [ -f "$OMARCHY_DIR/install.sh" ]; then
        OMARCHY_VERSION_MAJOR="3"
    else
        OMARCHY_VERSION_MAJOR="4"
    fi
fi
msg "Omarchy detectado: v${OMARCHY_VERSION_MAJOR}.x"

# AUR helper: Omarchy usa yay, y CachyOS publica yay (y paru) en su repo, así
# que se instala el binario. Compilar yay con makepkg pide la contraseña de sudo
# a mitad de la instalación y deja colgada una corrida desatendida; queda como
# último recurso.
if [ -z "$(aur_helper)" ]; then
    msg "Instalando yay desde los repos de CachyOS…"
    as_root pacman -S --needed --noconfirm --disable-download-timeout yay \
        || aviso "yay no está en los repos; se intenta con paru"
fi
if [ -z "$(aur_helper)" ]; then
    msg "yay no está en los repos. Instalando paru…"
    as_root pacman -S --needed --noconfirm --disable-download-timeout paru \
        || aviso "paru tampoco está en los repos; se compila yay"
fi
if [ -z "$(aur_helper)" ]; then
    msg "Ni yay ni paru están en los repos. Compilando yay…"
    as_root pacman -S --needed --noconfirm --disable-download-timeout git base-devel
    YAY_TMP="$(mktemp -d /tmp/yay-build.XXXXXX)"
    git clone --depth 1 https://aur.archlinux.org/yay.git "$YAY_TMP/yay"
    ( cd "$YAY_TMP/yay" && makepkg -si --noconfirm )
    rm -rf "$YAY_TMP"
    [ -n "$(aur_helper)" ] || die "no se pudo instalar yay"
    ok "yay instalado"
else
    skip "AUR helper disponible ($(aur_helper))"
fi

# Repo [omarchy] + llave (idempotente, tolerante a keyserver caído)
ensure_omarchy_repo

# Actualización completa: con repos mezclados, un -Sy sin -u deja partial upgrade
msg "Actualizando el sistema (pacman -Syu)…"
as_root pacman -Syu --noconfirm --disable-download-timeout \
    || die "pacman -Syu falló; revisá el log y reintentá"

# ============================================================================
# Guardias de arranque ANTES de instalar omarchy-settings
# ============================================================================

msg ""
msg "Instalando guardias de arranque (mkinitcpio + limine)…"
chmod +x "$SCRIPT_DIR/boot-guards.sh"
"$SCRIPT_DIR/boot-guards.sh" || aviso "los guardias de arranque devolvieron un error"

# La config de SDDM de CachyOS choca con el autologin de la sesión UWSM.
# Se aparta (no se borra) para poder volver atrás.
if [ -f /etc/sddm.conf ]; then
    msg "Apartando /etc/sddm.conf (autologin de UWSM)…"
    as_root mv /etc/sddm.conf "/etc/sddm.conf.bak-omarchy-$(date +%Y%m%d)" \
        || aviso "no se pudo apartar /etc/sddm.conf"
fi

install_guest_tools

# ============================================================================
# Datos del usuario
# ============================================================================

msg ""
OMARCHY_USER_NAME="${OMARCHY_USER_NAME:-$(ask_value 'Usuario de escritorio' "$(id -un)")}"
if [ -z "$OMARCHY_USER_NAME" ] || ! getent passwd "$OMARCHY_USER_NAME" >/dev/null; then
    die "el usuario '$OMARCHY_USER_NAME' no existe en este sistema"
fi
export OMARCHY_USER_NAME

OMARCHY_USER_EMAIL="${OMARCHY_USER_EMAIL:-$(ask_value 'Email para git' "$OMARCHY_USER_NAME@localhost")}"
export OMARCHY_USER_EMAIL

# ============================================================================
# v3: instalación desde fuente (flujo original + parches)
# ============================================================================

install_v3() {
    cd "$OMARCHY_DIR"

    # Quitar tldr para no chocar con tealdeer
    # ([[:space:]] en vez de \t: grep -E no interpreta \t como tab)
    patch install/omarchy-base.packages '^[[:space:]]*tldr[[:space:]]*$' \
        "quitar tldr (choca con tealdeer)" \
        '/^[[:space:]]*tldr[[:space:]]*$/d'

    # omarchy-update-restart: solo versiones viejas comparan `pacman -Q linux`
    if [ -f bin/omarchy-update-restart ]; then
        if grep -qF 'pacman -Q linux' bin/omarchy-update-restart; then
            sed -i "s/ | sed 's\/-arch\/\\\\\\.arch\/'//" bin/omarchy-update-restart
            sed -i "s/'{print \$2}'/'{print \$2 \"-\" \$1}' | sed 's\/-linux\/\/'/" bin/omarchy-update-restart
            sed -i '/linux-cachyos/ ! s/pacman -Q linux/pacman -Q linux-cachyos/' bin/omarchy-update-restart
            ok "omarchy-update-restart -> cachyos"
        else
            ok "omarchy-update-restart ya es agnóstico del kernel"
        fi
    else
        skip "bin/omarchy-update-restart no existe en esta versión"
    fi

    # Quitar pacman.sh del preflight (pisa la config de CachyOS)
    patch install/preflight/all.sh 'run_logged \$OMARCHY_INSTALL/preflight/pacman\.sh' \
        "quitar pacman.sh de preflight/all.sh" \
        '/run_logged \$OMARCHY_INSTALL\/preflight\/pacman\.sh/d'

    # nvidia.sh propio, respetuoso del driver de CachyOS
    if [ -f install/config/hardware/nvidia.sh ]; then
        cp "$SCRIPT_DIR/nvidia.sh" install/config/hardware/nvidia.sh
        chmod +x install/config/hardware/nvidia.sh
        ok "nvidia.sh de CachyOS"
    else
        skip "install/config/hardware/nvidia.sh no existe en esta versión"
    fi

    # Symlinks idempotentes en omarchy-ai-skill.sh
    patch install/config/omarchy-ai-skill.sh '\bln -s\b' \
        "omarchy-ai-skill.sh: symlinks idempotentes" \
        's/\bln -s\b/ln -sfn/g'

    # Quitar plymouth.sh / limine-snapper.sh / alt-bootloaders.sh del login
    patch install/login/all.sh 'run_logged \$OMARCHY_INSTALL/login/plymouth\.sh' \
        "quitar plymouth.sh" \
        '/run_logged \$OMARCHY_INSTALL\/login\/plymouth\.sh/d'
    patch install/login/all.sh 'run_logged \$OMARCHY_INSTALL/login/limine-snapper\.sh' \
        "quitar limine-snapper.sh" \
        '/run_logged \$OMARCHY_INSTALL\/login\/limine-snapper\.sh/d'
    patch install/login/all.sh 'run_logged \$OMARCHY_INSTALL/login/alt-bootloaders\.sh' \
        "quitar alt-bootloaders.sh" \
        '/run_logged \$OMARCHY_INSTALL\/login\/alt-bootloaders\.sh/d'

    # Quitar pacman.sh del post-install (pisa pacman.conf y mirrorlist)
    patch install/post-install/all.sh 'run_logged \$OMARCHY_INSTALL/post-install/pacman\.sh' \
        "quitar pacman.sh de post-install/all.sh" \
        '/run_logged \$OMARCHY_INSTALL\/post-install\/pacman\.sh/d'

    # NetworkManager con backend iwd
    if [ -f install/config/hardware/network.sh ]; then
        cat >> install/config/hardware/network.sh << 'NETEOF'

# Desactivar wpa_supplicant para no chocar con iwd
sudo systemctl disable --now wpa_supplicant.service 2>/dev/null

# NetworkManager con backend iwd
if ! grep -q "wifi.backend=iwd" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
  sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null << EOF

[device]
wifi.backend=iwd
EOF
fi
NETEOF
        ok "backend iwd + wpa_supplicant desactivado"
    else
        skip "install/config/hardware/network.sh no existe en esta versión"
    fi

    # Fijar walker al repo de omarchy
    if [ -f install/config/walker-elephant.sh ]; then
        sed -i '1a\
# Fijar walker al repo de omarchy para evitar el conflicto con CachyOS\
if ! grep -q "^IgnorePkg.*walker" /etc/pacman.conf 2>/dev/null; then\
  if grep -q "^IgnorePkg" /etc/pacman.conf; then\
    sudo sed -i '"'"'s/^IgnorePkg = \\(.*\\)/IgnorePkg = \\1 walker/'"'"' /etc/pacman.conf\
  else\
    sudo sed -i '"'"'/^\\[options\\]/a IgnorePkg = walker'"'"' /etc/pacman.conf\
  fi\
fi\
' install/config/walker-elephant.sh
        ok "walker fijado al repo de omarchy"
    else
        skip "install/config/walker-elephant.sh no existe en esta versión"
    fi

    # mise para bash y fish
    patch config/uwsm/env '^omarchy-cmd-present mise && eval' \
        "mise: activar en bash y fish" \
        's|^omarchy-cmd-present mise && eval "\$\(mise activate bash( --shims)?\)"$|if [ "$SHELL" = "/bin/bash" ] \&\& command -v mise \&> /dev/null; then\n  eval "$(mise activate bash\1)"\nelif [ "$SHELL" = "/bin/fish" ] \&\& command -v mise \&> /dev/null; then\n  mise activate fish\1 \| source\nfi|'

    # Permitir CachyOS vaciando el loop de guardia de derivadas
    patch install/preflight/guard.sh '^for marker in .*; do$' \
        "permitir CachyOS en la guardia de derivadas" \
        's|^for marker in .*; do$|for marker in; do # CachyOS: derivadas permitidas por omarchy-on-cachyos|'

    # stty sin TTY no debe abortar
    patch install/helpers/presentation.sh 'TERM_SIZE=\$\(stty size 2>/dev/null </dev/tty\)' \
        "presentation.sh a prueba de headless" \
        's#TERM_SIZE=\$\(stty size 2>/dev/null </dev/tty\)#TERM_SIZE=$(stty size 2>/dev/null </dev/tty || true)#'

    # Copiar la instalación a ~/.local/share/omarchy
    mkdir -p ~/.local/share/omarchy
    cp -r . ~/.local/share/omarchy
    cd ~/.local/share/omarchy

    msg ""
    msg "Ajustes aplicados para CachyOS (v3):"
    msg "  1. Repo [omarchy] en pacman.conf"
    msg "  2. tldr fuera del listado (se usa tealdeer)"
    msg "  3. pacman.sh de preflight y post-install desactivados (no se pisa pacman.conf)"
    msg "  4. nvidia.sh respetuoso del driver de CachyOS"
    msg "  5. plymouth.sh / limine-snapper.sh / alt-bootloaders.sh fuera del login"
    msg "  6. /etc/sddm.conf apartado (autologin UWSM)"
    msg "  7. Guardias de arranque (mkinitcpio + limine)"
    msg "  8. NetworkManager con backend iwd"
    msg "  9. walker fijado al repo de omarchy"
    msg " 10. CachyOS permitido como destino"
    msg " 11. Instalador independiente de TTY"
    msg " 12. mise en bash y fish"
    msg ""
    if [ "$ASSUME_YES" != "1" ]; then
        msg "Enter para iniciar la instalación de Omarchy…"
        read -r || true
    fi

    chmod +x install.sh
    TERM=xterm-256color script -qec './install.sh' /dev/null

    # Stack gráfico/CPU + ajustes permanentes + guards de actualización
    install_gpu_stack
    install_system_overrides
    install_qt_color_fix
    install_mirror_order

    # Capa en español (solo si el repo la trae: el mismo instalador sirve para
    # el fork base omarchy-on-cachyos, que no incluye la traducción).
    if [ -f "$SCRIPT_DIR/apply-es-layer.sh" ]; then
        msg ""
        msg "Aplicando la capa Omarchy en Español (omarchy-es)…"
        chmod +x "$SCRIPT_DIR/apply-es-layer.sh"
        "$SCRIPT_DIR/apply-es-layer.sh" "$ES_REPO_URL" "$OMARCHY_USER_NAME" \
            || aviso "no se pudo aplicar la capa en español"
    else
        skip "capa en español no incluida en este repo"
    fi
}

# ============================================================================
# v4: instalación por paquetes (pacman + configuración)
# ============================================================================

# La configuración de sistema se corre paso por paso (ver el driver más abajo),
# así un script que falla no corta los siguientes.
apply_system_config() {
    if [ ! -f "$OMARCHY_SHARE/install/helpers/logging.sh" ]; then
        aviso "no existe $OMARCHY_SHARE/install/helpers/logging.sh; se omite la config de sistema"
        return 0
    fi
    local driver
    driver="$(mktemp /tmp/omarchy-apply-cachyos.XXXXXX.sh)"
    chmod 600 "$driver"
    cat > "$driver" << 'APPLYEOF'
#!/bin/bash
# Configuración de sistema de Omarchy para CachyOS.
# Corre cada paso por separado: un fallo se informa y no aborta el resto.
set -uo pipefail
export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
export OMARCHY_INSTALL="${OMARCHY_PATH}/install"
export OMARCHY_INSTALL_USER="${OMARCHY_INSTALL_USER:-}"
export OMARCHY_INSTALL_LOG_FILE="/var/log/omarchy-install.log"
export OMARCHY_FIRST_INSTALL="0"
export OMARCHY_UPGRADE="0"
export PATH="${OMARCHY_PATH}/bin:${PATH}"

source "${OMARCHY_INSTALL}/helpers/logging.sh"
start_install_log

run_install_list() {
    local list="$1"; shift
    local -a omit=("$@")
    local line path base o skip_it
    if [ ! -f "$list" ]; then
        echo "  [skip]  $(basename "$list") no existe"
        return 0
    fi
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in *run_logged*) ;; *) continue ;; esac
        path="$(printf '%s\n' "$line" | sed -n 's/.*"\([^"]*\)".*/\1/p')"
        [ -n "$path" ] || continue
        path="${path//\$OMARCHY_INSTALL/$OMARCHY_INSTALL}"
        path="${path//\$\{OMARCHY_INSTALL\}/$OMARCHY_INSTALL}"
        base="$(basename "$path")"
        skip_it=0
        for o in "${omit[@]}"; do [ "$base" = "$o" ] && skip_it=1; done
        if [ "$skip_it" = 1 ]; then
            echo "  -> $base (omitido a propósito en CachyOS)"
            continue
        fi
        echo "  -> $base"
        if [ -f "$path" ]; then
            run_logged "$path" || echo "  [aviso] $base devolvió error (se continúa)"
        else
            echo "  [skip]  $base no existe en esta versión"
        fi
    done < "$list"
}

run_install_list "${OMARCHY_INSTALL}/config/all.sh"

if [ "${OMARCHY_SKIP_HARDWARE:-0}" = "1" ]; then
    echo "  [skip]  omarchy-apply-hardware (OMARCHY_SKIP_HARDWARE=1)"
elif command -v omarchy-apply-hardware >/dev/null 2>&1; then
    echo "  -> omarchy-apply-hardware --install-user ${OMARCHY_INSTALL_USER}"
    omarchy-apply-hardware --install-user "${OMARCHY_INSTALL_USER}" \
        || echo "  [aviso] omarchy-apply-hardware devolvió error (se continúa)"
elif [ -x "${OMARCHY_PATH}/bin/omarchy-apply-hardware" ]; then
    echo "  -> omarchy-apply-hardware --install-user ${OMARCHY_INSTALL_USER}"
    "${OMARCHY_PATH}/bin/omarchy-apply-hardware" --install-user "${OMARCHY_INSTALL_USER}" \
        || echo "  [aviso] omarchy-apply-hardware devolvió error (se continúa)"
else
    echo "  [skip]  omarchy-apply-hardware no existe en esta versión"
fi

run_install_list "${OMARCHY_INSTALL}/login/all.sh"
# post-install/pacman.sh se omite siempre: reescribe pacman.conf y el mirrorlist
run_install_list "${OMARCHY_INSTALL}/post-install/all.sh" pacman.sh

stop_install_log
echo "SYSTEM_APPLY_DONE"
APPLYEOF
    as_root env OMARCHY_PATH="$OMARCHY_SHARE" OMARCHY_INSTALL_USER="$OMARCHY_USER_NAME" \
        bash "$driver" || aviso "la configuración de sistema devolvió un error"
    rm -f "$driver"
}

install_v4() {
    local USER_HOME=""

    msg "Instalando paquetes de Omarchy via pacman…"
    install_pkgs_tolerant omarchy omarchy-settings omarchy-nvim
    pkg_installed omarchy \
        || die "el paquete base 'omarchy' no se pudo instalar (mirá el log)"
    pkg_installed omarchy-settings \
        || aviso "falta omarchy-settings: la configuración del sistema puede fallar"

    msg "Versión de omarchy instalada: $(pacman -Q omarchy 2>/dev/null | awk '{print $2}')"
    msg "NOTA: pkgs.omarchy.org solo publica la última release v4, así que la versión"
    msg "      elegida en el paso 1 no se puede fijar en modo v4."

    [ -d "$OMARCHY_SHARE" ] || die "el paquete omarchy se instaló pero falta $OMARCHY_SHARE"

    install_system_overrides
    install_gpu_stack

    # --- Paquetes base (filtrados para CachyOS) ---
    msg ""
    msg "Instalando el listado base de Omarchy (filtrado para CachyOS)…"
    if [ -f "$OMARCHY_SHARE/install/omarchy-base.packages" ]; then
        local filtered
        filtered="$(mktemp /tmp/omarchy-base.XXXXXX)"
        filter_base_packages < "$OMARCHY_SHARE/install/omarchy-base.packages" > "$filtered"
        local -a base=()
        mapfile -t base < "$filtered"
        rm -f "$filtered"
        msg "  ${#base[@]} paquetes en el listado"
        install_pkgs_tolerant "${base[@]}"
    else
        aviso "no existe omarchy-base.packages en $OMARCHY_SHARE/install"
    fi

    # --- Configuración del sistema ---
    msg ""
    msg "Ejecutando la configuración de sistema de Omarchy…"
    if [ "${OMARCHY_SKIP_HARDWARE:-0}" = "1" ]; then
        msg "  (OMARCHY_SKIP_HARDWARE=1: se omite el paso de hardware)"
        OMARCHY_SKIP_HARDWARE=1 apply_system_config
    else
        apply_system_config
    fi

    # --- Configuración del usuario ---
    msg ""
    msg "Configurando el usuario…"
    USER_HOME="$(getent passwd "$OMARCHY_USER_NAME" | cut -d: -f6)"
    [ -n "$USER_HOME" ] || die "no se pudo resolver la home de $OMARCHY_USER_NAME"

    # omarchy-provision-user corre COMO el usuario (no root). Solo --force:
    # --first-install fuerza OMARCHY_SETUP_CONTEXT=iso-chroot y falla buscando
    # el tarball de Node en /opt/packages.
    if [ -x "$OMARCHY_SHARE/bin/omarchy-provision-user" ]; then
        msg "Ejecutando omarchy-provision-user --force como $OMARCHY_USER_NAME…"
        as_user "$OMARCHY_USER_NAME" env \
            HOME="$USER_HOME" \
            OMARCHY_PATH="$OMARCHY_SHARE" \
            OMARCHY_INSTALL="$OMARCHY_SHARE/install" \
            PATH="$OMARCHY_SHARE/bin:$PATH" \
            "$OMARCHY_SHARE/bin/omarchy-provision-user" --force \
            || aviso "omarchy-provision-user devolvió error"
    else
        skip "omarchy-provision-user no existe en esta versión"
    fi

    # Los configs de usuario vienen en /etc/skel: copiarlos a la home actual
    if [ -d /etc/skel ]; then
        msg "Copiando /etc/skel a $USER_HOME…"
        as_user "$OMARCHY_USER_NAME" cp -af /etc/skel/. "$USER_HOME/" \
            || aviso "no se pudo copiar /etc/skel"
    fi

    # Neutralizar la migración rota de omarchy-hyprland-titlebars (1791403310.sh):
    # hyprland en CachyOS es más nuevo que el que pinnea Omarchy y
    # omarchy-migrate aborta el `omarchy update` completo.
    as_user "$OMARCHY_USER_NAME" mkdir -p "$USER_HOME/.local/state/omarchy/migrations"
    as_user "$OMARCHY_USER_NAME" touch \
        "$USER_HOME/.local/state/omarchy/migrations/1791403310.sh"
    ok "migración 1791403310.sh marcada como aplicada"

    # Descargas AUR con aria2c (16 conexiones) si está disponible
    if command -v aria2c >/dev/null 2>&1; then
        as_user "$OMARCHY_USER_NAME" mkdir -p "$USER_HOME/.config/pacman"
        local MAKEPKG_CONF="$USER_HOME/.config/pacman/makepkg.conf"
        if [ ! -f "$MAKEPKG_CONF" ]; then
            as_user "$OMARCHY_USER_NAME" tee "$MAKEPKG_CONF" >/dev/null << 'MKEOF'
# Generado por omarchy-on-cachyos: descargas AUR en paralelo con aria2c
DLAGENTS=('file::/usr/bin/curl -qgC - -o %o %u'
          'ftp::/usr/bin/curl -qgfC - --ftp-pasv --retry 3 --retry-delay 3 -o %o %u'
          'http::/usr/bin/aria2c -UWget -s 16 -x 16 -k 1M --allow-overwrite=true -o %o %u'
          'https::/usr/bin/aria2c -UWget -s 16 -x 16 -k 1M --allow-overwrite=true -o %o %u'
          'rsync::/usr/bin/rsync --no-motd -z %u %o'
          'scp::/usr/bin/scp -C %u %o')
MKEOF
            ok "aria2c configurado para AUR"
        fi
    fi

    # --- Omarchy en Español (solo si el repo la trae) ---
    if [ -f "$SCRIPT_DIR/apply-es-layer.sh" ]; then
        msg ""
        msg "Aplicando la capa Omarchy en Español (omarchy-es)…"
        chmod +x "$SCRIPT_DIR/apply-es-layer.sh"
        "$SCRIPT_DIR/apply-es-layer.sh" "$ES_REPO_URL" "$OMARCHY_USER_NAME" \
            || aviso "no se pudo aplicar la capa en español"
    else
        skip "capa en español no incluida en este repo"
    fi

    # --- SDDM ---
    # El tema SDDM de Omarchy no tiene campo de usuario: entra con el último
    # usuario de state.conf, y el autologin usa la entrada omarchy.desktop.
    msg ""
    msg "Configurando SDDM…"
    as_root mkdir -p /var/lib/sddm
    printf '[Last]\nSession=omarchy.desktop\nUser=%s\n' "$OMARCHY_USER_NAME" \
        | as_root tee /var/lib/sddm/state.conf > /dev/null
    as_root chown -R sddm:sddm /var/lib/sddm 2>/dev/null || true

    as_root mkdir -p /etc/sddm.conf.d
    printf '[Autologin]\nUser=%s\nSession=omarchy.desktop\n' "$OMARCHY_USER_NAME" \
        | as_root tee /etc/sddm.conf.d/autologin.conf > /dev/null
    as_root systemctl enable sddm.service 2>/dev/null || true
    ok "SDDM con autologin para $OMARCHY_USER_NAME (omarchy.desktop)"

    # --- Guards de actualización ---
    msg ""
    msg "Instalando guards de actualización de CachyOS…"
    install_qt_color_fix
    install_mirror_order

    # --- Comprobaciones finales ---
    msg ""
    msg "Verificando…"
    local fails=0

    if [ -f /usr/local/share/wayland-sessions/omarchy.desktop ] \
        || [ -f /usr/share/wayland-sessions/omarchy.desktop ]; then
        ok "sesión omarchy.desktop presente"
    else
        aviso "no encontré omarchy.desktop en wayland-sessions"
        fails=1
    fi

    if systemctl is-enabled sddm.service >/dev/null 2>&1; then
        ok "sddm.service habilitado"
    else
        aviso "sddm.service no quedó habilitado"
        fails=1
    fi

    if [ -f "$USER_HOME/.config/omarchy/language" ]; then
        ok "idioma de Omarchy: $(cat "$USER_HOME/.config/omarchy/language")"
    else
        aviso "falta $USER_HOME/.config/omarchy/language"
    fi

    local es_plugins
    es_plugins="$(find "$USER_HOME/.config/omarchy/plugins" -maxdepth 1 -name 'marlo4220.*' -type d 2>/dev/null | wc -l)"
    ok "$es_plugins plugins en español"

    case "$(detect_gpu_vendors)" in
        *amd*)
            pkg_installed vulkan-radeon && pkg_installed libva-mesa-driver \
                && ok "AMD: mesa + vulkan-radeon + VA-API"
            ;;
        *intel*)
            pkg_installed vulkan-intel && ok "Intel: mesa + vulkan-intel"
            ;;
        *nvidia*)
            ok "NVIDIA: driver gestionado por CachyOS ($(pacman -Qq 2>/dev/null | grep -E '^nvidia' | head -n1 || echo 'sin driver'))"
            ;;
    esac

    for unit in NetworkManager.service sddm.service; do
        systemctl is-enabled "$unit" >/dev/null 2>&1 || { aviso "$unit no habilitado"; fails=1; }
    done

    msg ""
    msg "=========================================="
    msg "  Instalación de Omarchy v4.x completa    "
    msg "=========================================="
    msg ""
    msg "  - Paquetes instalados via pacman"
    msg "  - Stack gráfico según el hardware detectado"
    msg "  - Guardias de arranque activos (mkinitcpio + limine)"
    msg "  - Ajustes de CachyOS que se restauran tras cada update"
    msg "  - SDDM configurado para $OMARCHY_USER_NAME (omarchy.desktop)"
    msg "  - Omarchy en Español aplicado (capa omarchy-es)"
    msg ""
    msg "Reiniciá para entrar al escritorio."
    msg ""

    return "$fails"
}

# ============================================================================
# Rama: v3 (fuente) o v4 (paquetes)
# ============================================================================

if [ "$OMARCHY_VERSION_MAJOR" -eq 3 ]; then
    msg ""
    msg "=========================================="
    msg "  Instalando Omarchy v3.x (modo fuente)  "
    msg "=========================================="
    msg ""
    install_v3
else
    msg ""
    msg "=========================================="
    msg "  Instalando Omarchy v4.x (modo paquetes)"
    msg "=========================================="
    msg ""
    if ! install_v4; then
        msg ""
        msg "La instalación terminó con avisos: revisá los [aviso] de arriba."
        msg "Log: ${OMARCHY_LOG:-sin log}"
        exit 1
    fi
fi

msg "Log completo: ${OMARCHY_LOG:-sin log}"
