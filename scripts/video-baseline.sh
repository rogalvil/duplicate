#!/bin/bash
# Compara el muestreo de video de esta app contra las dos ramas de ffmpeg del CLI.
#
# El plan pedía esta medición para que "quitamos la dependencia de ffmpeg y además es más rápido" fuera un
# número y no un eslogan. Reproduce los dos comandos exactos del CLI (`core/perceptual.py:106-129`):
#
#   rápida  — N llamadas con `-ss` ANTES de `-i`: salta al sync sample más cercano
#   lenta   — una llamada con el filtro `fps`: decodifica el archivo entero
#
# La rama que el CLI elige depende de un umbral de 200 MB, y esa propiedad *es* `requestedTimeTolerance` en
# AVFoundation, que es lo que esta app usa en su lugar.
#
# Uso:  scripts/video-baseline.sh <video> [<video> ...]
# Requiere ffmpeg y ffprobe. Solo lee los archivos que se le pasan; los cuadros van a un temporal que borra.
set -uo pipefail

command -v ffmpeg >/dev/null || { echo "falta ffmpeg"; exit 2; }
command -v ffprobe >/dev/null || { echo "falta ffprobe"; exit 2; }
APP="build/Duplicate.app/Contents/MacOS/Duplicate"
[ -x "$APP" ] || { echo "falta $APP -- corre make"; exit 2; }
[ $# -ge 1 ] || { echo "uso: $0 <video> [...]"; exit 2; }

FRAMES=8
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf '%-26s %10s %8s %12s %12s %12s\n' archivo tamaño dur "ffmpeg-rápida" "ffmpeg-lenta" "esta-app"
for video in "$@"; do
    [ -f "$video" ] || { echo "no existe: $video"; continue; }
    bytes=$(stat -f%z "$video")
    dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video")
    dur=${dur:-0}
    # interval = max(dur/(n+1), 0.1), la aritmética que el umbral de 0.70 se calibró contra
    interval=$(python3 -c "print(max($dur/($FRAMES+1), 0.1))")

    # Rama rápida: una llamada por cuadro, `-ss` antes de `-i`.
    rm -rf "$work"/fast; mkdir -p "$work"/fast
    start=$(python3 -c 'import time;print(time.monotonic())')
    for i in $(seq 1 $FRAMES); do
        ts=$(python3 -c "print(f'{$interval * $i:.3f}')")
        ffmpeg -nostdin -ss "$ts" -i "$video" -frames:v 1 -q:v 2 \
            "$work/fast/frame$i.jpg" >/dev/null 2>&1
    done
    fast=$(python3 -c "import time;print(f'{time.monotonic()-$start:.3f}')")

    # Rama lenta: una llamada con el filtro fps, que decodifica todo.
    rm -rf "$work"/slow; mkdir -p "$work"/slow
    start=$(python3 -c 'import time;print(time.monotonic())')
    ffmpeg -nostdin -i "$video" -vf "fps=1/$interval" -frames:v $FRAMES -q:v 2 \
        "$work/slow/frame%04d.jpg" >/dev/null 2>&1
    slow=$(python3 -c "import time;print(f'{time.monotonic()-$start:.3f}')")

    # Esta app, con la tolerancia que se envía. El modo hace su propio calentamiento y toma el mejor de tres.
    ours=$("$APP" --selftest --mode video-timing --file "$video" 2>/dev/null \
        | awk '/\(shipped\)/ {print $4}' | tr -d "s")
    ours=${ours:-n/a}

    printf '%-26.26s %9.1fM %7.1fs %11ss %11ss %11ss\n' \
        "$(basename "$video")" "$(python3 -c "print($bytes/1048576)")" \
        "$(python3 -c "print($dur)")" "$fast" "$slow" "$ours"
done
