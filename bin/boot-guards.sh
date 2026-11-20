#!/usr/bin/env bash
# boot-guards.sh — Protege el arranque de CachyOS (initramfs systemd + limine)
# de los drop-ins que instala omarchy-settings.
#
# Se corre ANTES de instalar omarchy-settings y también desde el hook de pacman
# después de cada update, así que tiene que ser:
#   - idempotente (nunca pisa un guardia ya creado),
#   - tolerante (nunca aborta la instalación ni la transacción de pacman),
#   - agnóstico del gestor de arranque (solo toca limine si limine existe).
#
# Uso: boot-guards.sh [--quiet]

set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

say() { [ "$QUIET" -eq 1 ] || printf '[boot-guards] %s\n' "$*"; }
warn() { printf '[boot-guards] aviso: %s\n' "$*" >&2; }

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

pkg_installed() { pacman -Qq "$1" >/dev/null 2>&1; }

MKINITCPIO_DIR="/etc/mkinitcpio.conf.d"
GUARD_FILE="$MKINITCPIO_DIR/zz-cachyos-restore-hooks.conf"

# --- 1. initramfs (mkinitcpio) ----------------------------------------------
# omarchy-settings deja /etc/mkinitcpio.conf.d/omarchy_hooks.conf, que reemplaza
# HOOKS por los legacy (udev/encrypt) y rompe el initramfs systemd de CachyOS.
# Un drop-in que ordene después (zz-) gana, y guarda una foto de los HOOKS
# reales de CachyOS.
#
# La foto se calcula SIEMPRE ignorando cualquier drop-in de omarchy, así que
# re-ejecutar el script después de instalar omarchy-settings no copia los hooks
# rotos ni aborta.

compute_cachyos_hooks() {
    (
        set +u
        HOOKS=()
        [ -f /etc/mkinitcpio.conf ] && . /etc/mkinitcpio.conf
        shopt -s nullglob
        for f in /etc/mkinitcpio.conf.d/*.conf; do
            case "$(basename "$f")" in
                *omarchy*) continue ;;
            esac
            . "$f" >/dev/null 2>&1 || true
        done
        printf '%s' "${HOOKS[*]:-}"
    )
}

install_mkinitcpio_guard() {
    local hooks line fallback
    fallback="base systemd autodetect microcode kms modconf block keyboard sd-vconsole plymouth sd-encrypt filesystems sd-btrfs-overlayfs"

    if ! pkg_installed mkinitcpio; then
        say "mkinitcpio no está instalado; no hay initramfs que proteger"
        return 0
    fi

    if [ -f "$GUARD_FILE" ]; then
        say "guardia de mkinitcpio ya presente: $GUARD_FILE"
        return 0
    fi

    hooks="$(compute_cachyos_hooks)"
    if [ -n "$hooks" ]; then
        line="HOOKS=($hooks)"
        say "HOOKS reales de CachyOS: $hooks"
        case " $hooks " in
            *" systemd "*) ;;
            *) warn "los HOOKS de CachyOS no incluyen 'systemd': se guardan tal cual están" ;;
        esac
    else
        line="HOOKS=($fallback)"
        warn "no se pudo leer /etc/mkinitcpio.conf; uso el layout systemd conocido de CachyOS"
    fi

    as_root mkdir -p "$MKINITCPIO_DIR" || return 0
    printf '%s\n' "$line" | as_root tee "$GUARD_FILE" >/dev/null \
        && say "escrito $GUARD_FILE"
    return 0
}

# --- 2. limine ---------------------------------------------------------------
# omarchy-settings deja configs en /etc/limine-entry-tool.d/ que cambian las
# entradas (TARGET_OS_NAME, ENABLE_UKI, BOOT_ORDER). /etc/default/limine se lee
# al final, así que ahí van nuestras claves.
#
# Si el sistema no usa limine, no se toca nada (en GRUB/systemd-boot estos
# archivos son inertes, pero mejor no dejar basura).

LIMINE_DEFAULT="/etc/default/limine"
LIMINE_SECTION="# CachyOS boot guard (omarchy-settings override)"

limine_in_use() {
    [ -f /boot/limine.conf ] && return 0
    [ -d /etc/limine-entry-tool.d ] && return 0
    pkg_installed limine && return 0
    [ -f "$LIMINE_DEFAULT" ] && return 0
    return 1
}

install_limine_guard() {
    local os_name="CachyOS" boot_order='*, *lts, *fallback, Snapshots' raw

    if ! limine_in_use; then
        say "limine no está en uso; se omite su guardia"
        return 0
    fi

    if [ -r /boot/limine.conf ]; then
        raw="$(sed -n 's/^[[:space:]]*description:[[:space:]]*//p' /boot/limine.conf 2>/dev/null | head -n1)"
        [ -n "$raw" ] && os_name="$raw"
        raw="$(sed -n 's/^[[:space:]]*set[[:space:]]*BOOT_ORDER:[[:space:]]*//p' /boot/limine.conf 2>/dev/null | head -n1)"
        [ -n "$raw" ] && boot_order="$raw"
    fi

    if [ -f "$LIMINE_DEFAULT" ]; then
        raw="$(sed -n 's/^BOOT_ORDER="\([^"]*\)".*/\1/p' "$LIMINE_DEFAULT" 2>/dev/null | head -n1)"
        [ -n "$raw" ] && boot_order="$raw"
    fi

    if [ -f "$LIMINE_DEFAULT" ] \
        && grep -qF "TARGET_OS_NAME=\"$os_name\"" "$LIMINE_DEFAULT" 2>/dev/null \
        && grep -qF "ENABLE_UKI=no" "$LIMINE_DEFAULT" 2>/dev/null; then
        say "guardia de limine ya presente en $LIMINE_DEFAULT"
        return 0
    fi

    as_root mkdir -p /etc/default || return 0
    if [ -f "$LIMINE_DEFAULT" ]; then
        printf '\n%s\nTARGET_OS_NAME="%s"\nENABLE_UKI=no\nBOOT_ORDER="%s"\n' \
            "$LIMINE_SECTION" "$os_name" "$boot_order" \
            | as_root tee -a "$LIMINE_DEFAULT" >/dev/null \
            && say "claves de guardia agregadas a $LIMINE_DEFAULT"
    else
        printf '# CachyOS boot guard: sobreescribe los configs de omarchy-settings\nTARGET_OS_NAME="%s"\nENABLE_UKI=no\nBOOT_ORDER="%s"\n' \
            "$os_name" "$boot_order" \
            | as_root tee "$LIMINE_DEFAULT" >/dev/null \
            && say "escrito $LIMINE_DEFAULT"
    fi
    say "limine: TARGET_OS_NAME=$os_name BOOT_ORDER=$boot_order"
    return 0
}

install_mkinitcpio_guard
install_limine_guard

say "guardias de arranque verificados"
exit 0
