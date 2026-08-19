#!/usr/bin/env python3
"""Escribe el archivo de referencia que consume `--selftest --mode phash-differential`.

Por qué un archivo y no un subproceso desde la app: el modo tiene que poder correr contra el bundle
firmado sin lanzar un intérprete desde dentro, y una referencia en disco es reproducible — se puede
diffear, versionar y regenerar sola. El precio es que puede quedar rancia, y de eso se encarga el modo:
graba el conteo y cada ruta, así que un corpus con un archivo más falla en vez de comparar de menos.

Uso:
    python3 scripts/phash-reference.py ~/duplicados /tmp/phash-reference.json

Requiere `imagehash` y `Pillow`. Con cualquiera ausente sale distinto de cero diciendo cuál falta:
una referencia a medias sería peor que ninguna.
"""
import json
import sys
from pathlib import Path

try:
    import imagehash
    from PIL import Image, __version__ as pillow_version
except ImportError as error:  # pragma: no cover - es el camino de diagnóstico
    print(f"falta una dependencia: {error}", file=sys.stderr)
    print("instalar con: pip3 install imagehash Pillow", file=sys.stderr)
    raise SystemExit(2)

SUFFIXES = {".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tiff", ".tif", ".webp", ".heic"}


def orientation(path: Path) -> int:
    """El flag EXIF de orientación, o 1 si no dice nada.

    Es la única divergencia sistemática conocida contra nuestro hash: Pillow no auto-rota y nosotros
    sí, así que estos archivos *deben* diferir. El modo los separa en vez de aflojar su tolerancia
    para todos.
    """
    try:
        with Image.open(path) as image:
            exif = image.getexif()
            return int(exif.get(274, 1)) if exif else 1
    except Exception:
        return 1


def main() -> int:
    if len(sys.argv) != 3:
        print(f"uso: {sys.argv[0]} <corpus> <salida.json>", file=sys.stderr)
        return 2
    corpus = Path(sys.argv[1]).expanduser()
    output = Path(sys.argv[2]).expanduser()
    if not corpus.is_dir():
        print(f"el corpus no es un directorio: {corpus}", file=sys.stderr)
        return 2

    entries = []
    failures = 0
    # Orden por bytes de la ruta, igual que todo lo demás en este proyecto, para que dos corridas
    # produzcan el mismo archivo y un diff sea informativo.
    paths = sorted(
        (p for p in corpus.rglob("*") if p.is_file() and p.suffix.lower() in SUFFIXES),
        key=lambda p: str(p).encode("utf-8"),
    )
    for path in paths:
        try:
            with Image.open(path) as image:
                digest = str(imagehash.phash(image))
        except Exception:
            failures += 1
            continue
        entries.append(
            {"path": str(path), "hash": digest, "orientation": orientation(path)}
        )
        if len(entries) % 250 == 0:
            print(f"  {len(entries)}/{len(paths)}", file=sys.stderr)

    document = {
        "generator": "scripts/phash-reference.py",
        "imagehash": getattr(imagehash, "__version__", "unknown"),
        "pillow": pillow_version,
        "corpus": str(corpus),
        "hashed": len(entries),
        "unreadable": failures,
        "images": entries,
    }
    output.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    print(f"{len(entries)} hasheadas, {failures} ilegibles -> {output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
