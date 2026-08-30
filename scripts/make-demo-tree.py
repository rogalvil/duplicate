#!/usr/bin/env python3
"""Árbol chico con duplicados conocidos, para la pasada a mano.

**Existe para no ensayar sobre el corpus real.** La pasada a mano incluye aplicar y deshacer, y aunque todo
va a la Papelera y vuelve, un árbol desechable con respuestas conocidas hace que "esto está mal" sea
evidente en vez de discutible.

Lo que arma, y lo que cada detector debe encontrar:

    exactos/          4 archivos, dos pares byte-idénticos  -> 2 grupos exactos
    parecidas/        2 JPEG de la misma foto a calidades distintas -> 1 par de imagen
    parecidas/        2 clips del mismo video recodificado   -> 1 par de video
    copia-a/ copia-b/ 5 archivos iguales y 1 solo en copia-b -> 1 par de carpetas al 90.9%

El detector exacto ve **7** grupos sobre 19 archivos, no 2: los dos pares que exactos/ declara más los
cinco archivos que copia-a y copia-b comparten. Es correcto, y es el recordatorio de que el detector
exacto no sabe nada de carpetas.

Uso: python3 scripts/make-demo-tree.py ~/demo-duplicate
"""
import os
import shutil
import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = os.path.expanduser(sys.argv[1])
    shutil.rmtree(root, ignore_errors=True)

    # 1. Exactos: dos pares byte-idénticos, con nombres que ejercitan la heurística de "parece copia".
    exact = f"{root}/exactos"
    os.makedirs(f"{exact}/subcarpeta", exist_ok=True)
    for name, payload in [
        ("informe.pdf", b"contenido del informe " * 400),
        ("subcarpeta/informe copia.pdf", b"contenido del informe " * 400),
        ("foto.raw", b"bytes de la foto " * 900),
        ("foto 2.raw", b"bytes de la foto " * 900),
    ]:
        with open(f"{exact}/{name}", "wb") as handle:
            handle.write(payload)

    # 2. Parecidas: la misma imagen a dos calidades. Pillow porque el punto es que sean *parecidas* y no
    # idénticas, que es lo que el detector perceptual encuentra y el exacto no.
    similar = f"{root}/parecidas"
    os.makedirs(similar, exist_ok=True)
    try:
        from PIL import Image, ImageDraw

        image = Image.new("RGB", (1200, 800), (32, 64, 96))
        draw = ImageDraw.Draw(image)
        # Las alturas se clampean: sin eso, pasado i=1050 el borde de abajo queda arriba del de arriba y
        # Pillow lanza `y1 must be greater than or equal to y0`.
        for i in range(0, 1200, 60):
            top = min(i // 3, 380)
            bottom = max(700 - i // 3, top + 20)
            draw.rectangle([i, top, i + 40, bottom], fill=(200 - i // 8, 90, i // 6))
        image.save(f"{similar}/paisaje-original.jpg", quality=95)
        image.resize((600, 400)).save(f"{similar}/paisaje-whatsapp.jpg", quality=60)
        print("  parecidas: 2 JPEG de la misma imagen (95% y 60% reescalada)")
    except ImportError:
        print("  parecidas: SALTADO, falta Pillow (pip3 install Pillow)")

    # 3. Video: el mismo clip recodificado, que es el caso que el ratio de cuadros existe para absorber.
    if shutil.which("ffmpeg"):
        source = f"{similar}/clip-original.mp4"
        subprocess.run(
            ["ffmpeg", "-nostdin", "-y", "-f", "lavfi", "-i",
             "testsrc=duration=12:size=640x480:rate=24", "-pix_fmt", "yuv420p", source],
            capture_output=True,
        )
        subprocess.run(
            ["ffmpeg", "-nostdin", "-y", "-i", source, "-b:v", "300k", "-s", "320x240",
             f"{similar}/clip-recodificado.mp4"],
            capture_output=True,
        )
        print("  video: 2 clips del mismo contenido, uno recodificado más chico")
    else:
        print("  video: SALTADO, falta ffmpeg")

    # 4. Carpetas: el mismo árbol con otro nombre, más un archivo que solo tiene una.
    #
    # **Cinco compartidos y no tres, y el número sale de una desigualdad.** Con `s` archivos iguales y uno
    # solo en `copia-b`, el Dice es `2s / (2s + 1)`; para llegar al umbral por default de 90% hace falta
    # `s >= 4.5`, o sea cinco. Con tres daba 85.7% y el par de las carpetas padre **no se encontraba**: el
    # detector sólo veía `copia-a/notas` contra `copia-b/notas` al 100%, un par de un archivo sin nada que
    # sobre de un lado -- justo lo que el paso 5 de la pasada a mano existe para mirar.
    folder_a = f"{root}/copia-a"
    os.makedirs(f"{folder_a}/notas", exist_ok=True)
    for name, payload in [
        ("uno.txt", b"primero\n"),
        ("dos.txt", b"segundo\n"),
        ("cuatro.txt", b"cuarto\n"),
        ("notas/tres.txt", b"tercero\n"),
        ("notas/cinco.txt", b"quinto\n"),
    ]:
        with open(f"{folder_a}/{name}", "wb") as handle:
            handle.write(payload)
    shutil.copytree(folder_a, f"{root}/copia-b")
    # Y un archivo extra en una, para que el visor tenga algo que avisar que se perdería.
    with open(f"{root}/copia-b/solo-aqui.txt", "wb") as handle:
        handle.write(b"esto solo esta en copia-b\n")

    print(f"\nÁrbol listo en {root}")
    print("  exactos/    -> 2 grupos exactos")
    print("  parecidas/  -> 1 par de imagen y 1 par de video")
    print("  copia-a vs copia-b -> 1 par de carpetas al 90.9%, con solo-aqui.txt de más en copia-b")
    print("  y el detector exacto ve 7 grupos: los 2 de exactos/ más los 5 que las copias comparten")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
