#!/usr/bin/env bash
# Pruebas del mapeo de locale de CachyOS -> código de UI de Omarchy.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../bin/omarchy-lib.sh"

expect() {
    local locale="$1" want="$2" got
    got="$(detect_omarchy_language "$locale")"
    if [ "$got" != "$want" ]; then
        printf 'FAIL %s: esperado %s, obtenido %s\n' "$locale" "$want" "$got" >&2
        exit 1
    fi
    printf 'ok   %-18s -> %s\n' "$locale" "$got"
}

expect 'es_PE.UTF-8' 'es-MX'
expect 'es_ES.UTF-8' 'es-MX'
expect 'es_MX.UTF-8' 'es-MX'
expect 'pt_BR.UTF-8' 'pt-BR'
expect 'pt_PT.UTF-8' 'pt'
expect 'pt_AO.UTF-8' 'pt'
expect 'fr_CA.UTF-8' 'fr'
expect 'de_AT.UTF-8' 'de'
expect 'zh_HK.UTF-8' 'zh-TW'
expect 'zh_Hant.UTF-8' 'zh-TW'
expect 'zh_SG.UTF-8' 'zh-CN'
expect 'sr_RS@latin' 'sr'
expect 'ja_JP.UTF-8' 'ja'
expect 'en_US.UTF-8' 'en'
expect 'en_GB.UTF-8' 'en'
expect 'C.UTF-8' 'en'
expect 'C' 'en'

echo 'Todos los tests de idioma pasaron.'
