#!/usr/bin/env python3
"""Árbol chico con duplicados conocidos, para la pasada a mano.

**Existe para no ensayar sobre el corpus real.** La pasada a mano incluye aplicar y deshacer, y aunque todo
va a la Papelera y vuelve, un árbol desechable con respuestas conocidas hace que "esto está mal" sea
evidente en vez de discutible.

Lo que arma, y lo que cada detector debe encontrar:

    exactos/          4 archivos, dos pares byte-idénticos  -> 2 grupos exactos
    parecidas/        2 JPEG de la misma foto a calidades distintas -> 1 par de imagen
    parecidas/        2 clips del mismo video recodificado   -> 1 par de video
    parecidas/        2 clips de medio segundo               -> 1 par juzgado con menos de 8 cuadros
    parecidas/        1 JPEG con "||" en el nombre           -> 1 par de clave ambigua
    copia-a/ copia-b/ 5 archivos iguales y 1 solo en copia-b -> 1 par de carpetas al 90.9%

El detector exacto ve **7** grupos sobre 23 archivos, no 2: los dos pares que exactos/ declara más los
cinco archivos que copia-a y copia-b comparten. Es correcto, y es el recordatorio de que el detector
exacto no sabe nada de carpetas.

**Los seis archivos que se agregaron a parecidas/ no cambian ese 7**, y eso es deliberado: son parecidos
entre sí y ninguno es byte-idéntico a otro, así que el detector exacto no los agrupa y los pasos 3 y 6 de
la pasada siguen viendo el mismo escaneo chico de siempre.

Uso: python3 scripts/make-demo-tree.py ~/demo-duplicate
     python3 scripts/make-demo-tree.py ~/demo-grande --carpeta-grande

La bandera arma un árbol **aparte** con dos carpetas de 4,000 archivos iguales. Va aparte porque 4,000
archivos compartidos serían 4,000 grupos exactos, y eso volvería inutilizable el escaneo chico que el resto
necesita.
"""
import os
import shutil
import subprocess
import sys


def build_big_folder_pair(root: str) -> int:
    """Dos carpetas de 4,000 archivos iguales, para ver la barra de progreso con etapa.

    **Va en su propio árbol, no en el chico.** Verificar un par de carpetas digiere cada archivo de las dos
    antes de mover nada, y eso es lo único que hace visible la etapa: con dos archivos, el apply termina antes
    del primer tick del `Timer` de 10 Hz y la línea nunca alcanza a decir "verificando" ni "moviendo".

    Y va aparte porque 4,000 archivos compartidos serían **4,000 grupos exactos**: el escaneo chico que los
    pasos 3 y 6 de la pasada necesitan dejaría de ser chico.
    """
    shutil.rmtree(root, ignore_errors=True)
    a = f"{root}/original"
    os.makedirs(f"{a}/sub", exist_ok=True)
    for index in range(4000):
        # Contenido distinto por archivo: 4,000 copias del mismo byte serían un grupo exacto de 4,000 y
        # el trabajo de verificación se colapsaría en una sola clase de almacenamiento.
        name = f"sub/archivo-{index:04d}.txt" if index % 2 else f"archivo-{index:04d}.txt"
        with open(f"{a}/{name}", "wb") as handle:
            handle.write(f"contenido numero {index}\n".encode() * 40)
    shutil.copytree(a, f"{root}/respaldo")

    print(f"\nÁrbol grande listo en {root}")
    print("  original vs respaldo -> 1 par de carpetas al 100%, 4,000 archivos por lado")
    print("  escanéalo con Carpetas parecidas y aplica: ahí sí se ve la barra con etapa")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    root = os.path.expanduser(sys.argv[1])
    if "--carpeta-grande" in sys.argv[2:]:
        return build_big_folder_pair(root)
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

        # 2b. Un par cuyo nombre trae "||", que es el separador de la clave de decisiones.
        #
        # `SimilarPairKey` guarda "a||b" sin escapes, así que una ruta que lo contenga produce una clave que
        # se vuelve a partir en el par equivocado — y lo que esa clave nombra es un archivo que se borra.
        # Medido: ninguna ruta del corpus real lo tiene, y por eso hace falta fabricarlo. El "|" es legal en
        # APFS. El aviso sale al cerrar la ventana, y solo para pares **decididos**: uno sin decidir no
        # escribe clave, así que su ambigüedad no cuesta nada.
        # **Un dibujo distinto, no una copia del paisaje.** La primera versión guardaba `image` otra vez a
        # la misma calidad, y salía byte-idéntica: dos grupos exactos nuevos, que es exactamente lo que este
        # archivo dice estar evitando. El detector exacto pasó de 7 a 9 y lo destapó.
        raro = Image.new("RGB", (1000, 700), (96, 32, 64))
        pincel = ImageDraw.Draw(raro)
        for i in range(0, 1000, 50):
            pincel.ellipse([i, 100 + i // 4, i + 90, 400 + i // 4], fill=(40, 200 - i // 6, i // 4))
        raro.save(f"{similar}/foto||rara.jpg", quality=95)
        raro.resize((500, 350)).save(f"{similar}/foto||rara-chica.jpg", quality=60)
        print('  parecidas: 2 JPEG con "||" en el nombre, para el aviso de clave ambigua')
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

        # 3b. Dos clips de medio segundo, para el encabezado de pocos cuadros.
        #
        # El muestreo es `interval = max(dur/(n+1), 0.1)` con marcas en `interval·(i+1)`, así que a 0.5 s el
        # intervalo se clampea a 0.1 y las últimas marcas caen **pasado el final**. Esas se filtran antes de
        # pedirlas, y el encabezado lo dice: "juzgado con N de 8 cuadros". Con clips de 12 s las ocho marcas
        # caen dentro y esa frase no aparece nunca.
        corto = f"{similar}/clip-corto.mp4"
        subprocess.run(
            ["ffmpeg", "-nostdin", "-y", "-f", "lavfi", "-i",
             "testsrc=duration=0.5:size=320x240:rate=24", "-pix_fmt", "yuv420p", corto],
            capture_output=True,
        )
        subprocess.run(
            ["ffmpeg", "-nostdin", "-y", "-i", corto, "-b:v", "120k",
             f"{similar}/clip-corto-recodificado.mp4"],
            capture_output=True,
        )
        print("  video: 2 clips de 0.5 s, para el encabezado de pocos cuadros")
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
    print("  parecidas/  -> 2 pares de imagen, 2 de video; uno de cada uno es el fixture raro")
    print("  copia-a vs copia-b -> 1 par de carpetas al 90.9%, con solo-aqui.txt de más en copia-b")
    print("  y el detector exacto ve 7 grupos: los 2 de exactos/ más los 5 que las copias comparten")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
