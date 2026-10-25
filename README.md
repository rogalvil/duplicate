# Duplicate

App nativa de macOS para encontrar archivos duplicados. Swift, AppKit programático, cero
dependencias externas.

Nació como versión con ventana de `rav duplicate`, una herramienta de línea de comandos del mismo autor que no
es pública, y agrega lo que esa herramienta no tenía: vista previa antes de borrar, escaneo concurrente con
caché, y deshacer. Para usarla no hace falta nada más.

**Estado: en construcción, y la lista de abajo es literal.** No hay que deducir qué falta.

| | Estado |
|---|---|
| Escaneo de duplicados exactos desde la app, con progreso y cancelación | **funciona** |
| Biblioteca de escaneos, con actualización en vivo | **funciona** |
| Revisión de grupos con vista previa y decisiones que se guardan | **funciona** |
| Simular, aplicar a la Papelera, **detener a media corrida** y deshacer la sesión | **funciona** |
| Detector de carpetas: escanea, lista, decide con ⌘Z y aplica | **funciona** |
| Detector perceptual de imagen: escanear desde la app, listar y ver los pares | **funciona** |
| Detector perceptual de video: escanear, listar y ver los pares | **funciona** |
| Caché de hashes perceptuales | **funciona** — 177 s a 0.5 s en el mismo árbol |
| Decidir pares parecidos en el visor, con el consejo, **lote por filtro** y ⌘Z | **funciona** |
| Aplicar un par parecido a la Papelera desde la app, verificado y deshacible | **funciona** |
| Progreso con etapa durante el apply: verificar y mover se distinguen | **funciona** |
| Cancelar dentro del hasheo de un archivo grande, no solo entre archivos | **funciona** |
| Metadata bajo la vista previa: tamaño, fecha, resolución, codec — y fecha por carpeta | **funciona** |
| Vista rápida a tamaño completo (⌘Y) y Mostrar en Finder, en los tres visores | **funciona** |
| Historial de sesiones: listarlas y deshacer **cualquiera**, no solo la última | **funciona** |
| Cuarentena cuando la Papelera no existe, probada en un montaje SMB real | **funciona** |
| Limpiar los journals de sesiones ya deshechas, con su regla probable | **funciona** |

O sea: **los tres detectores cierran el ciclo completo** desde la app — escanear, revisar, decidir, simular,
aplicar a la Papelera, deshacer. Imágenes y video, los dos.

El hash perceptual está medido contra `imagehash` sobre las 2,779 fotos reales del corpus, y el modo
`phash-differential` vuelve a medirlo cuando se le pide: **90.9% idéntico bit a bit** entre las 2,761 sin
rotación, peor caso de **4 bits**, **96.7% de Jaccard** entre los dos conjuntos de pares, y **ningún par** que
una implementación llame casi idéntico y la otra ajeno. Las 18 imágenes con etiqueta de rotación EXIF se
separan en vez de tolerarse: nosotros aplicamos la orientación y Pillow no, así que ahí diferir es lo
correcto — una copia que solo cambia el flag debería coincidir con su original.

## Requisitos

- **macOS 15 o superior.** No es negociable: el proyecto usa `Atomic` y `Mutex` de
  `Synchronization`, que existen desde macOS 15.
- **Command Line Tools de Xcode** (o Xcode). `xcode-select --install` si `xcrun` no responde.
- Swift 6, que viene con las Command Line Tools de esa versión.
- Nada más. Cero dependencias externas es requisito del proyecto, así que no hay `brew install` de
  nada, ni SwiftPM resolviendo paquetes de red.

## Instalación

```bash
git clone git@github.com:rogalvil/duplicate.git
cd duplicate

./scripts/make-signing-cert.sh   # una sola vez, ver abajo
make install                     # compila, firma y copia a /Applications
open -a Duplicate
```

`make install` copia el bundle firmado a `/Applications`, así que sobrevive a un `make clean`. Para
ponerlo en otro lado:

```bash
make install INSTALL_DIR=~/Applications
```

Si solo se quiere probar sin instalar:

```bash
make run        # lo lanza por Launch Services desde build/
make run-debug  # lo corre en primer plano, con stdout y crashes visibles
```

### El certificado de firma no es opcional en la práctica

La app se firma con un certificado self-signed local llamado `Duplicate Dev`. Si no existe, `make`
firma **ad-hoc**, y entonces macOS trata cada rebuild como una app distinta: los permisos de acceso a
carpetas que ya concediste se olvidan y los vuelve a pedir cada vez.

```bash
./scripts/make-signing-cert.sh
```

Se corre una vez por máquina. El detalle, y las dos trampas si lo automatizas por tu cuenta, están en
[`CONTRIBUTING.md`](CONTRIBUTING.md).

### Primer arranque

La app **no** está notarizada ni firmada con un Developer ID de Apple. Es una app local compilada en
la máquina donde corre, así que la primera vez macOS puede negarse a abrirla con un diálogo que dice
que no se puede verificar el desarrollador. Se resuelve con clic derecho → Abrir, o en Ajustes del
Sistema → Privacidad y Seguridad → Abrir de todos modos.

Al escanear una carpeta protegida, macOS pide permiso una vez por carpeta (Escritorio, Documentos,
Descargas, discos externos). **No pide, ni pedirá, Acceso Total al Disco**: no hay API para solicitarlo
—solo un interruptor manual— los duplicados dentro de `~/Library` son casi siempre cachés donde quitar
un "duplicado" rompe una app, y una app que pide Acceso Total al Disco para ordenar Descargas es
indistinguible de malware para un usuario cuidadoso. `~/Library` se excluye por default — salvo que la raíz que elijas esté dentro de ella, porque entonces
la señalaste a propósito.

### Desinstalar

```bash
make uninstall              # quita la copia de /Applications
rm -rf ~/Library/Caches/com.rogalvil.duplicate    # la caché de hashes, dato derivado
```

El directorio de estado (`~/.local/state/rav/duplicate/`) **no se toca**: son los escaneos y decisiones del
usuario, no de la app.

## Cómo se usa hoy

```bash
open -a Duplicate     # ⌘N, elegir carpeta, Empezar
```

El escaneo corre en la app con progreso —archivos vistos, hasheados, bytes leídos, aciertos de caché,
segundos— y se puede cancelar; un escaneo cancelado no deja documento. El paso a paso, con capturas, está en el
[manual de uso](docs/MANUAL.md).

Doble clic en un escaneo abre su revisión. En la revisión:

| Tecla | Qué hace |
|---|---|
| `espacio` | conserva o descarta el archivo bajo el cursor |
| `Enter` | confirma el grupo y avanza |
| `↑` `↓` | mueve el cursor |
| `⌘⏎` | confirma y avanza, desde el menú |
| `⌘⇧K` | salta el grupo sin decidir |
| `⌘[` `⌘]` | grupo anterior y siguiente |
| `⌘R` | muestra el archivo en Finder |
| — | el filtro de la barra lateral estrecha por tamaño y por "sin decidir"; estrechar no decide nada |
| — | selección múltiple + Grupo > Aceptar la sugerencia en los seleccionados (sin atajo, a propósito) |
| `⌘Z` | deshace la última decisión |
| `⌘S` | guarda las decisiones (también se guardan solas al simular y al cerrar) |
| `⌘⇧D` | simula y abre la hoja de aplicar — o el botón del pie |

Las decisiones se guardan en `decisions/<scan_id>.json`. **Solo se escriben los grupos que decidiste**: los que
saltaste y los que nunca abriste no aparecen, ni a favor ni en contra.

**⌘Z es deshacer de revisión, nunca de aplicación.** Deshacer una casilla y deshacer cuatro mil
archivos mandados a la Papelera no son el mismo acto; el deshacer de una sesión está en el menú Sesiones y en el
historial, y no tiene atajo.

## Qué detecta

Tres detectores:

| Detector | Criterio |
|---|---|
| Archivos exactos | SHA-256 idéntico |
| Carpetas | coeficiente de Dice sobre `{ruta relativa → digest}` |
| Media perceptual | pHash de imagen por distancia de Hamming; video por proporción de frames que coinciden |

## Dónde guarda lo que encuentra

```
$XDG_STATE_HOME/rav/duplicate/      (o ~/.local/state/rav/duplicate/)
├── scans/                  duplicados exactos
├── decisions/              qué conservar, por grupo
├── folder-scans/           carpetas parecidas
├── folder-decisions/
├── similar-scans/          imágenes y videos parecidos
├── similar-decisions/
└── journal/                qué se movió y a dónde, para poder deshacerlo
```

Documentos JSON legibles, escritos de forma atómica. Qué campos llevan, en qué orden y por qué el escritor de
JSON está hecho a mano: [`docs/FORMATO.md`](docs/FORMATO.md).

Aplicar manda a la Papelera real con `FileManager.trashItem` y registra cada movimiento en el journal. Eso da el
"Sacar del basurero" de Finder y un deshacer dentro de la app. Solo cuando el volumen no tiene Papelera, como un
montaje de red, mueve a una carpeta de cuarentena local.

## Decisiones de comportamiento

No son accidentes. Cada una arregla algo o evita un riesgo, y cada una cambia lo que se encuentra:

- **Los archivos ocultos se omiten por default.** Un grupo de 400 `.DS_Store` idénticos entierra todo hallazgo
  real. El panel de escaneo tiene un interruptor para incluirlos.
- **Los hardlinks se colapsan.** Dos hardlinks son un archivo; "borrar" uno no libera nada, así que proponerlo es
  mentir sobre el espacio recuperado.
- **Los clones de APFS se marcan como ya deduplicados**, no como duplicados a borrar. En volúmenes que no son APFS
  la cifra de espacio recuperable es una cota superior, y la app lo dice —con un `≤` delante del número, no
  redondeándola a un número confiado.
- **Los paquetes (`.app`, `.photoslibrary`, `.fcpbundle`) no se recorren por default.** Sacar un archivo de dentro
  de un bundle lo corrompe en silencio.
- **La Papelera y las carpetas de cuarentena se excluyen del recorrido**, así que escanear `~` dos veces no
  vuelve a encontrar lo que la primera vez acaba de mover.
- **Los grupos sin revisar no se deciden solos.** Solo se escriben los que decidiste, y aplicar actúa sobre esos.
- **Un archivo que comparte almacenamiento con el que conservas no se ofrece para borrar.** Su casilla está
  deshabilitada y la nota dice por qué.
- **Antes de mover nada, se verifica otra vez.** Un archivo exacto se vuelve a hashear, un par parecido se vuelve
  a puntuar, y una carpeta solo se mueve si cada archivo suyo —ocultos y paquetes incluidos— está idéntico en la
  que se conserva.

## Idiomas

Interfaz en inglés y español, según el idioma del sistema. No hay más idiomas y no está previsto
agregarlos. La salida del selftest es siempre en inglés: es diagnóstico para quien desarrolla, no UI.

## Desarrollo

```bash
make            # compila, arma y firma build/Duplicate.app
make run        # lo lanza por Launch Services
make test       # suite de DuplicateCore
make coverage   # tests + piso de cobertura del 80% sobre Core
make lint       # swift-format estricto, sin reescribir
make selftest-all
make help       # lista todos los targets
```

Cómo trabajar en el repo y qué exige un PR: [`CONTRIBUTING.md`](CONTRIBUTING.md). El catálogo de los
modos de selftest —que CI corre en cada PR— con la rotura exacta que hace fallar a cada uno:
[`docs/SELFTEST.md`](docs/SELFTEST.md).

## Si algo no funciona

| Síntoma | Causa |
|---|---|
| macOS pide permiso de carpetas después de cada rebuild | falta el certificado: `./scripts/make-signing-cert.sh` |
| "No se puede abrir porque Apple no puede comprobar…" | no está notarizada, a propósito. Clic derecho → Abrir |
| La app no lista escaneos que deberían estar | ¿`XDG_STATE_HOME` distinto del que se usó al escanear? `make selftest MODE=state-dir` imprime a dónde resolvió la app |
| Un escaneo sale marcado "rutas relativas" y no se puede revisar | lo escribió una herramienta de terminal con una raíz relativa; la app arranca con `/` como directorio de trabajo y no puede resolverlas |
| `make lint` pasa local y falla en CI | `swift-format` local es más nuevo que el del runner. No reformatear a ciegas |
| El escaneo se ve lento en un disco externo | a propósito: dos lectores concurrentes como tope. Más lectores en un disco que gira convierten lecturas secuenciales en tormenta de seeks |

## Lo que no está verificado

- **Que el selftest pase no dice nada sobre los permisos de la app.** Lanzada desde la terminal,
  macOS atribuye el acceso a archivos a la terminal, y la app hereda los permisos de ella. Lanzada
  por Launch Services, la app es su propio proceso responsable. Los dos hechos son verdad y ninguno
  implica el otro.
- El pHash de imágenes **no** es bit-idéntico al de `imagehash.phash` de Python. La forma del pipeline se
  reproduce, pero el resample de Pillow no es el de ImageIO, así que pares justo en el borde del umbral pueden
  aparecer en una implementación y no en la otra (la medición está arriba).
- El video se muestrea con `AVAssetImageGenerator`, sin ffmpeg. `.mkv` y `.avi` pueden no abrirse; el corpus
  real de este usuario es `.mp4` y `.mov`.
- **Los benchmarks son de un solo corpus, esta máquina.** Medido sobre datos reales:

  | Corpus | Archivos | Bytes | Frío | Caliente |
  |---|---|---|---|---|
  | `~/me/code` (SSD) | 10,506 | 664 MB | 0.11 s | — |
  | carpeta en USB externo | 696 | 245 GB | 0.61 s | — |
  | carpeta en USB externo | 15,242 | 806 GB | 130.2 s | 7.1 s (18.3×) |

  La de 245 GB tarda menos de un segundo porque ningún par de archivos comparte tamaño: el bucketing
  los descarta y no se lee un byte de contenido. La de 806 GB es donde sí hay trabajo. Nada de esto
  dice cómo se porta en un disco que gira, ni en un montaje de red.

## Arquitectura

El detalle y las alternativas que se descartaron están en
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Árbol de prueba

Para probar a mano sin tocar archivos reales. Lo único que ninguna herramienta puede verificar, **qué permisos
tiene la app de verdad**, tiene su guion corto al final de [`docs/SELFTEST.md`](docs/SELFTEST.md).

```bash
python3 scripts/make-demo-tree.py ~/demo-duplicate                  # el árbol chico, 7 grupos exactos
python3 scripts/make-demo-tree.py ~/demo-grande --carpeta-grande    # 4,000 archivos, para la barra con etapa
```

El árbol trae fixtures que existen para forzar casos que no salen solos: un clip de medio segundo, para que el
encabezado tenga que decir con cuántos cuadros juzgó; y un nombre con `||`, que es el separador de la clave de
decisiones y no aparece en ninguna ruta real. El grande va aparte porque 4,000 archivos compartidos serían
4,000 grupos exactos.

## Qué hace, capacidad por capacidad

[`docs/CAPACIDADES.md`](docs/CAPACIDADES.md) es el mapa de la app: **qué hace**, flujo por flujo y con cada
menú, atajo y opción; **qué no hace**, a propósito o porque está pendiente; y **qué sobra** — lo duplicado
entre los tres detectores, lo inalcanzable y lo muy especializado, con una recomendación para cada caso —
para que agregar o quitar funcionalidad se decida leyendo, no adivinando.

## Licencia

[GPL-3.0](LICENSE). Puedes usar, estudiar, modificar y redistribuir Duplicate. Si distribuyes una versión
modificada, tiene que ir bajo la misma licencia y con su código: nadie puede hacer de ella una app cerrada.

Hasta el 25 de octubre de 2026 el código se publicó bajo MIT, y las copias que se obtuvieron entonces conservan
esa licencia.
