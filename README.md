# Duplicate

App nativa de macOS para encontrar archivos duplicados. Swift, AppKit programático, cero
dependencias externas.

Es el puerto de `rav duplicate`, el subcomando del CLI personal en Python, a una app con ventana —
con vista previa antes de borrar, escaneo concurrente con caché, y algo que el CLI nunca tuvo:
deshacer.

**Estado: en construcción.** Ahora mismo hay scaffolding, localización y la resolución del
directorio de estado compartido. La detección todavía no existe. Lo que sí funciona está listado
abajo; lo que no, no está.

## Qué hará

Tres detectores, paridad con el CLI:

| Detector | Criterio |
|---|---|
| Archivos exactos | SHA-256 idéntico |
| Carpetas | coeficiente de Dice sobre `{ruta relativa → digest}` |
| Media perceptual | pHash de imagen por distancia de Hamming; video por proporción de frames que coinciden |

## Interoperabilidad con el CLI

El estado vive en el mismo lugar que el del CLI y en el mismo formato:

```
$XDG_STATE_HOME/rav/duplicate/      (o ~/.local/state/rav/duplicate/)
├── scans/                  ┐
├── decisions/              │
├── folder-scans/           │ compartidos con `rav duplicate`, byte a byte
├── folder-decisions/       │
├── similar-scans/          │
├── similar-decisions/      ┘
└── journal/                  solo de esta app: qué se movió y a dónde
```

Un escaneo hecho en la terminal se revisa en la app, y al revés. Los formatos de scan y decisiones
son byte-compatibles en las dos direcciones — hay un modo de selftest que lo verifica contra los
archivos reales del usuario, comparando bytes.

**La acción destructiva sí difiere, y conviene saberlo:** el CLI mueve a una carpeta de cuarentena
con `shutil.move`; la app manda a la Papelera real con `FileManager.trashItem` y registra cada
movimiento en el journal. Eso da "Devolver" de Finder y un deshacer dentro de la app. Un archivo que
la app mandó a la Papelera no está donde el CLI lo buscaría.

## Diferencias de comportamiento respecto al CLI

No son accidentes. Cada una arregla algo o evita un riesgo, y cada una cambia lo que se encuentra:

- **Los archivos ocultos se omiten por default.** Un grupo de 400 `.DS_Store` idénticos entierra
  todo hallazgo real. Hay un toggle para volver al comportamiento del CLI.
- **Los hardlinks se colapsan.** Dos hardlinks son un archivo; "borrar" uno no libera nada, así que
  proponerlo es mentir sobre el espacio recuperado.
- **Los clones de APFS se marcan como ya deduplicados**, no como duplicados a borrar. En volúmenes
  que no son APFS la cifra de espacio recuperable es una cota superior, y la app lo dice.
- **Los paquetes (`.app`, `.photoslibrary`, `.fcpbundle`) no se recorren por default.** Sacar un
  archivo de dentro de un bundle lo corrompe en silencio.
- **Las raíces de Papelera y cuarentena se excluyen del recorrido.** El CLI no las excluye, así que
  correr `rav duplicate ~` dos veces re-descubre lo que la primera corrida acaba de poner en
  cuarentena.
- **Los grupos sin revisar no se deciden solos.** El CLI escribe una decisión por default para cada
  grupo, incluidos los que nunca viste; esta app solo escribe los que decidiste, y al aplicar dice
  cuántos quedaron sin revisar.

## Idiomas

Interfaz en inglés y español, según el idioma del sistema. No hay más idiomas y no está previsto
agregarlos.

## Cómo correrlo

```bash
make            # compila, arma y firma build/Duplicate.app
make run        # lo lanza por Launch Services
make test       # suite de DuplicateCore
make coverage   # tests + piso de cobertura del 80% sobre Core
make selftest-all
make help       # lista todos los targets
```

La primera vez conviene correr `./scripts/make-signing-cert.sh`. Sin un certificado estable, macOS
vuelve a pedir permiso para cada carpeta después de cada rebuild. Está explicado en
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## Lo que no está verificado

- **Que el selftest pase no dice nada sobre los permisos de la app.** Lanzada desde la terminal,
  macOS atribuye el acceso a archivos a la terminal, y la app hereda los permisos de ella. Lanzada
  por Launch Services, la app es su propio proceso responsable. Los dos hechos son verdad y ninguno
  implica el otro.
- El pHash de imágenes **no** es bit-idéntico al de `imagehash.phash` del CLI. La forma del pipeline
  se reproduce, pero el resample de Pillow no es el de ImageIO, así que pares justo en el borde del
  umbral pueden aparecer en una herramienta y no en la otra. El formato compartido no guarda hashes,
  así que nada se vuelve ilegible.
- El video se muestrea con `AVAssetImageGenerator` en vez de ffmpeg. `.mkv` y `.avi` pueden no
  abrirse; el corpus real de este usuario es `.mp4` y `.mov`.

## Arquitectura

El detalle y las alternativas que se descartaron están en
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Licencia

MIT. Ver [`LICENSE`](LICENSE).
