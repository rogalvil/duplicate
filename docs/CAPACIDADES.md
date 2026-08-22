# Capacidades de Duplicate

Inventario de lo que la app **hace hoy**, con detalle suficiente para decidir qué agregar, qué quitar y qué
está duplicado. No es un plan ni una lista de deseos: cada entrada describe algo que existe y dice cómo se
verifica.

> **Se actualiza en cada PR**, junto con `README.md` y `docs/SELFTEST.md`. Una capacidad que cambia de forma
> o desaparece se edita aquí en el mismo cambio, o este archivo se convierte en la peor clase de
> documentación: la que suena autorizada y miente.

Última actualización: PR de cancelación dentro de un archivo. 39 modos de selftest, 762 tests, 94.60% de
cobertura sobre `DuplicateCore`.

## Resumen en una tabla

| | Escanear | Revisar | Decidir | Aplicar | Deshacer |
|---|---|---|---|---|---|
| **Exactos** (SHA-256) | sí | sí | sí | sí | sí |
| **Carpetas** (Dice) | sí | sí | sí | sí | sí |
| **Imágenes** (pHash) | sí | sí | sí | sí | sí |
| **Video** (frames) | sí | sí | sí | sí | sí |

Los tres detectores cierran el ciclo completo desde la app, sin el CLI, y sobre los mismos documentos JSON
que el CLI lee y escribe.

---

## 1. Detección de duplicados exactos

**Qué hace.** Recorre una raíz, agrupa por tamaño, y sobre cada grupo de candidatos calcula SHA-256 para
confirmar identidad byte a byte. El documento resultante es el mismo que escribe `rav duplicate scan`.

| Capacidad | Detalle | Dónde |
|---|---|---|
| Recorrido con reglas de skip | Oculto/paquete/cruce de volumen configurables; **no cruza puntos de montaje por default**, divergencia deliberada de `os.walk` | `Walk/DirectoryWalker.swift`, `Scan/ScanPolicy.swift` |
| Exclusión de Papelera **por identidad** | Cubre `~/.Trash` y las tres cuarentenas del CLI de una sola vez, incluso alcanzadas por symlink. Arregla un bug vivo del CLI | `Support/ExclusionSet.swift` |
| Agrupación por tamaño y luego digest | Ordenar-y-detectar-runs en vez de `defaultdict(list)`: cero allocation por bucket | `Scan/DuplicateFinder.swift` |
| Etapa de prefijo | Sonda cabeza+cola+tamaño antes del hash completo, **solo arriba de 8 MiB** (recalibrado midiendo: a 256 KiB cobraba 54% del tiempo y ahorraba 1 MB de 1.5 GB) | `Hash/ContentHasher.swift` |
| `F_NOCACHE` arriba de 1 MiB | Medido: 4× menos page cache (+0.10 GB contra +0.40 GB) al mismo tiempo de reloj | `Hash/ChunkedReader.swift` |
| Concurrencia acotada por volumen | NVMe interno `min(max(cpus-2,2),8)`; externo/rotacional 2; red 2. Ventana deslizante, no 800k tareas | `Runtime/IOConcurrencyPolicy.swift` |
| Clases de almacenamiento | Hardlinks y clones APFS se cuentan como **ya deduplicado**, no como duplicado ni se ocultan. El conjunto de acción nunca es `files[1:]` | `Model/StoragePartition.swift` |
| Progreso a 10 Hz por *pull* | Contadores atómicos leídos por un `Timer`, no 800k pushes | `Runtime/ProgressCounters.swift` |
| Cancelación | Por lote del recorrido, por archivo, **y entre chunks dentro de un archivo** | `Scan/DuplicateFinder.swift`, `Hash/ContentHasher.swift` |
| Caché de digests | Clave `(volumen, inodo, tamaño, mtime, generation)`, filas de 80 bytes con CRC-32C, `flock`, reparación de cola truncada | `Hash/HashCache.swift` |

**Cómo se verifica.** Modos `scan`, `cache`, `storage`, `digest`, `walk-permissions`, `trash-exclusion`,
`realroot`, `cancel`, `fdlimit`, `volumes`. El modo `digest` compara contra `shasum -a 256` en el tamaño de
chunk de producción.

## 2. Detección de carpetas duplicadas

**Qué hace.** Compara carpetas por coeficiente de Dice sobre el conjunto `{ruta relativa → digest}` de sus
archivos, y encuentra pares que son la misma colección con otro nombre.

| Capacidad | Detalle | Dónde |
|---|---|---|
| Un solo hasheo del árbol | El CLI hashea cada archivo una vez **por nivel de profundidad**; aquí es una pasada | `Folders/FolderSimilarity.swift` |
| Intervalos de Euler | Ancestro en O(1) entero, en vez de `relative_to` con try/except | `Folders/DirectoryTree.swift` |
| Candidatos por `(digest, basename)` | Con prueba de completitud: ningún par sobre umbral positivo se pierde | `Folders/FolderSimilarity.swift` |
| Poda por tamaño | De Dice ≥ t sale `|B|/|A| ≤ (2−t)/t`; a t=0.9 descarta todo par que difiera >22% en conteo | `Folders/DiceBounds` |
| Orientación por bytes | `folder_a` es la ruta menor. **No es cosmético**: `folders-move` del CLI borra `folder_b`. Medido contra el CLI: mismo conjunto de 42 pares, los 42 al revés antes del arreglo | `Folders/FolderSimilarity.swift` |
| Diferencias materializadas | `only_in_a`, `only_in_b`, `changed` solo para los pares que sobreviven | `Folders/FolderSimilarity.swift` |
| Canonicalización de rutas | Parte por `/` los dos lados; nada de case folding, Unicode ni symlinks | `Folders/DirectoryTree.canonical` |

**Cómo se verifica.** Test diferencial contra fuerza bruta sobre árboles aleatorios (conjuntos, conteos y
floats idénticos), más el CLI real como oráculo sobre un árbol real. Modos `folder-window`, `folder-apply`.

## 3. Detección perceptual: imágenes

**Qué hace.** Encuentra imágenes que se **parecen** aunque no sean idénticas: recomprimidas, escaladas,
recortadas de más.

| Capacidad | Detalle | Dónde |
|---|---|---|
| pHash de 64 bits | Grises estilo Pillow (**redondeado**, medido) → Lanczos-3 a mano → cuantizar a `UInt8` → DCT de Accelerate → recorte 8×8 con DC → mediana → `>` estricto | `Media/PerceptualHash.swift` y vecinos |
| DCT que cancela exacto | Solo `vDSP.DCT` lo hace; con matriz de la base una imagen plana prende **32 bits en vez de 1** | `Media/CosineTransform.swift` |
| Decode a 256 px | Barrido de 128 a 4096: los pares encontrados no se mueven (0.1% de rango). Pedir 32 px a ImageIO es un desastre (10.9% de coincidencia) | `Media/ImageHasher.swift` |
| Orientación EXIF aplicada | Divergencia deliberada contra Pillow: una copia que solo cambia el flag **debe** coincidir con su original | `Media/ImageHasher.swift` |
| Índice LSH multi-banda | `T+1` bandas por palomar (6 de 11,11,11,11,10,10 a T=5); colapso de hashes idénticos en clases (2,779 fotos → 1,630 clases) | `Media/MultiIndexLSH.swift` |
| Caché perceptual | Filas de 112 bytes, salt **derivada de los parámetros del pipeline**, CRC, `flock`, reparación. **177 s → 0.5 s** medido | `Media/PerceptualCache.swift` |

**Coincidencia con `imagehash`.** Medida sobre las 2,779 fotos reales del usuario: **90.9% de hashes
idénticos** entre las 2,761 sin rotación, peor caso **4 bits**, **96.7% de Jaccard** entre los conjuntos de
pares, y **cero pares** que una implementación llame casi idénticos y la otra ajenos.

**Cómo se verifica.** Modos `phash`, `phash-differential` (con referencia generada por
`scripts/phash-reference.py`), `similar-window`, `similar-apply`.

## 4. Detección perceptual: video

| Capacidad | Detalle | Dónde |
|---|---|---|
| Ocho cuadros por video | `interval = max(dur/(n+1), 0.1)`, cuadros en `interval·(i+1)` — **aritmética preservada exacta** porque el umbral 0.70 se calibró contra ella | `Media/VideoFrameSampler.swift` |
| Sin `ffmpeg` | `AVAssetImageGenerator` con `requestedTimeTolerance`, que **es** la rama de fast-seek del CLI, y `.forceSDR` para que un HDR no hashee distinto | `Media/VideoHasher.swift` |
| Marcas pasadas del final filtradas | Medido: con tolerancia de 1 s un clip de 0.4 s devolvía **ocho** hashes con el último cuadro repetido cuatro veces | `Media/VideoFrameSampler.swift` |
| Similitud asimétrica y codiciosa preservada | Con la orientación fijada por bytes, o el mismo par cae de los dos lados del umbral entre corridas | `Media/VideoSimilarity.swift` |
| Cuatro decodes a la vez | Medido, no elegido: 60 videos reales dieron 213 ms en serie, 151 ms con cuatro, **151 ms con ocho** | `Media/SimilarScanSession.swift` |
| Comparación por pares, sin LSH | El LSH indexa hashes sueltos; el video compara *listas*. 617 videos = 190,036 pares de popcounts, barato | `Media/SimilarScanSession.swift` |

## 5. Revisión y decisiones

| Capacidad | Detalle |
|---|---|
| Tri-estado | Un grupo sin revisar **no se escribe** en el archivo de decisiones. El CLI escribe los 50 al salir en el grupo 1; la ausencia de la clave es el contrato |
| Heurística de keeper | Gana el archivo **más profundo** que no parece copia. Batch e interactivo eligen el mismo |
| Regex de nombres-copia | Portado del CLI con su falso positivo sobre `IMG_1234` preservado a propósito, y con el espacio escrito `\x20` porque ICU lo borra dentro de una clase |
| ⌘Z real | Snapshot del estado completo, `groupsByEvent = false`, agrupamiento explícito, y `windowWillReturnUndoManager` para que el menú Edición lo alcance. En las **tres** revisiones |
| Filtros y decisión en lote | Se filtra, y se acepta **exactamente lo que está en pantalla**, con conteo de archivos y bytes dicho antes. No existe un botón que decida todo |
| Contradicciones reportadas | Con (a,b) `keep_a` y (b,c) `keep_a`, el primero borra `b` y el segundo lo conserva. Se reporta al cerrar, no se resuelve |
| Consejo de media | Tráiler antes que calidad (un tráiler HEVC de 30 s **le gana en puntuación** a la película de dos horas), codec desconocido vale 1.0 **y se marca** |
| Avisos al decidir, no al aplicar | Un par de carpetas dice "mover la segunda perdería 5 archivos" *mientras eliges* |
| Presencia de archivos | El panel distingue "el archivo ya no está" de "la miniatura no llega". Se refresca también al deshacer |
| Miniaturas | Clave por digest en grupos exactos (ocho archivos idénticos = **una** miniatura) y **por ruta** en pares perceptuales, donde son fotos distintas |

## 6. Acción destructiva y deshacer

| Capacidad | Detalle |
|---|---|
| Papelera real | `trashItem` da el "Devolver" de Finder gratis. Medido: funciona en los tres volúmenes de esta máquina, y también en FAT32 |
| Cuarentena como fallback | Para montajes de red. **Medido: no rescata un volumen de solo lectura**, porque mover fuera de uno tiene que borrar el origen |
| Verificar antes de actuar | Exactos: se re-hashea contra el digest del escaneo. Perceptual: se **re-puntúa el par** (un escaneo perceptual no guarda digests). Carpetas: **contención**, no similitud — cada archivo necesita gemelo byte-idéntico en la misma ruta relativa |
| Compuerta de dry-run | Aplicar exige una simulación **vigente**: editar una decisión invalida la aprobación, comparada por huella FNV-1a (no el `Hasher` de Swift, que está sembrado por proceso) |
| Journal JSON Lines | Lotes de 32 durante el apply, no al final. Un `undone_at` se **agrega**, no reescribe |
| Deshacer sesión | Ocupante byte-idéntico cuenta como ya restaurado; cualquier otro **bloquea**, nunca sobrescribe. Se re-chequea justo antes de mover |
| Colapso de pares anidados | `Pole ↔ Pole` y `Pole/videos ↔ Pole/videos` son pares separados en el corpus real; mover el padre se lleva al hijo |
| Cancelar devuelve reporte | No lanza: lanzar se saltaba el flush y dejaba hasta 31 archivos movidos **sin entrada en el journal** |
| Detener sigue vivo durante el apply | Cerrar la hoja mientras corre **detiene y no cierra** |
| Etapa en el progreso | `verifying(filesChecked:)` / `moving` / `done`, porque verificar un par de carpetas digiere miles de archivos antes de mover nada |
| Veinte fallas seguidas detienen | Una sola no: un archivo bloqueado no aborta los otros 3,997 |
| Cancelación no acusa | Una cancelación nunca se reporta como archivo ilegible, ni como carpeta ilegible, ni como "estas dos carpetas difieren" |

## 7. Biblioteca, ventanas y sistema

| Capacidad | Detalle |
|---|---|
| Biblioteca de escaneos | Los cuatro tipos, con badge de origen (CLI o app), orden y filtro, y **watcher por directorio** de los cuatro |
| Carga en segundo plano | `summaries()` decodifica 21,594 grupos en 0.34 s; va fuera del hilo principal con contador de generación |
| Escaneo con progreso | Panel con fase, conteos de dígitos monoespaciados, raíces recientes y cancelación |
| Quick Look | Con plazo de 2 s: `quicklookd` es XPC y puede colgarse; se cae al icono del archivo |
| Menús | Atajos sin colisiones (verificado por el modo `menu`), Sesiones de primer nivel, deshacer de apply **sin atajo de teclado** |
| `RLIMIT_NOFILE` | Launch Services arranca con 256 blando; se sube a 4096 antes de abrir nada |
| Directorios inaccesibles | Se cuentan y se reportan; nunca se lee "no encontré duplicados" cuando fue "no pude entrar" |
| Ciclo de vida | Cerrar la última ventana cierra la app; un clic en el Dock o un `open` traen la biblioteca de vuelta |

## 8. Interop con el CLI

| Capacidad | Detalle |
|---|---|
| JSON byte-idéntico | `\uXXXX` para no-ASCII, `1.0` para doubles enteros, indent 2, orden de inserción, `\n` final. Encoder a mano porque Foundation falla en las cinco cosas |
| Seis formatos | `scans`, `decisions`, `folder-scans`, `folder-decisions`, `similar-scans`, `similar-decisions` — **tres formas distintas de documento de decisiones**, no una |
| Orden por bytes UTF-8 | `PathOrder`. El `String ==` de Swift considera iguales NFC y NFD y el de Python no; el corpus real tiene 38 rutas solo-NFD y 10 solo-NFC |
| Escrituras atómicas | Mejora estricta sobre el `write_text` del CLI, sin impacto de formato |
| Round-trip verificado | Modos `json-roundtrip` (crudo) y `scans` (por el modelo tipado), contra los 226 documentos reales |

**Divergencias declaradas**: la app manda a la Papelera y journaliza, el CLI mueve a cuarentena. La app
encuentra *menos* grupos (salta ocultos, no cruza volúmenes, separa clases de almacenamiento) y elige otros
sobrevivientes que `rav duplicate move`.

## 9. Verificación

| Mecanismo | Alcance |
|---|---|
| 762 tests unitarios | Solo `DuplicateCore`, piso de cobertura 80%, hoy 94.60% |
| 39 modos de selftest | Contra el bundle armado y firmado. Cada uno **afirma** y cada uno lleva escrita la rotura que lo hace fallar |
| CI | Todos los modos en cada PR, con `CONFIG=debug`, antes del paso de cobertura |
| Oráculos externos | `shasum` para digests, el CLI real para carpetas, `imagehash` para el pHash |

---

## Solapamientos y candidatos a revisión

Sin actuar sobre ellos: es la lista para decidir después.

**Código escrito para reportar algo que nadie reporta.** Cuatro piezas calculan un dato útil que ninguna
ventana muestra ni ningún reporte incluye. Cada una tiene test y comentario explicando por qué el número
importa, lo que las hace peores que código muerto: parecen una capacidad.

| Pieza | Qué calcula | Quién lo usa |
|---|---|---|
| `HashCache.verify(_:against:)` | Si un digest guardado sigue coincidiendo con el disco | **Nadie.** `VerifyingDisposer` hace su propia verificación |
| `VideoSimilarity.directionsDisagree` | Cuántos pares cambian de lado del umbral al invertir la comparación | **Nadie.** Su doc dice "reportado para que quien llame pueda contarlos" |
| `SimilarPairKey.isAmbiguous` | Si una ruta contiene `||` y rompería la clave | **Nadie.** `CLAUDE.md` afirma que "lo reporta en vez de esconderlo", y no hay quien lo reporte |
| `VideoFrameSampler.usableCount` | Cuántas de las ocho marcas caen dentro del video | **Nadie.** Escrito para avisar "este clip se juzgó con tres cuadros" |

**Otros puntos a decidir:**

- **`folder-decisions/` no tiene lector externo.** El CLI tiene el slot y nunca escribió uno, así que su
  round-trip se prueba contra un documento sintetizado. La app lo escribe y lo lee.
- **`PerceptualHash(hex:)` y `hexString` solo existen para el diferencial** y los tests: ningún hash
  perceptual aparece en el JSON compartido. Es deuda barata y deliberada (hace depurable un desacuerdo
  contra Python), pero es superficie pública que producción no usa.
- **`FolderManifest.buildSynchronously` tiene un solo llamador** (el planificador de deshacer) y una
  semántica distinta de la versión async: sin checkpoint de cancelación. Dos funciones que se ven iguales y
  no lo son.
- **Dos ramas del disposer no son alcanzables** con un `FileManager` real y están marcadas como tal.
- **El montaje de red es el único caso que la cuarentena rescata de verdad**, y es el camino menos probado
  del código destructivo. No se puede fabricar aquí sin servidor.

## Deuda conocida

- **Sin poda de entradas de archivos borrados** en las dos cachés. Crecen una fila por cada (archivo,
  versión) visto. Medido: 532 KB tras 119 escaneos, en un directorio que macOS puede purgar. Podar por
  existencia se rechaza con número: el corpus vive en un disco externo y desmontado *todas* sus entradas se
  verían muertas.
- **Sin compactación ni poda del journal.** Un archivo por sesión, para siempre, en el directorio
  compartido. Podarlo destruye la capacidad de deshacer, así que la regla tendría que ser explícita.
- **Barrido de concurrencia en frío sin medir** (`sudo purge`, necesita root). El barrido caliente no tiene
  codo hasta c=16, pero mide SHA-256, no disco, así que la política enviada **no se cambió**.
- **`ContentHasher.fullDigest` corta entre chunks, no dentro de uno.** El límite es una lectura de 1 MiB.
- **Los fallos de un apply se renderizan interpolando el enum**, no localizados.
