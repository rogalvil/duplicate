# Mapa de Duplicate

Contesta tres preguntas, en este orden: **qué hace la app hoy**, **qué no hace** —a propósito o porque está
pendiente— y **qué sobra**: lo redundante, lo inalcanzable y lo muy especializado.

Todo lo de aquí se sacó leyendo el código, no documentos anteriores. La versión previa de este archivo se
contradecía a sí misma (dos conteos de tests distintos, "sin poda de cachés" junto a "poda de cachés"), y es la
razón de la regla de abajo.

> **Se actualiza en el mismo PR que cambia la funcionalidad.** Una capacidad que cambia de forma o desaparece
> se edita aquí en ese cambio. Y **no lleva números que cambian en cada PR** —tests, modos, cobertura—: esos se
> piden al código (ver [Cómo mantener este mapa](#cómo-mantener-este-mapa)).

## En una página

Tres detectores, y los tres cierran el ciclo completo desde la app, sobre documentos JSON en
`~/.local/state/rav/duplicate/` (formato en [`FORMATO.md`](FORMATO.md)):

| | Escanear | Revisar | Decidir | Simular y aplicar | Deshacer |
|---|---|---|---|---|---|
| **Exactos** (SHA-256) | sí | sí | sí | sí | sí |
| **Carpetas** (Dice) | sí | sí | sí | sí | sí |
| **Parecidos: imágenes** (pHash) | sí | sí | sí | sí | sí |
| **Parecidos: video** (cuadros) | sí | sí | sí | sí | sí |

El recorrido de quien la usa:

```
Biblioteca ──⌘N──► Nuevo escaneo ──► Biblioteca (fila nueva)
    │
    └─ doble clic ─► Visor del detector ──► Simular y aplicar (hoja) ──► Papelera + journal
                       exacto / carpetas / parecidos                          │
                                                                              ▼
                                                     Sesiones: deshacer, historial, limpiar
```

---

## 1. Qué hace, flujo por flujo

Lo que alguien puede alcanzar en pantalla, con el nombre que tiene en la UI en inglés. Los nombres de archivo
son de `Sources/Duplicate/` salvo que digan otra cosa.

### 1.1 Arranque y ciclo de vida

| Qué | Cómo se llega | Qué hace |
|---|---|---|
| Biblioteca | lanzar la app | Es la ventana inicial ("Scans") |
| La biblioteca vuelve | cerrar la última ventana que no es la biblioteca | La reabre. Las hojas y los paneles no cuentan como ventana |
| Salir al cerrar | cerrar la biblioteca sin otra ventana abierta | La app termina |
| Reabrir | clic en el Dock, o `open` | Trae la biblioteca |
| ⌘Q durante un apply | ⌘Q | No sale: mientras la hoja de aplicar está abierta, macOS rechaza la salida. Cerrarla primero (#145) |
| Límite de descriptores | invisible | Sube `RLIMIT_NOFILE` de 256 a 4096 antes de abrir nada |
| About | Duplicate > About Duplicate | Versión, número de build, commit, y aviso si el árbol estaba sucio al compilar |

No hay arrastrar y soltar, ni ventana de preferencias, ni menú de ayuda.

### 1.2 Menús y atajos

| Menú > ítem | Atajo | Dónde funciona |
|---|---|---|
| File > New Scan… | ⌘N | En todas partes |
| File > Save Decisions | ⌘S | Solo revisión exacta. Los otros dos visores guardan solos |
| File > Close | ⌘W | En la exacta pregunta si guardar |
| Edit > Undo / Redo | ⌘Z / ⇧⌘Z | Deshacer de **revisión**, nunca de un apply. Un `UndoManager` por visor |
| View > Quick Look | ⌘Y | Los tres visores |
| View > Show File Metadata | ⌥⌘I | Preferencia global, los tres visores |
| Group > Confirm and Next | ⌘↩ | Solo exacta |
| Group > Skip This Group | ⇧⌘K | Solo exacta |
| Group > Clear the Decision | — | Solo exacta |
| Group > Accept the Suggestion for Selected Groups… | — | Solo exacta, con confirmación |
| Group > Keep Every File | — | Solo exacta |
| Group > Discard the Whole Group… | — | Solo exacta, con confirmación |
| Group > Previous / Next Group | ⌘[ / ⌘] | Solo exacta |
| Group > Show in Finder | ⌘R | Exacta: el archivo. Parecidos: **los dos**. Carpetas: abre las dos |
| Group > Simulate Applying… | ⇧⌘D | Solo exacta. Los otros dos tienen botón y no atajo |
| Sessions > Undo the Last Session… | — | Sin atajo a propósito: deshacer cuatro mil archivos no es ⌘Z |
| Sessions > Session History… | — | Abre el historial |
| Sessions > Clean Up Undone Sessions… | — | Borra journals de sesiones ya devueltas, con confirmación |

El menú Group siempre está en la barra; fuera de la revisión exacta todo sale gris salvo Show in Finder.

### 1.3 Biblioteca

| Qué | Cómo se llega | Qué hace |
|---|---|---|
| Detector | segmentado Files / Folders / Images | Cambia columnas y fuente de la tabla |
| New Scan | botón (+) | Abre el panel de escaneo; uno a la vez |
| Review | botón, o doble clic en la fila | Abre el visor del detector; uno por escaneo, y si ya está abierto lo trae al frente |
| Refresh | botón | Relee el disco |
| Ordenar | Newest / Oldest / Most groups / Most reclaimable | **Solo pestaña Files** |
| Filtrar | por carpeta o scan id, sin distinguir mayúsculas ni acentos | **Solo pestaña Files** |
| Menú contextual | clic derecho | Review, Open Scanned Folder, Show Scan File in Finder, Copy Scan ID, Delete This Scan…, en las tres pestañas |
| Delete This Scan… | menú contextual | Borra el documento del escaneo y sus decisiones, no los archivos |
| Columnas Files | — | carpeta, fecha, grupos, archivos, recuperable (`≤ X` cuando es cota), estado (Reviewed / Relative paths) |
| Columnas Folders | — | carpeta, fecha, umbral %, pares, carpetas, estado |
| Columnas Images | — | carpeta, fecha, pares de imagen, pares de video, archivos, umbral en bits, estado |
| Se actualiza sola | — | Vigila `scans/`, `decisions/`, `folder-scans/` y `similar-scans/`: un documento escrito por otro proceso aparece sin tocar nada |
| Origen | — | Lista todo documento válido del directorio, lo haya escrito la app o no |

### 1.4 Nuevo escaneo

Opciones, con su default. Ninguna se recuerda entre aperturas salvo las carpetas recientes:

| Opción | Default | Aplica a |
|---|---|---|
| Look for: Identical files / Similar folders / Similar images | Identical files | — |
| Umbral de carpetas: 95 / 90 / 80 / 70 % | **90 %** | carpetas |
| Umbral de imágenes: 0 / 2 / 5 / 10 bits | **5 bits** | parecidos |
| Include videos (slower) | sí | parecidos |
| Recent… | hasta 10 carpetas que todavía existen | todos |
| Choose Folder… | sin carpeta; Start gris hasta elegir | todos |
| Include hidden files | no | todos |
| Look inside packages | no | todos |
| Use the hash cache | sí | los tres detectores |
| Ignore files smaller than | 1 B: los archivos vacíos no cuentan | todos |

Fijo y sin control en pantalla: umbral de video 0.70; **no cruza volúmenes**; se excluyen la Papelera, las
cuarentenas y `~/Library` (salvo que la raíz esté dentro); extensiones de parecidos `jpg jpeg png webp gif` y
`mp4 mov avi mkv m4v`.

Durante el escaneo: fase (Listing files, Comparing candidates, Reading contents, Grouping, **Saving**, Done),
contadores a 10 Hz y la ruta actual. Cancelar no deja documento; cerrar la ventana también cancela.

Al terminar:

| Detector | Qué pasa | Aviso de carpetas que no se pudieron leer |
|---|---|---|
| Exactos | Selecciona el escaneo nuevo, sin cambiar de pestaña | sí, con el conteo |
| Carpetas | Cambia a la pestaña Folders, sin seleccionar | sí, con el conteo |
| Parecidos | Cambia a Images, sin seleccionar; avisa imágenes ilegibles | sí, con el conteo |

El aviso tiene un solo botón: el que abría Acceso Total al Disco se quitó en #163.

### 1.5 Revisión exacta

| Qué | Cómo se llega | Qué hace |
|---|---|---|
| Lista de grupos | barra lateral, selección múltiple | Estado de cada grupo (✓ decidido / ✗ saltado / → actual), tamaño y conteo |
| Encabezado | — | Carpeta común y "Group i of N — frees X / up to X" |
| Aviso | — | Por prioridad: ya no es duplicado, cambió desde el escaneo, nada conservado, almacenamiento compartido, nada decidido aún, último grupo |
| Tabla de archivos | — | Keep (casilla), File (truncado al medio) y Note (gone, changed, unreadable, same storage as the keeper, looks like a copy) |
| Conservar / descartar | espacio, o clic en la casilla | Pita si dejaría el grupo sin nada |
| Confirmar | botón Confirm and Next, ⏎ con la lista enfocada, o ⌘↩ | Graba y avanza |
| Vista previa | — | Miniatura, nombre, ruta completa, tamaño y fecha |
| Filtros | barra lateral | Tamaño mínimo, "Not decided yet", "Still on disk" |
| Check the disk | botón (Cancel mientras corre) | Hace `stat` de todo el escaneo en segundo plano y guarda el resultado con su fecha |
| Decisiones importadas | al abrir, si el archivo de decisiones trae una para cada grupo (5 o más) | Keep Them / Start Over; Start Over se puede deshacer |
| Pie | — | Simulate and Apply…, y "N decididos · N saltados · N sin mirar · X se liberarían" |
| Guardar | ⌘S, al simular, o al cerrar | Escribe **solo** los grupos decididos |

La sugerencia del heurístico sale preseleccionada: gana el archivo **más profundo** que no parece copia.
Confirmar es lo que la vuelve decisión.

### 1.6 Visor de carpetas

| Qué | Cómo se llega | Qué hace |
|---|---|---|
| Tabla de pares | — | % parecido, carpeta, contra cuál, archivos iguales, diferencias, decisión |
| Encabezado | — | "N % alike — N files identical — N against N files" |
| Metadata | ⌥⌘I | Nombre, conteo y fecha por lado. El tamaño no está: una carpeta no tiene uno propio |
| Detalle | — | Solo en A, solo en B, mismo nombre con otro contenido |
| Aviso de pérdida | — | "Mover la segunda perdería N archivos que la primera no tiene", mientras eliges |
| Decidir | botones Keep the first / Keep the second / Keep both / Skip | Graba, guarda y avanza |
| Simular | botón Simulate and apply… | Abre la hoja de aplicar |
| Abrir carpetas | doble clic (A), menú contextual (A o B), ⌘R (las dos) | Finder |

### 1.7 Visor de parecidos

| Qué | Cómo se llega | Qué hace |
|---|---|---|
| Filtros | arriba | % mínimo (any / 90 / 95 / identical), tipo (imágenes, videos, ambos), "Not decided yet" |
| Accept the N shown | botón | Acepta la sugerencia de **exactamente** lo que está en pantalla, diciendo antes archivos y bytes |
| Tabla | — | % parecido, tipo, decisión, archivo, contra cuál |
| Encabezado | — | Imagen: bits que difieren de 64. Video: % de cuadros que coinciden, y "judged on N of 8 frames" si son menos |
| Dos lados | — | Miniatura, nombre, ruta, metadata (tamaño, fecha, resolución, codec, duración) y "this file is no longer there" |
| Sugerencia | — | "Suggested: … — razón" (tráiler, codec, bitrate, profundidad); el botón sugerido es el default |
| Decidir | botones Keep the first / Keep the second / Keep both / Discard both (rojo) / Skip | Graba, guarda y avanza |
| Al cerrar | — | Avisa contradicciones entre pares y claves `a\|\|b` que no se pueden volver a partir |

### 1.8 Simular y aplicar

Una hoja por detector, con la misma forma:

| | Exactos | Carpetas | Parecidos |
|---|---|---|---|
| Qué dice la simulación | archivos y **bytes** que se liberarían | carpetas que se moverían | archivos y de cuántos pares |
| Qué verifica antes de mover | re-hash contra el digest del escaneo | **contención**: cada archivo con gemelo byte-idéntico en la misma ruta relativa, ocultos, paquetes y vacíos incluidos; solo el ruido de Finder (`.DS_Store`) queda fuera | **re-puntúa** el par contra el umbral |
| Qué excluye y nombra | — | pares anidados colapsados, contradicciones | contradicciones |
| Durante | Verifying / Moving N of N, Stop | igual, más archivos revisados | igual |
| Después | movidos, fallas, rehúsas, aviso de cuarentena | igual | igual |
| Deshacer desde la hoja | Undo This Session | igual | igual |

En los tres: aplicar exige una simulación **vigente** (editar una decisión la invalida); va a la Papelera real,
con cuarentena local si el volumen no tiene Papelera (montajes de red); el journal se escribe en lotes de 32;
veinte fallas seguidas detienen; cancelar devuelve reporte de lo que sí se movió.

### 1.9 Deshacer, historial y limpieza

| Qué | Cómo se llega | Qué hace |
|---|---|---|
| Undo the Last Session… | menú Sessions | Restaura la sesión más nueva que todavía tiene algo que devolver; si no queda ninguna, lo dice |
| Session History… | menú Sessions | Una fila por apply: fecha, archivos, tamaño, estado (moved / all put back / N of M put back), escaneo |
| Undo This Session… | botón en el historial | Deshace **cualquier** sesión, no solo la última |
| Clean Up… / Clean Up Undone Sessions… | botón o menú | Borra journals cuyos archivos ya volvieron **todos**; nunca uno ilegible o vacío |

Deshacer nunca sobrescribe: una ruta ocupada por contenido idéntico cuenta como ya devuelta, y cualquier otra
cosa se bloquea y se dice por qué.

### 1.10 Lo que la app recuerda

| Qué | Dónde |
|---|---|
| Mostrar metadata (única preferencia) | `UserDefaults`, encendida por default |
| Carpetas recientes (hasta 10) | `~/Library/Application Support/com.rogalvil.duplicate/` |
| Tamaño de ventana | biblioteca, revisión exacta y carpetas; **el visor de parecidos no** |
| Resultado del chequeo de disco | `~/Library/Caches`, por clave de grupo |
| Cachés de digests y de hashes perceptuales | `~/Library/Caches` |
| Escaneos, decisiones y journals | `~/.local/state/rav/duplicate/` ([`FORMATO.md`](FORMATO.md)) |

---

## 2. Los tres visores, lado a lado

Hacen lo mismo —revisar, decidir, simular— con controles distintos. Esta tabla es la que conviene leer antes de
tocar cualquiera de los tres.

| Capacidad | Exacto | Carpetas | Parecidos |
|---|---|---|---|
| Cómo se decide | casillas + Confirm (menú y atajos) | botones | botones |
| Filtros | tamaño, sin decidir, sigue en disco | **ninguno** | %, tipo, sin decidir |
| Aceptar en lote | menú, sobre grupos seleccionados | **no** | botón, sobre lo visible |
| ⌘Z | todo | todo | todo |
| Saltar | solo ⇧⌘K | botón | botón |
| Borrar la decisión | menú | **no** | **no** |
| Anterior / siguiente | ⌘[ ⌘] | flechas de la tabla | flechas de la tabla |
| ⏎ | confirma | nada | acepta la sugerencia |
| Doble clic | revela el archivo | abre A | revela **solo A** (⌘R revela los dos) |
| Guardar | ⌘S, al simular, al cerrar; **sin decisiones no escribe**, así que el archivo anterior sobrevive | automático, escribe vacío a propósito; la falla sale primero en el pie, en naranja | automático, igual |
| Agrupa el deshacer a mano | **no** (por evento) | sí | sí |
| Avisa decisiones importadas (una por cada grupo o par) | sí | **no** | sí |
| Pregunta al cerrar | sí | no | no (sí avisa contradicciones) |
| Simular | botón y ⇧⌘D | botón | botón |
| ⌘Q protegido durante el apply | sí, por la hoja | sí, por la hoja | sí, por la hoja |
| Nota de cuarentena tras el apply | sí | sí | sí |
| Biblioteca: ordenar, filtrar, badge "Reviewed" | sí | **no** | **no** |
| Biblioteca: menú contextual | sí | sí | sí |
| Aviso de carpetas sin permiso al escanear | sí | sí | sí |
| "Terminado" solo después de guardar | sí | sí | sí |

Casi todos los **no** de esta tabla no son decisiones: son la misma pieza escrita tres veces, arreglada en una.
La sección 5 cuenta cuántas líneas cuesta eso.

---

## 3. Cómo funciona por dentro

El detalle técnico de lo de arriba, con lo que se midió para decidirlo. El *por qué* largo vive en
[`ARCHITECTURE.md`](ARCHITECTURE.md); las trampas de cada área, en `.claude/rules/`.

### 3.1 Duplicados exactos

| Mecanismo | Detalle | Dónde (`Sources/DuplicateCore/`) |
|---|---|---|
| Recorrido con reglas de skip | Oculto, paquete y cruce de volumen configurables; **no cruza puntos de montaje por default** | `Walk/DirectoryWalker.swift`, `Walk/ScanPolicy.swift` |
| Exclusiones por identidad | Papelera, cuarentenas y `~/Library`, incluso alcanzadas por symlink o firmlink | `Walk/ExclusionSet.swift` |
| Directorios inaccesibles | Se cuentan; nunca se lee "no encontré duplicados" cuando fue "no pude entrar" | `Walk/DirectoryWalker.swift` |
| Agrupar por tamaño y luego digest | Ordenar y detectar runs, sin allocation por bucket | `Scan/DuplicateFinder.swift` |
| Etapa de prefijo | Sonda cabeza + cola **solo arriba de 8 MiB**. Sobre 80 archivos de 64 MiB del mismo tamaño: 0.03 s contra 1.75 s | `Hash/ContentHasher.swift` |
| `F_NOCACHE` arriba de 1 MiB | 4× menos page cache al mismo tiempo de reloj | `Hash/ChunkedReader.swift` |
| Concurrencia por volumen | Interno `min(max(cpus-2,2),8)`, externo y red 2. La curva medida es plana de c=1 a c=16 | `Runtime/IOConcurrencyPolicy.swift` |
| Clases de almacenamiento | Hardlinks y clones APFS cuentan como **ya deduplicado**. El conjunto de acción nunca es `files[1:]` | `Model/StoragePartition.swift` |
| Cancelación | Por lote del recorrido, por archivo y entre chunks de 1 MiB | `Scan/DuplicateFinder.swift`, `Hash/ContentHasher.swift` |
| Caché de digests | Clave `(volumen, inodo, tamaño, mtime, generation)`, CRC, `flock`, reparación de cola truncada y poda de filas cuyo archivo ya no existe. En memoria es una tabla ordenada, no un diccionario | `Hash/HashCache.swift`, `Hash/DigestTable.swift` |
| Fases honestas | `.finished` se marca después de guardar, no antes | `Scan/ScanSession.swift` |
| Memoria a escala | 800,000 archivos en 336–371 MB (caché fría) y 356–362 MB (caliente), contra 897–955 antes de #161: `FileEntry` de 72 B, ninguna lista de todos los archivos vive más que la siguiente | `Scan/DuplicateFinder.swift`, `Model/FileEntry.swift` |

### 3.2 Carpetas

| Mecanismo | Detalle | Dónde |
|---|---|---|
| Un solo hasheo del árbol | Cada archivo se hashea una vez, no una por cada nivel de carpetas que lo contiene | `Folders/FolderSimilarity.swift` |
| Intervalos de Euler | Ancestro en O(1) | `Folders/DirectoryTree.swift` |
| Candidatos por `(digest, basename)` | Con prueba de completitud | `Folders/FolderSimilarity.swift` |
| Poda por tamaño | A t=0.9 descarta todo par que difiera más de 22% en conteo | `Folders/FolderSimilarity.swift` |
| Orientación por bytes | `folder_a` es la ruta menor, así que el documento sale igual sin importar el orden del recorrido | `Folders/FolderSimilarity.swift` |
| Clase patológica truncada | 10,000 archivos idénticos con el mismo nombre se cortan y se nombran | `Folders/FolderSimilarity.swift` |

### 3.3 Parecidos: imágenes

| Mecanismo | Detalle | Dónde |
|---|---|---|
| pHash de 64 bits | Grises estilo Pillow (redondeado) → Lanczos-3 → `UInt8` → DCT de Accelerate → 8×8 → mediana | `Media/PerceptualHash.swift` y vecinos |
| Decode a 256 px | El barrido de 128 a 4096 no mueve los pares encontrados | `Media/ImageHasher.swift` |
| Orientación EXIF aplicada | Divergencia deliberada contra Pillow | `Media/ImageHasher.swift` |
| Índice LSH | `T+1` bandas por palomar; hashes idénticos colapsados en clases | `Media/MultiIndexLSH.swift` |
| Caché perceptual | Salt derivada de los parámetros del pipeline, CRC, `flock`, poda. 177 s → 0.5 s | `Media/PerceptualCache.swift` |

Contra `imagehash`, sobre 2,779 fotos reales: 90.9% de hashes idénticos, peor caso 4 bits, y ningún par que una
implementación llame casi idéntico y la otra ajeno. Lo vuelve a medir el modo `phash-differential`.

### 3.4 Parecidos: video

| Mecanismo | Detalle | Dónde |
|---|---|---|
| Ocho cuadros | `interval = max(dur/(n+1), 0.1)`; la aritmética no se toca porque el umbral 0.70 se calibró contra ella | `Media/VideoFrameSampler.swift` |
| Sin `ffmpeg` | `AVAssetImageGenerator` con tolerancia: ~0.62 s por video de 10 MB a 1 GB | `Media/VideoHasher.swift` |
| Similitud asimétrica preservada | Con la orientación fijada por bytes | `Media/VideoSimilarity.swift` |
| Comparación por pares, sin LSH | Popcounts sobre listas de cuadros | `Media/SimilarScanSession.swift` |

### 3.5 Acción destructiva

| Mecanismo | Detalle |
|---|---|
| Papelera real | `trashItem`, que da el "Sacar del basurero" de Finder. Medido en APFS, FAT32 y los externos |
| Cuarentena como fallback | Probada en un montaje `smbfs` real; no rescata un volumen de solo lectura |
| Verificar antes de actuar | Exactos re-hashean, parecidos re-puntúan, carpetas exigen contención |
| Compuerta de simulación | Huella FNV-1a del plan; editar una decisión invalida la aprobación |
| Journal JSON Lines | Lotes de 32; un `undone_at` se agrega, nunca reescribe |
| Cancelar | Devuelve reporte y hace el flush; una cancelación nunca se reporta como archivo ilegible |

### 3.6 Formato en disco

| Mecanismo | Detalle |
|---|---|
| JSON escrito a mano | `\uXXXX`, `1.0` para doubles enteros, indent 2, orden de inserción: el formato de `json.dumps` de Python |
| Seis formatos | `scans`, `decisions`, `folder-scans`, `folder-decisions`, `similar-scans`, `similar-decisions` — tres formas distintas de documento de decisiones |
| Orden por bytes UTF-8 | `PathOrder`: NFC y NFD son rutas distintas |
| Escrituras atómicas | Temporal y rename: quien lee ve el documento viejo o el nuevo |

Detalle completo en [`FORMATO.md`](FORMATO.md).

---

## 4. Qué no hace

### 4.1 A propósito

Decisiones tomadas con evidencia. No son pendientes; están aquí porque cada una se volvió a discutir al menos
una vez.

| No hace | Por qué |
|---|---|
| Borrar definitivamente | Todo va a la Papelera y se journaliza, porque deshacer es la razón de la app |
| Mover sin decisiones | Aplicar actúa solo sobre lo decidido: un grupo sin decidir no se toca, nunca se completa con la sugerencia |
| Cruzar volúmenes por default | Escanear `~` no baja a los discos externos montados dentro |
| Escanear `~/Library` | Son cachés donde quitar un "duplicado" rompe una app. Excepción: la raíz elegida está dentro |
| Pedir Full Disk Access | No hay API para pedirlo, y una app que lo pide para ordenar Descargas parece malware |
| Sandbox | El estado vive en `~/.local/state/rav/duplicate/`, fuera del contenedor, para que otras herramientas lo lean |
| Bookmarks security-scoped | Sin sandbox, un permiso de TCC persiste por bundle id |
| Cortar la cancelación dentro de un chunk | El límite es una lectura de 1 MiB |
| `folder-decisions/` contra un archivo real | No existe uno escrito fuera de la app; el round-trip se prueba contra uno sintetizado |
| Usar `PerceptualHash(hex:)` en producción | Existe para que el diferencial contra Python sea depurable lado a lado |

### 4.2 Lo que no tiene

| Qué | En su lugar |
|---|---|
| Exportar un reporte (texto, CSV o JSON) | La biblioteca y los visores lo muestran en pantalla; los documentos JSON están en disco ([`FORMATO.md`](FORMATO.md)) |
| Preferencias | Las opciones se eligen en cada escaneo y no se recuerdan, salvo las carpetas recientes |
| Escaneos programados o en segundo plano | Cada escaneo lo empieza alguien, con la ventana abierta |

### 4.3 Pendiente

**Los pendientes viven en los issues**, no aquí; esta tabla es el índice que los ordena. Todo lo de abajo se
confirmó leyendo el código, y se volvió a confirmar contra `main` al abrir cada issue (2026-10-24). Un issue
cerrado sale de esta tabla en el mismo PR que lo arregla.

| Prioridad | Issue | Qué |
|---|---|---|
| — | — | Nada abierto al 2026-10-25 |

```bash
gh issue list --label priority:p1     # cerca de los datos del usuario
gh issue list --label bloqueado       # y por qué está bloqueado
```

Lo que ninguna herramienta verifica: los permisos de macOS, con el guion corto al final de
[`SELFTEST.md`](SELFTEST.md).

---

## 5. Qué sobra

Resultado de una auditoría del código completo, con cada hallazgo confirmado por grep. **Nada de esto se ha
quitado todavía**: es la lista para decidir, con una recomendación en cada caso.

### 5.0 Funciones que hacen lo mismo

Vistas desde quien usa la app, no desde el código: dos o más caminos para el mismo resultado.

| Función | Los caminos | Recomendación |
|---|---|---|
| Deshacer un apply | Sessions > Undo the Last Session · Session History > Undo This Session · botón Undo This Session en la hoja de aplicar | **Quitar "Undo the Last Session"**: el historial hace lo mismo con más contexto (desde #156 el del menú ya no elige una sesión devuelta, pero sigue sin decir cuál va a deshacer más allá de su id) |
| Limpiar sesiones devueltas | menú Sessions · botón Clean Up en el historial | conservar los dos: es la misma acción y el botón está junto a lo que limpia |
| Guardar decisiones | ⌘S y al cerrar en la exacta · automático en carpetas y parecidos | **elegir uno**: dos modelos para lo mismo, y cada uno ya falla distinto (sección 2) |
| Aceptar sugerencias en lote | menú sobre los grupos *seleccionados* en la exacta · botón sobre lo *visible* en parecidos · nada en carpetas | **elegir uno** y llevarlo a los tres; el de parecidos —lo visible, con el conteo dicho antes— es el que el diseño defiende |
| Ver si un archivo sigue ahí | botón Check the disk y filtro "Still on disk" en la exacta · aviso automático "no longer there" en parecidos · fecha ilegible en carpetas | un solo mecanismo para los tres |
| Vista previa de un archivo | un panel en la exacta · otro distinto, escrito aparte, en parecidos | un solo panel |
| Actualizar la biblioteca | botón Refresh · actualización automática por vigilancia de directorios | conservar Refresh solo mientras la vigilancia tenga huecos: el de reabrir la ventana se cerró con #149; queda el documento reescrito en su lugar, que un watcher de directorio no ve |
| Simular | botón y ⇧⌘D en la exacta · solo botón en las otras dos | igualar |
| Revelar en Finder | doble clic (un archivo) · ⌘R (los dos, en parecidos) | igualar: que el doble clic haga lo mismo que ⌘R |

### 5.1 La duplicación entre detectores, en una línea

Los tres detectores repiten la misma tubería —sesión de escaneo, estado de revisión, ventana, hoja de aplicar,
runner— y en cada capa la copia **ya divergió**: la tabla de la sección 2 son esas divergencias vistas desde
afuera. El costo no es el tamaño; es que un arreglo hecho en una copia no llega a las otras dos, como pasó con
#131. (La que parecía estar en el camino destructivo, ⌘Q, resultó no alcanzable: la hoja de aplicar ya impide
salir, #145.)

Lo que **sí** es una sola pieza y conviene que siga así: el deshacer (`UndoPlanner`, `UndoCoordinator`,
`MoveJournal`), las frases de falla y de progreso, Quick Look, los contadores y el heurístico de profundidad.

### 5.2 Implementaciones paralelas

| Familia | Dónde | Lo repetido | Lo que difiere y es forzado | Ahorro estimado |
|---|---|---|---|---|
| Runners de aplicar | `Action/ApplyRunner`, `FolderApplyRunner`, `SimilarApplyRunner` (719 líneas) | flush, lote de 32, corte a las 20 fallas, id de sesión, tres structs de reporte | la verificación: re-hash, contención, re-puntuación | 180–250 líneas |
| Hojas de aplicar | `ApplySheetController`, `FolderApplySheetController`, `SimilarApplySheetController` (1,237) | carpetas contra parecidos difieren en 78 líneas normalizadas | el titular y la lista | ~600 |
| Estados de revisión | `ExactReviewState`, `SimilarReviewState`, `FolderReviewState` | tri-estado, `tally` idéntico ×3, dos `ConfirmOutcome` homónimos, guardado y rehidratación | el tipo de la decisión, el cursor, las sugerencias | 80–100 |
| Ventanas de revisión | las tres | `mutate`, simular→hoja, la extensión de Quick Look **idéntica** ×3 | el contenido | 250–300 |
| Paneles de vista previa | `PreviewPane` contra `SimilarSidePane` | mismos campos, mismo formateador de fecha, dos chequeos de presencia distintos | — | ~120 |
| Sesiones de escaneo | `ScanSession`, `FolderScanSession`, `SimilarScanSession` | bucle de identificador ×3 (mientras `ScanIdentifier.nextAvailable` solo lo usan tests), cola de guardado ×3 | qué se hashea | ~60 |
| Despacho del panel de escaneo | `ScanPanelController` | tres `Task` y tres `finish*` | — | ~60 |
| Cachés | `HashCache` contra `PerceptualCache` | ~160 líneas: carga, reparación, poda, compactación, `flock` | el formato de fila en disco | 150–200 |
| `ScanStore` | seis pares save/load | idénticos salvo slot y codec | — | ~70 |
| Enums de detector | `ScanKind` (solo tests), `ScanPanelController.Detector`, `LibraryWindowController.LibraryKind` | tres nombres para lo mismo | — | ~30 |

**No es redundancia** y se queda: los seis codecs JSON. Las tres formas de documento de decisiones, y que un
umbral sea entero en un formato y float en otro, los dicta el formato en disco.

### 5.3 Código que producción no usa

**Muerto** — sin referencias fuera de su propia declaración o de los tests de sí mismo. Unas 100 líneas:
`ScanPhase.cancelled` (nunca se asigna), `ScanKind`, `QuickLookCoordinator.present(paths:)` y sus dos accesores,
`HashCacheKey.invalid`, `JSONWriter.line`, `StateDirectory.init(environment:home:)`,
`DirectoryTree.relativePath(ofFile:under:)`, `MediaAdvice.Side.other`, `FolderReviewState.currentPair`,
`Log.scan`, `Log.action`, `AccessProbe.unreadable(among:)`, los tres campos de `DescriptorLimit` que se escriben
y no se leen, y ~30 hooks de selftest que nadie llama.

**Inalcanzable desde la UI:**

| Pieza | Qué pasa |
|---|---|
| `clearDecision` de carpetas y de parecidos | En Core, ningún visor lo llama |
| `RecentRoots.forget`, `PresenceCache.forget` | No hay forma de quitar una carpeta reciente, y borrar un escaneo no borra su chequeo de disco |
| `previousGroup`, `retreat`, `actionableCount`, `confirmEffective` | Las ventanas navegan por su cuenta |
| `ReviewFlow` completo | Es una máquina de menú de cuatro pasos por ocho acciones, heredada de la herramienta de línea de comandos; producción usa cuatro métodos. El invariante real —"la simulación sigue vigente"— cabe en ~20 líneas |
| Protocolo `DirectoryEnumerating` | Un solo conforme y ningún fake: era la costura para `AttrListWalker`, que se rechazó con medición |

**Calculado y nunca mostrado** — la regla del proyecto dice que esto es peor que código muerto, porque tiene
test y parece una capacidad. Se cablea o se borra:

| Dato | Lo calcula | Recomendación |
|---|---|---|
| `hasDecisions` de carpetas y parecidos | la biblioteca | cablear: es el badge "Reviewed" que el exacto sí tiene |
| `HashingError.isSkippable` | el lector de chunks | borrar o aplicar: `DuplicateFinder` trata todo error como ilegible |
| Conteos de caché, clases, pares examinados, `scannedKinds`, `videoPairsCompared` | los escaneos | borrar, o mostrarlos en el resumen del escaneo |
| `CacheLiveness.measure` y `Report` | — | moverlo al selftest: es un diagnóstico, no producción |

**Solo para tests, y está bien**: `PerceptualHash(hex:)`, `CosineTransform.basis`, `Lanczos3.sum` (oráculos
contra Python), `SyntheticImage` y `SyntheticMovie` (fixtures), y una veintena de accesores de introspección.

### 5.4 Muy especializado

Funciones que atienden un caso medido como raro o inexistente. Ninguna está mal; la pregunta es si su superficie
vale lo que cuesta.

| Función | Tamaño | Uso medido | Recomendación |
|---|---|---|---|
| Aviso de claves `a\|\|b` ambiguas al cerrar | ~50 líneas + textos, y una segunda implementación en el codec | **0 rutas reales**; las dos que existen son el fixture del árbol de demo. Carpetas usa la misma clave y no se revisa | conservar una implementación, quitar la del codec, y aplicarla también a carpetas |
| "Discard both" (`keep_none`) | pequeño | 1 de 944 decisiones | conservar: el formato lo trae y el botón es barato |
| Discard the Whole Group (exacto) | ~40 | 0 de 12,842 entradas en 59 archivos | **candidato a quitar** del menú; el codec debe seguir leyéndolo |
| Cuarentena de respaldo | ~250 | 0 de 6 entradas reales; solo SMB | conservar: es seguridad, no uso |
| Poda de la caché perceptual | ~25 | 0% de desperdicio medido | conservar: comparte el mecanismo con la de digests |
| Historial de sesiones y limpieza | ~490 | 5 journals, 6 archivos movidos | conservar: el uso es bajo porque la app es nueva |
| Chequeo de disco con foto en Caches | ~380 | justificado: 0.67% de rutas vivas en escaneos viejos | conservar; llevarlo a los otros dos visores o no, decidir |
| `.mkv` y `.avi` en las extensiones de video | 1 línea | 0 en el corpus; AVFoundation no abre `.mkv` | **quitar `.mkv`**: solo infla el conteo de ilegibles |
| Mostrar u ocultar metadata (⌥⌘I) | ~80 | sin medir | conservar |
| Modos de diagnóstico del selftest (`phash-differential`, `video-timing`, `corpus`, `cache-liveness`, `volumes`, `realroot`) | ~630 | son benchmarks y oráculos, no regresiones | separarlos de los modos que CI corre |

### 5.5 El selftest

Tres problemas distintos:

- **Modos que ya cubren los tests unitarios**: `state-dir`, `gate`, `keeper`, `format`, `trash`, `review` y
  media `storage`. ~700 líneas.
- **Lógica de Core que solo probaba el selftest** —y por lo tanto quedaba fuera del piso de cobertura—: la
  exclusión de `~/Library`, la fase `.grouping`, `loadAndRepair`, las etapas del apply de carpetas, la cancelación
  a media corrida. Ya tiene tests en `Tests/` (#157).
- **Copia y pega**: seis round-trips con el mismo esqueleto (~357 líneas), la cadena Papelera→journal cinco veces,
  y el contrato de visor tres veces. Y ningún modo aplica ni deshace a través de las hojas de carpetas o de
  parecidos: sus hooks existen y nadie los llama.

### 5.6 Por dónde empezar

En orden, y con el riesgo dicho:

1. **Barrido de lo muerto (5.3).** ~500 líneas, riesgo nulo, y quita afirmaciones falsas sobre capacidades que
   no existen.
2. **Los pendientes de la sección 4.3, por separado**, antes de cualquier consolidación: son bugs con nombre, y
   arreglarlos dentro de un refactor los esconde.
3. **Selftest** (5.5): borrar lo cubierto, mover Core a `Tests/`, un round-trip genérico. ~1,700–2,200 líneas,
   riesgo bajo para producción, y la cobertura sube.
4. **Pipeline de escaneo y biblioteca**: una cola de sesión común, un despacho que muestre `inaccessible` en los
   tres, `ScanStore` genérico, `ScanKind` adoptado, biblioteca igual en las tres pestañas. ~250–300 líneas, riesgo
   bajo-medio, y cierra tres filas de la sección 2.
5. **Revisión**: estado y soporte de ventana compartidos, un solo panel de vista previa. ~450–500 líneas, riesgo
   medio: obliga a elegir **una** política de guardado, y esa decide qué queda escrito en el archivo de
   decisiones.
6. **Familia de aplicar**: un runner y una hoja con un adaptador por detector. ~850 líneas y el valor más alto,
   porque es donde la deriva ya tocó seguridad. Riesgo **alto**: es el camino destructivo. La red existe
   (~1,600 líneas de tests de apply), y el orden del journal, el flush al cancelar, el lote de 32 y el corte a
   las 20 fallas tienen que salir idénticos.
7. **Cachés**: un `AppendOnlyCache<Row>` genérico. ~150–200 líneas, riesgo bajo si el formato en disco sale
   byte-idéntico.

---

## Cómo mantener este mapa

- **Cada PR que agrega, quita o cambia algo visible edita la sección 1 o 2.** Si cambia cómo funciona por
  dentro, la 3.
- **Un pendiente nuevo es un issue**, y una línea en 4.3 en el mismo cambio.
- **Los números que cambian en cada PR se piden al código**, no se copian aquí:

```bash
make coverage                          # tests y cobertura sobre DuplicateCore
grep -rE '^\s*@Test' Tests | wc -l     # cuántos tests
make selftest-all                      # todos los modos, y que pasen
```
