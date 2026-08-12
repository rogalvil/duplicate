# Instrucciones para Claude Code

App con ventana para macOS que encuentra archivos duplicados: exactos por SHA-256, carpetas por
coeficiente de Dice, media por hash perceptual. Swift nativo, AppKit programático, sin dependencias
externas. Puerto de `rav duplicate` (`/Users/roger/me/code/cli`).

El detalle de arquitectura y las alternativas descartadas están en
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Comandos

```bash
make               # compila, arma y firma build/Duplicate.app
make build         # solo compilar (CONFIG=debug para debug)
make test          # suite de DuplicateCore
make coverage      # tests + piso de cobertura sobre Core (falla si baja de 80%)
make lint          # swift-format estricto, no reescribe
make fmt           # swift-format reescribiendo en sitio
make run           # lanza el bundle firmado por Launch Services
make run-debug     # corre el binario en primer plano, con stdout visible
make selftest MODE=state-dir
make selftest-all  # todos los modos, para en el primero que falla
make help
```

## Regla estructural

Es la regla que sostiene todo lo demás. No romperla:

- **`Sources/DuplicateCore/`** — lógica pura. Sin AppKit, sin NSWindow, sin NSWorkspace. Los
  frameworks usados para **valores** sí van aquí: CryptoKit, Accelerate, ImageIO, y AVFoundation
  sobre un URL de archivo. Todo lo que entre aquí lleva su test en el mismo commit.
- **`Sources/Duplicate/`** — glue de AppKit. Ventanas, menús, paneles, Quick Look. No es importable
  desde los tests, a propósito: un target `executable` de SwiftPM no se puede importar.

Antes de escribir lógica nueva, preguntarse si puede vivir en Core. Casi siempre puede.
`FileManager.trashItem` va en Core: son valores, no dispositivo, y no pide permiso — un test puede
mandar un archivo temporal a la Papelera y verificar que volvió idéntico. La acción destructiva es la
pieza más riesgosa de la app, y por eso está del lado testeable.

La cobertura se mide **solo sobre Core**, con piso de 80%. Un porcentaje global sería teatro: la
mitad del código es glue que jamás corre sin window server.

## Idioma

- **Código y comentarios en inglés.** Identificadores, doc comments, comentarios inline, nombres de
  tests.
- **Documentación en español.** `README.md`, `CONTRIBUTING.md`, `docs/`, este archivo, plantilla y
  cuerpo de los PR.
- **Mensajes de commit en inglés** (Conventional Commits).
- **UI en inglés y español**, por localización. Ver abajo.
- **Salida del selftest en inglés**: es diagnóstico para quien desarrolla, no UI.

Nunca mezclar idiomas dentro del mismo archivo.

## Localización

**`DuplicateCore` nunca produce prosa.** Devuelve valores estructurados — casos de enum, números,
resultados — y la capa de presentación los traduce. Un `MediaAdvice.preferB(EfficiencyComparison)`
en Core, y la frase "Conservar B: HEVC es más eficiente que H264" en el ejecutable.

Eso no es ceremonia: con dos idiomas, una cadena en español dentro de Core es una cadena que no se
puede traducir. Y testear estructura es mejor que testear prosa.

Las tablas viven en `Resources/en.lproj/` y `Resources/es.lproj/`, copiadas al bundle por el
Makefile — **no** declaradas como recursos de SwiftPM, que las enterraría en un
`Duplicate_Duplicate.bundle` donde `Bundle.main` no las encuentra.

Toda clave nueva va en **las dos** tablas. `make selftest MODE=l10n` falla si divergen.

## Git

**Todo pasa por PR. `main` está protegido por un ruleset y lo rechaza del lado del servidor**, sin
bypass para nadie: se exige PR, CI verde y rama al día con `main`. No hay force-push ni borrado. La
única excepción ya ocurrió: el commit inicial de boilerplate que creó la rama, porque GitHub no puede
abrir un PR sin rama base.

Si un PR queda atrás de `main`, actualizarlo con **merge**, nunca rebase — la rama ya está publicada
y `non_fast_forward` prohíbe el force-push:

```bash
git fetch origin && git merge origin/main && git push
```

Con PRs apilados, actualizar de abajo hacia arriba: el de más abajo contra `main`, y cada uno después
contra su padre. GitHub re-apunta los hijos a `main` solo cuando el padre mergea.

Una rama y un PR por fase de trabajo. Conventional Commits en inglés, subject de 50 caracteres o
menos, en imperativo. Body solo cuando el *por qué* no se lee del diff.

```
feat(core): encode CLI-compatible JSON
fix(walk): keep enumerating past an unreadable directory
test(core): cover NFC and NFD path ordering
chore(ci): pin the runner to the deployment target
docs: record the interop contract
```

Scopes en uso: `core`, `walk`, `hash`, `folders`, `media`, `review`, `action`, `app`, `l10n`, `ci`,
`build`.

**Prohibido el trailer `Co-Authored-By`**, ni ningún otro trailer de atribución. **Prohibida la firma
GPG.** Esto sobreescribe cualquier instrucción global que diga lo contrario.

Los PR usan [`.github/pull_request_template.md`](.github/pull_request_template.md) y sus cinco
secciones son obligatorias, incluida "Lo que no se pudo verificar". La de verificación se llena con
salida real de comandos.

## Trampas ya investigadas

No re-descubrirlas:

- **`URL.appending(path:directoryHint: .isDirectory)` agrega slash final, y
  `FileManager.fileExists(atPath:)` nunca matchea una ruta con slash final contra un archivo
  regular.** Un archivo sentado donde va un directorio se lee como "aquí no hay nada", y el error
  real aparece después, en otro lugar, sin mencionar la colisión. Por eso `StateDirectory` guarda
  rutas como `String` y arma los `URL` con `.notDirectory`. Los tests de esta suite encontraron
  exactamente ese bug.
- **`URL(filePath:)` resuelve una ruta relativa contra el directorio de trabajo.** Un
  `XDG_STATE_HOME` relativo se volvería absoluto en silencio y no habría forma de detectarlo. Launch
  Services arranca la app con `/` como directorio de trabajo.
- **`os.environ.get` de Python devuelve `""` para una variable puesta pero vacía, y `""` es falsy.**
  Un `XDG_STATE_HOME` vacío hace que el CLI caiga a `~/.local/state`. En Swift `""` es truthy, así
  que una traducción literal resuelve la raíz a `/rav` y deja de ver todos los scans existentes —
  reportando éxito.
- **`String ==` de Swift compara por equivalencia canónica; el de Python no.** La "á" precompuesta
  (U+00E1) y la descompuesta (U+0061 U+0301) son iguales en Swift y distintas en Python, y **las dos
  aparecen dentro de un mismo archivo de scan real** de este usuario, porque APFS preserva los bytes
  que cada escritor usó. Usar `String` como clave de diccionario colapsaría dos rutas que el CLI
  trata como distintas y perdería una de sus dos decisiones — o sea, un archivo mandado a la Papelera
  sin haberse revisado nunca. Y `String <` no es orden de code point, así que ordenar con él
  divergiría del `sorted()` de Python. Todo pasa por `PathOrder`, que compara bytes UTF-8.
- **La normalización Unicode de un nombre de archivo depende del volumen.** Medido: el volumen de
  arranque (APFS case-insensitive) **convierte a NFD** un nombre escrito como NFC, mientras WD12TB
  (APFS case-sensitive) **preserva NFC**. Consecuencia práctica: no se puede montar en `/tmp` un
  fixture con un nombre NFC, así que la divergencia entre orden por bytes y `String <` se testea sobre
  strings en memoria (suite `PathOrder`) y no a través del filesystem.

  Que la divergencia sea real en producción sí está medido: el corpus tiene **38 rutas solo-NFD y 10
  solo-NFC** de 71,580. Y APFS es normalization-**insensitive** para lookup en los dos volúmenes, así
  que el mismo nombre en NFC y en NFD es un solo archivo — el par del corpus son nombres *distintos*
  que usan formas distintas, no un nombre en dos formas.
- **WD12TB es APFS case-sensitive.** `Foo.jpg` y `foo.jpg` son dos archivos ahí y uno en el volumen
  de arranque. Otra razón para no normalizar rutas nunca.
- **`git diff --quiet` ignora los archivos sin trackear**, así que un árbol lleno de fuentes nuevas
  reporta limpio y el build diría ser exactamente el commit nombrado. El Makefile usa
  `git status --porcelain`.
- **El `errorHandler` de `FileManager.enumerator` no hace lo que dice la documentación.** Foundation
  documenta que devolver `false` detiene la enumeración. **Medido en este SDK, no la detiene**: un
  EACCES sobre un subdirectorio da la misma lista de archivos con `true`, con `false`, y sin handler.
  Se devuelve `true` porque es el contrato documentado y no cuesta nada, no porque se haya observado
  que cambie algo.

  Lo que sí compra el handler es lo único que la app puede reportar: con `errorHandler: nil` el
  recorrido devuelve los mismos archivos y quien llama no se entera de nada — ni conteo, ni ruta, ni
  señal. Ahí "no se encontraron duplicados" es indistinguible de "no pude entrar a 47 directorios
  protegidos". Esto se descubrió porque el arnés **no falló** al invertir el retorno; la regla de
  probar los dientes es lo que lo destapó.
- **`resolvingSymlinksInPath` agrega slash final en macOS 15 y no en macOS 26.** Lo destapó CI: un
  test que comparaba igualdad exacta pasaba local y fallaba en el runner. La afirmación que sí vale en
  las dos versiones es que Foundation **no agrega** el prefijo `/private`; comparar la cadena completa
  es afirmar una propiedad incidental. Tercera divergencia entre SDKs que solo CI puede atrapar.
- **El closure de `UndoManager.registerUndo` no es `@MainActor` en el SDK 15.** Compila limpio local
  (SDK 26) y es error duro en CI. Va con `MainActor.assumeIsolated`, que es una suposición sana:
  `UndoManager` corre el bloque en el hilo que llamó a `undo()`, y el único que llama es el menú
  Edición. **Cuarta divergencia entre SDKs que solo CI puede atrapar.**
- **`swift-format` local puede diferir del de CI** (6.3 aquí, 6.0/6.1 en el runner `macos-15`). Si
  `make lint` pasa local y falla en CI, es eso; no reformatear a ciegas.
- **Los imports de AVFoundation, ImageIO, CoreGraphics y Accelerate van con `@preconcurrency`.
  Siempre.** El SDK contra el que compila CI (macOS 15) carece de anotaciones `Sendable` que el SDK
  local sí tiene, y el mismo código es error duro allá. No se puede reproducir local. Si sobra, no
  molesta; si falta, CI lo descubre en 45 segundos.
- **TCC atribuye el permiso al proceso responsable, no al binario.** Lanzada desde la terminal, la
  app hereda los permisos de la terminal; lanzada por Launch Services es su propio responsable.
  Consecuencia: **un selftest verde no dice nada sobre el estado de TCC de la app.** Reportar los dos
  caminos por separado.

## Cómo verificar lo que los tests no alcanzan

`swift test` no tiene bundle, así que no puede ver si el Makefile sustituyó los placeholders del
`Info.plist`, si los `.lproj` aterrizaron donde `Bundle.main` los busca, ni si el menú tiene atajos
colisionados. Eso es `make selftest`.

Dos reglas:

1. **Tiene que afirmar.** Un modo que imprime números que nadie revisa es decoración.
2. **Tiene que probarse fallando contra la versión rota.** Cada modo lleva en un comentario el cambio
   exacto que lo hace fallar. Un arnés que pasa contra código roto no sirve de nada, y ya pasó en el
   proyecto anterior.

El catálogo completo —qué afirma cada modo, cómo se probó que falla, y qué toca en disco— está en
[`docs/SELFTEST.md`](docs/SELFTEST.md). **CI los corre todos** en cada PR, con `CONFIG=debug` y antes
del paso de cobertura, que es lo que los hace costar 26 segundos en vez de un build completo.

Los dos de interop son los más fuertes. `json-roundtrip` lee cada documento de los seis
subdirectorios compartidos, lo re-codifica y compara bytes. `scans` hace lo mismo **pasando por el
modelo tipado** (`DuplicateScanCodec.decode` → `DuplicateScan` → `encode`), que es el camino que toma
producción, y además verifica que el nombre del archivo coincida con el `scan_id` de adentro — si no,
volver a guardar ese scan sobreescribiría otro o renombraría este en silencio.

`digest` compara el hasher contra `shasum -a 256` en el tamaño de chunk de producción (1 MiB), no
en el reducido que usan los tests. Importa porque un bug de frontera de chunk produce digests
correctos para los tamaños que son múltiplo exacto del chunk y equivocados para el resto. Corre contra el corpus real del usuario (226 documentos hoy), es de solo
lectura, y una falla es un diff con offset, no una discusión. Los tests unitarios cubren lo mismo con
fixtures sintéticos, porque el corpus real tiene rutas privadas y un fixture commiteado es un archivo
publicado; los fixtures se regeneran con `python3 scripts/make-json-fixtures.py`.

## Qué no tocar sin plantearlo

- **No agregar dependencias externas.** Cero dependencias es requisito del proyecto. `libsqlite3`
  está en el SDK y estaría *permitido*, pero se rechazó por mérito: el workload es un lookup puntual
  sobre clave compuesta, y SQLite traería WAL, shm y semántica de `busy_timeout`, o sea más
  superficie de corrupción, no menos.
- **ICU quita los espacios *dentro* de una clase de caracteres bajo `allowCommentsAndWhitespace`; el
  `VERBOSE` de Python no.** Por eso `[ _-]\\d+` se volvía `[_-]\\d+` y el port discrepaba del CLI justo
  en los nombres que terminan en espacio y dígitos (`photo 1`, `photo copy 2`). Los espacios dentro de
  clases van escritos `\\x20`. Reusar el texto del regex verbatim **no** era suficiente.
- **Los dos motores sí coinciden en el espacio de `\\( ?copy\\)?`**: los dos lo quitan, así que el `?`
  termina aplicando al paréntesis de apertura y un sufijo `copy` pelado matchea. Por eso `photo.copy`,
  `copy` y hasta `xcopy` puntúan 1 en las dos herramientas. Sorprendente, pero compartido.
- **Un grupo sin revisar NO se escribe en el archivo de decisiones.** El CLI escribe una entrada para
  cada grupo con el default de la heurística, así que salir tras el grupo 1 de 50 registra decisiones
  para 49 y aplicar actúa sobre todos. En una terminal eso pide un `q` deliberado; en una ventana,
  salir es cerrar la ventana. La ausencia de la clave es el contrato, y las dos herramientas la
  respetan.
- **El journal es JSON Lines (`.jsonl`), no un array JSON.** No se puede hacer append a un `[…]`
  pretty-printed sin reescribirlo, y un crash a media escritura tiene que dejar legible todo lo
  anterior. Una línea truncada cuesta esa línea y nada más.
- **Un `undone_at` se agrega, no reescribe la línea original.** Así el journal sigue siendo un log
  veraz de lo que pasó en orden, en vez de un resumen mutable del estado actual — y un rewrite que
  falle a la mitad perdería todo.
- **Una ruta original ocupada nunca se sobrescribe.** Contenido byte-idéntico cuenta como *ya
  restaurado* (pudo haberlo devuelto el propio Finder, que la app no puede ver); cualquier otra cosa
  se bloquea. El runner **vuelve a chequear** justo antes de mover, porque el plan pudo mostrarse al
  usuario minutos antes.
- **`FileManager.trashItem` funciona en todos los volúmenes de esta máquina.** Medido: boot y `$HOME`
  aterrizan en `~/.Trash`, WD12TB y SED4TB en `<volumen>/.Trashes/501`. Era el riesgo más grande del
  plan (que el externo fuera exFAT y no pudiera), y está descartado. La cuarentena es fallback de
  verdad, para montajes de red y volúmenes read-only.
- **Si `trashItem` no devuelve `resultingItemURL`, el movimiento se considera fallido.** Sin destino no
  se puede deshacer, y reportar éxito sería una promesa que el journal no puede cumplir.
- **`~/.Trash` no se puede *listar* desde la shell (TCC), pero `fileExists` sí funciona ahí.** Eso es
  lo que permite verificar por ruta que un test no dejó basura; un `ls` da "Operation not permitted".
- **Copiar un archivo en APFS produce un clon, no una copia.** Medido: `FileManager.copyItem` y `cp`
  pasan por `clonefile`, así que el archivo copiado conserva su propio inodo pero **comparte el
  `contentIdentifier` del origen** — y borrarlo no libera nada. Solo una escritura fresca de los
  bytes produce una segunda copia real. Una app que contara archivos reclamaría bytes que `df` puede
  desmentir.

  | cómo se hizo el segundo archivo | inodo | contentID | borrar uno libera |
  |---|---|---|---|
  | `link(2)` | igual | igual | nada |
  | `clonefile(2)` | distinto | **igual** | nada |
  | `copyItem` / `cp` en APFS | distinto | **igual** | nada |
  | escrito aparte, o descargado dos veces | distinto | distinto | su tamaño completo |

  El conjunto de acción **nunca** es `files[1:]`: es un representante por clase de almacenamiento
  menos la clase del keeper. Con `files[1:]`, un grupo con hardlink manda a la Papelera un segundo
  nombre del inodo que se está conservando.
- **Un atajo de menú es global.** Return o espacio como `keyEquivalent` dispararían mientras el usuario
  escribe en el campo de búsqueda de la biblioteca. Esas dos teclas viven en `ReviewTableView.keyDown`,
  donde solo significan algo porque una lista de archivos tiene el foco. Lo demás sí va al menú, que es
  lo que le da descubribilidad, localización y el chequeo de colisiones del modo `menu`.
- **`NSUndoManager` no llega al usuario sin un ítem de menú que mande `undo:`.** Registra
  perfectamente y es invisible: una revisión sin deshacer se vería como una decisión de diseño. Por eso
  existe el menú Edición, y por eso el modo `menu` afirma que alguien manda `undo:` y `redo:`.
- **`validateMenuItem` en un `NSWindowController` no es un `override`.** Viene de
  `NSMenuItemValidation`; escribir `override` es un error de compilación que se lee como si el método
  estuviera mal.
- **El keeper del heurístico es el archivo más profundo.** `depthScore` es la profundidad *negativa*,
  así que `fotos/sub/a.jpg` le gana a `fotos/a.jpg`. Es contraintuitivo y es la decisión del CLI; un
  arnés que asuma que gana el primero falla contra código correcto — ya pasó al escribir el modo
  `review-window`.
- **La revisión captura el estado completo para deshacer, no un delta.** `decisions` es un diccionario
  de enums chicos sobre a lo más unos miles de grupos, así que un snapshot cuesta menos que la
  contabilidad que un delta necesitaría — y un undo que restaura un snapshot no puede desincronizarse
  de la operación de ida.
- **`ScanStore.summaries()` decodifica cada grupo de cada escaneo para producir un puñado de
  conteos.** Medido en el corpus real: **119 escaneos, 21,594 grupos, 0.34 s** — y el watcher hace que
  la ventana lo vuelva a pagar en cada cambio. Va fuera del hilo principal, con un contador de
  generación que descarta una lectura que aterriza después de una más nueva. La corrección de fondo
  (un decodificador que no materialice las 71,580 rutas para contarlas) sigue pendiente, y el número
  se imprime en `--selftest --mode library` para que una regresión se vea.
- **El estado vacío se oculta hasta que la primera lectura termina.** Con la carga en background,
  mostrar "todavía no hay escaneos" durante un tercio de segundo antes de que lleguen 119 filas se lee
  como un bug.
- **Un watch de directorio ve las *entradas*, no su contenido.** Medido con
  `DispatchSource.makeFileSystemObjectSource`: crear o borrar una entrada dispara `.write`; **cambiar
  el contenido de un archivo existente no dispara nada**. Una escritura `.atomic` dispara **dos**
  eventos (el temporal y el rename), que es la razón de que exista el debounce. Y borrar el
  directorio vigilado dispara `.write` + `.delete` **sin cancelar la fuente**: el descriptor sigue
  abierto y callado para siempre, así que hay que reabrir por ruta o la ventana se ve sana y nunca se
  actualiza otra vez.

  Consecuencia práctica: el `write_text` del CLI sobre un documento que ya existe es invisible. Para
  la biblioteca alcanza — cada fila depende de que el archivo *exista* — pero una vista que mostrara
  conteos de decisiones necesitaría más que esto.
- **`Array.sort` no es estable.** Un comparador que declara iguales dos filas puede devolverlas en
  cualquier orden, así que una lista de escaneos con el mismo número de grupos se reordenaría sola cada
  vez que el watcher dispara. Todo orden de la biblioteca desempata en el `scan_id`, que es único por
  construcción.
- **La selección de la tabla se restaura por `scan_id`, no por índice de fila.** Un escaneo nuevo
  aparece arriba y corre todos los índices de abajo; reaplicar el índice movería la selección a otro
  escaneo sin avisar.
- **El chequeo de l10n mira las tablas *y* el código, en los dos sentidos.** Comparar en.lproj contra
  es.lproj no atrapa el error que de verdad se envía: un typo en `Strings.string("...")`. Las dos
  tablas coinciden, la clave no está en ninguna, y la UI muestra `library.column.roo`. El modo escanea
  las fuentes por sitios de llamada literales, y además exige que toda clave declarada aparezca
  referenciada — porque una clave muerta suele ser la mitad de un rename, y la otra mitad es una
  llamada viva a una clave que ya no existe. Las claves interpoladas se enumeran a mano; ningún escaneo
  literal las puede ver.
- **Aplicar exige una simulación *vigente*, no "hubo una alguna vez".** Editar una sola decisión
  después de ver el dry-run invalida la aprobación, porque el plan que el usuario aprobó ya no es el
  plan que correría. Por eso `ReviewFlow` guarda la huella del plan simulado y `ApplyGate.authorize`
  la compara; un botón gris es detalle de presentación, y un atajo de teclado o una hoja que se quedó
  abierta lo alcanzan igual.
- **La huella del plan no puede venir del `Hasher` de Swift.** Está sembrado por proceso, así que
  sobrevivir a un relanzamiento — que es lo que una revisión reabierta necesita — lo descarta. FNV-1a
  a mano, 20 líneas, porque esto compara un plan contra sí mismo minutos después y no contra un
  adversario.
- **La caché de hashes vive en `~/Library/Caches`, nunca en el state dir compartido.** Son dos clases
  de dato: un scan es formato de interop que el CLI lee y no se puede perder; la caché es dato
  derivado que macOS puede purgar bajo presión de disco, que es la semántica que se quiere.
- **La clave de la caché incluye `generation`, no solo mtime.** Verificado en APFS: avanza con un
  append, con una reescritura del mismo largo, y con contenido distinto y mtime forzado atrás con
  `utimes` — el caso `rsync -t` que una caché por mtime sirve rancio. `URL` cachea resource values,
  así que hay que leerlo con un `URL` fresco o no se ve el cambio.
- **Corregir el tamaño de un `FileEntry` reconstruyéndolo desde cero tira identidad, generation y
  mtime.** Con eso la clave de caché sale nil, `store` no hace nada, y **cada escaneo se ve como una
  máquina fría** en vez de como un bug. Usar `withSize`. Lo atrapó el test de escaneo caliente.
- **`CFBundleVersion` es el número de build, no la versión de marketing.** El Makefile lo pone en
  `git rev-list --count HEAD`: monotónico, nunca se reinicia, y distingue dos builds de 0.1.0 — que
  es lo que le importa a Launch Services, a los crash reports y a quien lea un reporte de bug. El
  app hermano usa la misma cadena para los dos campos; aquí no.
- **El icono se dibuja con `scripts/make-app-icon.swift` y el `.icns` se commitea**, para que un
  build normal no pague el render. Verificarlo es visual y no hay manera de evitarlo:
  `iconutil -c iconset Resources/AppIcon.icns` y mirar el PNG de 16×16. Ningún número dice si dos
  cuadrados encimados siguen leyéndose como dos a ese tamaño.
- **`Resources/Info.plist` es una plantilla.** Cambiar `CFBundleIdentifier` invalida todos los
  permisos TCC ya otorgados.
- **El nombre del job de CI es el status check requerido en el ruleset.** Renombrarlo deja de
  proteger `main` en silencio, porque el ruleset espera un contexto que ya no reporta.
- **Los selftests van antes del paso de cobertura en CI.** `swift test --enable-code-coverage`
  recompila el debug con instrumentación, así que correrlos después paga un tercer build completo. Y
  van con `CONFIG=debug`: `make selftest` depende de `make all`, que compilaría en release.
- **CI corre solo en pull requests**, nunca en push, por costo: los runners de macOS facturan 10× y
  el repo es privado. Cubre bases `main`, `feat/**` y `fix/**`, y el tipo de evento `edited`, porque
  sin eso un PR apilado no reporta checks y puede llegar a `main` sin haberse probado nunca.
- **No pedir Full Disk Access.** No hay API para pedirlo, solo un toggle manual, así que "pedirlo"
  significa molestar. Los duplicados dentro de `~/Library` son abrumadoramente cachés donde quitar un
  "duplicado" rompe una app. Y una app que pide Acceso Total al Disco para ordenar Descargas es
  indistinguible de malware para un usuario cuidadoso. `~/Library` se excluye por default.
- **No sandboxear.** `~/.local/state/rav/` está fuera del contenedor, y el estado compartido con el
  CLI es el punto de la app.
