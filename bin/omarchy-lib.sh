#!/usr/bin/env bash
# =============================================================================
# omarchy-lib.sh — utilidades compartidas del instalador y de sus auxiliares.
#
# No ejecuta nada al cargarse: solo define funciones. Eso permite testearlas
# con dobles (mocks de pacman, lspci, systemctl…) sin tocar el sistema real.
#
# Requiere bash >= 4.3. Se usa en CachyOS/Arch (pacman), así que no hace falta
# portabilidad a otras distribuciones, pero sí tolerancia a que falte un
# comando, un paquete o un archivo.
# =============================================================================

# --- Salida ------------------------------------------------------------------
msg()   { printf '%s\n' "$*"; }
ok()    { printf '  [ok]    %s\n' "$*"; }
skip()  { printf '  [skip]  %s\n' "$*"; }
aviso() { printf '  [aviso] %s\n' "$*" >&2; }
die()   { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- sudo --------------------------------------------------------------------
# Pide la contraseña una vez y mantiene la credencial viva durante toda la
# instalación (que puede tardar bastante). El bucle se corta solo si sudo deja
# de estar en caché o al salir.
SUDO_KEEPALIVE_PID=""

sudo_init() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 || die "sudo no está instalado"
    sudo -v || die "no se pudo obtener sudo"
    ( while sleep 50; do sudo -n true 2>/dev/null || exit 0; done ) &
    SUDO_KEEPALIVE_PID=$!
}

sudo_stop() {
    if [ -n "${SUDO_KEEPALIVE_PID:-}" ]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        SUDO_KEEPALIVE_PID=""
    fi
}

# Ejecuta como root (sin sudo cuando ya se es root).
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Ejecuta como otro usuario (root -> sudo -u, que root puede usar sin clave).
as_user() {
    local user="$1"
    shift
    sudo -u "$user" "$@"
}

# --- pacman ------------------------------------------------------------------
# --ask 4 responde "sí" a "¿reemplazar el paquete en conflicto?": CachyOS y el
# repo de omarchy empaquetan lo mismo (p. ej. power-profiles-daemon vs
# omarchy-power-profiles-daemon) y sin eso pacman aborta la transacción entera.
PACMOPTS=(--noconfirm --needed --disable-download-timeout --ask 4)

pkg_installed() {
    pacman -Qq "$1" >/dev/null 2>&1
}

# ¿El paquete existe en algún repo configurado? (no instala nada)
pkg_available() {
    pacman -Sp --needed --print-format '%n' "$1" >/dev/null 2>&1
}

pacman_conf_file() {
    printf '%s' "${PACMAN_CONF:-/etc/pacman.conf}"
}

repo_enabled() {
    grep -qE "^[[:space:]]*\[$1\]" "$(pacman_conf_file)" 2>/dev/null
}

multilib_enabled() {
    if command -v pacman-conf >/dev/null 2>&1; then
        pacman-conf --repo-list 2>/dev/null | grep -qx multilib && return 0
    fi
    repo_enabled multilib
}

aur_helper() {
    if command -v paru >/dev/null 2>&1; then
        printf 'paru'
    elif command -v yay >/dev/null 2>&1; then
        printf 'yay'
    fi
}

# Instala paquetes AUR de uno en uno: si uno falla, el resto igual se intenta.
install_aur_pkgs() {
    local helper p
    helper="$(aur_helper)"
    if [ -z "$helper" ]; then
        aviso "no hay helper AUR (yay/paru); se omite: $*"
        return 0
    fi
    for p in "$@"; do
        [ -n "$p" ] || continue
        "$helper" -S --needed --noconfirm "$p" \
            || aviso "no se pudo instalar '$p' desde AUR (se continúa sin él)"
    done
}

# Instala lo que exista en los repos y manda el resto al AUR, sin abortar por
# un nombre inexistente (pacman cancela TODA la transacción si uno falta).
install_pkgs_tolerant() {
    local -a want=("$@") resolvable=() missing=()
    local p

    for p in "${want[@]}"; do
        [ -n "$p" ] || continue
        if pkg_available "$p"; then
            resolvable+=("$p")
        else
            missing+=("$p")
        fi
    done

    if [ "${#resolvable[@]}" -gt 0 ]; then
        # Un conflicto entre dos paquetes cancela la transacción completa; en
        # ese caso se reintenta de a uno para salvar todo lo que se pueda.
        if ! as_root pacman -S "${PACMOPTS[@]}" "${resolvable[@]}"; then
            aviso "la instalación en lote falló (¿conflicto?); reintentando uno por uno"
            for p in "${resolvable[@]}"; do
                as_root pacman -S "${PACMOPTS[@]}" "$p" \
                    || aviso "no se pudo instalar '$p' (se continúa sin él)"
            done
        fi
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        aviso "no están en los repos de CachyOS: ${missing[*]}"
        install_aur_pkgs "${missing[@]}"
    fi
}

# --- CPU ---------------------------------------------------------------------
# amd | intel | other
detect_cpu_vendor() {
    local vendor="" cpuinfo="${CPUINFO:-/proc/cpuinfo}"
    if [ -r "$cpuinfo" ]; then
        vendor="$(awk -F: '/^vendor_id/ { gsub(/[ \t]/, "", $2); print $2; exit }' "$cpuinfo" 2>/dev/null || true)"
    fi
    if [ -z "$vendor" ] && command -v lscpu >/dev/null 2>&1; then
        vendor="$(lscpu 2>/dev/null | awk -F: '/Vendor ID/ { gsub(/[ \t]/, "", $2); print $2; exit }')"
    fi
    case "$vendor" in
        GenuineIntel)             printf 'intel' ;;
        AuthenticAMD|HygonGenuine) printf 'amd' ;;
        *)                        printf 'other' ;;
    esac
}

microcode_pkg() {
    case "$(detect_cpu_vendor)" in
        amd)   printf 'amd-ucode' ;;
        intel) printf 'intel-ucode' ;;
        *)     printf '' ;;
    esac
}

# --- GPU ---------------------------------------------------------------------
# Una línea por fabricante detectado: amd, intel, nvidia, arm.
# Usa lspci y, si no está, el bus PCI de /sys (funciona en todas las PCs).
detect_gpu_vendors() {
    local seen=" " id line vendor
    local out=""

    if command -v lspci >/dev/null 2>&1; then
        out="$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' || true)"
    fi

    if [ -n "$out" ]; then
        while IFS= read -r line; do
            case "$line" in
                *"1002:"*) id=amd ;;
                *"8086:"*) id=intel ;;
                *"10de:"*) id=nvidia ;;
                *"13b5:"*) id=arm ;;
                *)         id=other ;;
            esac
            [ "$id" = other ] && continue
            case "$seen" in
                *" $id "*) ;;
                *) seen="$seen$id "; printf '%s\n' "$id" ;;
            esac
        done <<< "$out"
        return 0
    fi

    for vendor in "${SYSFS_PCI:-/sys/bus/pci/devices}"/*/; do
        [ -r "$vendor/class" ] || continue
        case "$(cat "$vendor/class" 2>/dev/null)" in
            0x03*) ;;
            *) continue ;;
        esac
        case "$(cat "$vendor/vendor" 2>/dev/null)" in
            0x1002) id=amd ;;
            0x8086) id=intel ;;
            0x10de) id=nvidia ;;
            0x13b5) id=arm ;;
            *)     id=other ;;
        esac
        [ "$id" = other ] && continue
        case "$seen" in
            *" $id "*) ;;
            *) seen="$seen$id "; printf '%s\n' "$id" ;;
        esac
    done
}

# Paquetes de usuarios (mesa/vulkan/VA-API) según el hardware detectado.
# No incluye drivers de kernel: eso lo maneja CachyOS (chwd / linux-cachyos).
# NVIDIA necesita nvidia-utils, pero solo si el driver propietario está en uso,
# así que eso lo decide nvidia.sh (respeta lo que ya instaló CachyOS).
gpu_packages() {
    local -a pkgs=(mesa vulkan-icd-loader libva-utils linux-firmware)
    local v

    for v in $(detect_gpu_vendors); do
        case "$v" in
            amd)
                pkgs+=(vulkan-radeon libva-mesa-driver mesa-vdpau)
                if multilib_enabled; then
                    pkgs+=(lib32-mesa lib32-vulkan-radeon lib32-libva-mesa-driver)
                fi
                ;;
            intel)
                pkgs+=(vulkan-intel intel-media-driver)
                if multilib_enabled; then
                    pkgs+=(lib32-mesa lib32-vulkan-intel)
                fi
                ;;
            arm)
                if [ "$(uname -m)" = "aarch64" ]; then
                    pkgs+=(vulkan-freedreno)
                fi
                ;;
        esac
    done

    local ucode
    ucode="$(microcode_pkg)"
    [ -n "$ucode" ] && pkgs+=("$ucode")

    printf '%s\n' "${pkgs[@]}" | awk 'NF && !seen[$0]++'
}

install_gpu_stack() {
    local -a pkgs=()
    local p

    msg "Detectando hardware gráfico…"
    if [ -z "$(detect_gpu_vendors)" ]; then
        aviso "no se detectó ninguna GPU por PCI; se instala solo lo básico (mesa)"
    fi
    msg "  CPU: $(detect_cpu_vendor)   GPU: $(detect_gpu_vendors | tr '\n' ' ')"

    while IFS= read -r p; do
        [ -n "$p" ] && pkgs+=("$p")
    done < <(gpu_packages)

    if [ "${#pkgs[@]}" -eq 0 ]; then
        skip "sin paquetes gráficos que instalar"
        return 0
    fi

    msg "  Paquetes: ${pkgs[*]}"
    install_pkgs_tolerant "${pkgs[@]}"
    ok "stack gráfico/CPU al día"
}

# --- Arranque ----------------------------------------------------------------
# limine | grub | systemd-boot | unknown
detect_bootloader() {
    if [ -f "${BOOT_DIR:-/boot}/limine.conf" ]; then
        printf 'limine'
    elif [ -f "${BOOT_DIR:-/boot}/grub/grub.cfg" ]; then
        printf 'grub'
    elif [ -f "${BOOT_DIR:-/boot}/loader/loader.conf" ]; then
        printf 'systemd-boot'
    elif pkg_installed limine || [ -d /etc/limine-entry-tool.d ]; then
        printf 'limine'
    elif pkg_installed grub; then
        printf 'grub'
    else
        printf 'unknown'
    fi
}

# --- Paquetes base de Omarchy ------------------------------------------------
# Filtros para CachyOS sobre install/omarchy-base.packages (stdin -> stdout):
#   tldr                      -> CachyOS trae tealdeer
#   nvim                      -> rebuild propio de omarchy; se usa neovim
#   quickshell-git            -> el repo de omarchy publica quickshell
#   omarchy-hyprland-titlebars-> exige hyprland=0.56.2 y CachyOS es rolling
filter_base_packages() {
    sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
        | grep -vE '^[[:space:]]*$' \
        | sed -e '/^tldr$/d' \
              -e 's/^nvim$/neovim/' \
              -e 's/^quickshell-git$/quickshell/' \
              -e '/^omarchy-hyprland-titlebars$/d'
}

# --- Preflight ---------------------------------------------------------------
human_gib() {
    awk -v k="${1:-0}" 'BEGIN { printf "%.1f", k / 1048576 }'
}

disk_free_kib() {
    df -Pk "$1" 2>/dev/null | awk 'NR==2 { print $4 }'
}

root_fstype() {
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -no FSTYPE / 2>/dev/null || printf 'desconocido'
    else
        printf 'desconocido'
    fi
}

have_network() {
    local host="${NET_CHECK_HOST:-pkgs.omarchy.org}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSI --max-time 10 "https://$host/" >/dev/null 2>&1
        return $?
    fi
    if command -v getent >/dev/null 2>&1; then
        getent hosts "$host" >/dev/null 2>&1
        return $?
    fi
    return 0
}

# Imprime el estado del sistema. Devuelve 1 si hay un problema bloqueante.
preflight_report() {
    local rc=0 os="" ram_kib free_kib fstype bootloader

    if [ -r /etc/os-release ]; then
        os="$( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-desconocido}" )"
    fi
    ram_kib="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || printf 0)"
    free_kib="$(disk_free_kib /)"
    fstype="$(root_fstype)"
    bootloader="$(detect_bootloader)"

    msg "== Comprobaciones del sistema =="
    printf '  %-18s %s\n' "Sistema"        "${os:-desconocido}"
    printf '  %-18s %s\n' "Arquitectura"   "$(uname -m)"
    printf '  %-18s %s\n' "Kernel"         "$(uname -r)"
    printf '  %-18s %s GB\n' "RAM"         "$(human_gib "$ram_kib")"
    printf '  %-18s %s GB libres\n' "Disco /" "$(human_gib "${free_kib:-0}")"
    printf '  %-18s %s\n' "Raíz (fs)"      "$fstype"
    printf '  %-18s %s\n' "Arranque"       "$bootloader"
    printf '  %-18s %s\n' "CPU"            "$(detect_cpu_vendor)"
    printf '  %-18s %s\n' "GPU"            "$(detect_gpu_vendors | tr '\n' ' ')"

    case "$(uname -m)" in
        x86_64) ;;
        *) aviso "arquitectura $(uname -m): el flujo de esta guía está pensado para x86_64"; rc=1 ;;
    esac

    if [ "$fstype" != "btrfs" ]; then
        aviso "la raíz no es btrfs ($fstype): snapper y los rollbacks de Omarchy no van a funcionar"
    fi

    if ! pkg_installed snapper; then
        aviso "snapper no está instalado (Omarchy lo espera para los snapshots)"
    fi

    if [ "$(id -u)" -eq 0 ]; then
        if [ "${OMARCHY_ALLOW_ROOT:-0}" != "1" ]; then
            aviso "no ejecutes el instalador como root: usá tu usuario y este pedirá sudo"
            rc=1
        fi
    fi

    if ! have_network; then
        aviso "sin acceso a los repos (¿red caída?)"
        rc=1
    fi

    if [ -n "$free_kib" ] && [ "$free_kib" -lt $((15 * 1024 * 1024)) ]; then
        aviso "menos de 15 GB libres en /: puede no alcanzar"
        rc=1
    fi

    if [ -f /var/lib/pacman/db.lck ]; then
        aviso "existe /var/lib/pacman/db.lck (¿otro pacman corriendo?)"
        rc=1
    fi

    case "$bootloader" in
        limine)        ok "arranque limine (el soportado por Omarchy)" ;;
        unknown)       aviso "no pude identificar el gestor de arranque" ;;
        *)             aviso "arranque $bootloader: Omarchy 4 asume limine; se aplican igual los guardias" ;;
    esac

    return "$rc"
}

# --- Omarchy repo ------------------------------------------------------------
OMARCHY_KEY="F0134EE680CAC571"

omarchy_repo_ready() {
    repo_enabled omarchy && pacman -Si omarchy >/dev/null 2>&1
}

ensure_omarchy_repo() {
    if ! pacman-key --list-keys "$OMARCHY_KEY" >/dev/null 2>&1; then
        msg "Importando la llave del repo de Omarchy ($OMARCHY_KEY)…"
        as_root pacman-key --recv-keys "$OMARCHY_KEY" \
            || aviso "no se pudo descargar la llave (¿keyserver caído?)"
        as_root pacman-key --lsign-key "$OMARCHY_KEY" \
            || aviso "no se pudo firmar localmente la llave"
    else
        skip "llave de Omarchy ya presente"
    fi

    if repo_enabled omarchy; then
        skip "repo [omarchy] ya está en $(pacman_conf_file)"
    else
        msg "Agregando el repo [omarchy] a $(pacman_conf_file)…"
        printf '\n[omarchy]\nSigLevel = Optional TrustedOnly\nServer = https://pkgs.omarchy.org/$arch\n' \
            | as_root tee -a "$(pacman_conf_file)" >/dev/null
    fi

    as_root pacman -Sy --noconfirm --disable-download-timeout \
        || die "no se pudo sincronizar la base de datos de pacman"

    if ! pacman -Si omarchy >/dev/null 2>&1; then
        die "el repo [omarchy] no responde o la firma no valida (revisá la red y pacman-key)"
    fi
}
