#!/bin/bash
# Barrido de concurrencia con el page cache vacío.
#
# **Es la medición que decide un default enviado, y la única que no se podía tomar sin root.** El barrido
# caliente no tenía codo hasta c=16, lo que dejaría ~13% en la mesa con el tope de 8 -- pero corrió a
# 2,350 MB/s, y un número así invita a sospechar que lo sirvió el page cache y que medía SHA-256 en vez de
# disco. Correrlo en frío es lo que separa las dos explicaciones.
#
# `purge` necesita root, así que este script pide la contraseña una vez y la reusa. La app corre **sin** sudo:
# como root escribiría archivos de root y tendría otro estado de TCC.
#
# El corpus por default es el de bytes, no el real: sobre 1.5 GB en 0.70 s ninguna concurrencia se distingue
# de otra, y lo que se quiere ver es la curva bajo presión de disco.
#
# Uso:
#   scripts/cold-sweep.sh                 # construye 5 GB en /tmp y barre en frío
#   scripts/cold-sweep.sh <dir>           # barre sobre un corpus que ya existe
#   scripts/cold-sweep.sh --warm [<dir>]  # sin purge, sin sudo: la mitad que se puede correr sin contraseña
#
# `--warm` existe porque la forma de la curva se puede ver sin root y el contraste frío/caliente es
# justamente lo que se quiere: la misma curva por el mismo script, con y sin page cache.
set -uo pipefail

APP="build/Duplicate.app/Contents/MacOS/Duplicate"
[ -x "$APP" ] || { echo "falta $APP -- corre make"; exit 2; }
command -v purge >/dev/null || { echo "falta purge"; exit 2; }

LEVELS=(1 2 3 4 6 8 12 16)
# La sonda de prefijo apagada a propósito: con ella este corpus lee 0 bytes, que es su gracia y aquí sería
# medir nada. Un entero enorme la desactiva sin tocar el default enviado.
NO_PROBE=9223372036854775807

warm=""
if [ "${1:-}" = "--warm" ]; then warm="yes"; shift; fi

corpus="${1:-}"
built=""
if [ -z "$corpus" ]; then
    corpus="${TMPDIR:-/tmp}/duplicate-cold-sweep"
    echo "Construyendo 5 GB en $corpus (una vez)…"
    python3 scripts/make-corpus.py c1-prefix "$corpus" 40 64 || exit 2
    built="$corpus"
fi

if [ -z "$warm" ]; then
    echo "Pidiendo sudo una vez para poder vaciar el page cache entre corridas."
    sudo -v || exit 2
else
    echo "Modo caliente: sin purge, así que estos números incluyen el page cache."
fi

# **Lo mejor de tres, y no un promedio.** Una sola corrida por nivel dio 939 MB/s en c=4 entre vecinos de
# 3,084 y 2,896: un 3x de swing que no es una curva, es otro proceso tomando el disco. El ruido aquí es
# siempre hacia abajo -- nada hace que un disco lea más rápido de lo que puede -- así que la corrida más
# rápida es la menos contaminada, y promediar mezcla la señal con la interferencia.
printf '\n%12s %10s %10s %12s\n' concurrencia "mejor wall" MB/s "RSS pico"
for c in "${LEVELS[@]}"; do
    best_wall=""; best_mbs=0; best_rss=""
    for _ in 1 2 3; do
        [ -z "$warm" ] && sudo purge
        line=$("$APP" --selftest --mode corpus --dir "$corpus" \
            --prefix-threshold "$NO_PROBE" --concurrency "$c" 2>&1 | sed -n '3p')
        mbs=$(echo "$line" | awk '{for (i=1;i<=NF;i++) if ($i=="MB/s,") print $(i-1)}')
        [ -z "$mbs" ] && continue
        if [ "$mbs" -gt "$best_mbs" ] 2>/dev/null; then
            best_mbs="$mbs"
            best_wall=$(echo "$line" | awk '{print $1}')
            best_rss=$(echo "$line" | awk '{for (i=1;i<=NF;i++) if ($i=="RSS") print $(i+1), $(i+2)}')
        fi
    done
    printf '%12s %10s %10s %12s\n' "$c" "$best_wall" "$best_mbs" "$best_rss"
done

[ -n "$built" ] && { echo; echo "Borrando $built"; rm -rf "$built"; }
