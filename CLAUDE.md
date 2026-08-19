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
- **`#available` no protege la *existencia* de un símbolo en el SDK, solo su disponibilidad en runtime.**
  Poner `NSButton.BezelStyle.glass` detrás de `if #available(macOS 26.0, *)` compila local (SDK 26) y es
  error duro en CI (SDK 15), porque el símbolo no está ahí para compilar. Un símbolo de un SDK más nuevo no
  se alcanza así. **Quinta divergencia entre SDKs que solo CI atrapa.**
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
- **Rehidratar un archivo de decisiones del CLI hace que *todos* los grupos salgan decididos**, porque el
  CLI escribe una entrada por grupo incluidos los que nadie abrió. Medido en este corpus: **55 de 56
  archivos tienen exactamente una decisión por grupo**, y el único parcial es el que escribió esta app. La
  app los carga —son el formato compartido— y avisa: ni rehusarlos ni tirarlos en silencio serían mejores,
  los dos son la app decidiendo por el usuario.
- **`NSString.deletingLastPathComponent` colapsa un doble slash y una cadena de root no.** Un root de
  `…/T//tree` con archivos de `…/T//tree/a/x.bin` daba un padre de `…/T/tree/a` —un solo slash— y el test
  de prefijo tiraba **todos** los archivos: árbol vacío, escaneo que no encuentra nada, en silencio. Y
  `NSTemporaryDirectory()` termina en slash, así que no es un caso raro. `DirectoryTree` canonicaliza
  partiendo por `/` los dos lados, y solo los slashes: nada de case folding, normalización Unicode ni
  symlinks.
- **El detector de carpetas hashea *todos* los archivos**, no solo los que colisionan por tamaño — 244 de
  10,506 en un árbol medido, 986 de 15,242 en otro. Ahí la caché de hashes deja de ser optimización y es
  la diferencia entre minutos y segundos en la segunda corrida.
- **`threshold` es float y los conteos son enteros, en el mismo documento.** Escribir `5.0` donde el CLI
  pone `5` rompe la comparación byte a byte igual que escribir `1` donde pone `1.0`. Los dos errores
  existen y son opuestos; hay un test para cada uno.
- **En un par de carpetas, `folder_b` es la que se borra: `rav duplicate folders-move` conserva `folder_a`
  y manda la otra a cuarentena.** El documento es formato compartido, así que la orientación no es
  cosmética — un escaneo que escriba la app se puede aplicar con el CLI. Se normaliza por bytes:
  `folder_a` es la ruta menor. Tomarla del orden de índices del árbol la tomaba del orden de enumeración,
  que nada promete reproducir. Medido: mismo conjunto de 42 pares que el CLI sobre un árbol real, y **los
  42 al revés**. El caso que lo destapa es una carpeta cuyo nombre es **prefijo del de su hermana** (`wen`
  y `wen 2`): el recorrido visita `wen` primero porque el nombre corto ordena antes, y el orden de bytes
  pone `wen 2/s` primero porque el espacio (0x20) le gana al slash (0x2F). **Sesenta árboles aleatorios
  nunca produjeron un hermano-prefijo** — el corpus real lo produjo en el primer intento, y es el
  recordatorio de que un fixture generado cubre lo que se le ocurrió al generador.
- **Pillow redondea al convertir a grises, no trunca.** Medido sobre diez triples:
  `(19595·R + 38470·G + 7471·B + 0x8000) >> 16` acierta los diez y la forma truncada falla tres — `(0,255,0)`
  da 149 contra 150. El plan decía lo contrario.
- **El DCT del hash perceptual tiene que cancelar exacto, y solo el de Accelerate lo hace.** Una imagen plana
  debe dar un coeficiente y 63 ceros; con la matriz de la base quedan ~1e-3 de signo mezclado, la mediana cae
  entre ellos y prenden **32 bits en vez de 1**. No es precisión: una FFT resta valores iguales y da cero
  exacto, una suma de 32 cosenos que cancela matemáticamente no lo hace a ninguna precisión. Por eso también se
  **cuantiza a `UInt8` después del resample**, o el ringing de Lanczos deja la región plana en `255 ± 1e-3` y
  vuelve el volado. Y por eso los frames negros de dos videos distintos dan el mismo hash, que es de lo que
  depende el agrupamiento del camino de video. Cuantizar además *entre* las dos pasadas de Lanczos, como hace
  Pillow, **se midió y empeora** (89.97% contra 90.88%).
- **El setup de `vDSP.DCT` cuesta 1 µs**, no lo que el plan supuso: 1,000 setups de tamaño 32 en 1.0 ms. No hay
  que reusarlo por worker, y así el tipo se queda siendo un valor sin discusión de `Sendable`. Su método es
  `transform(_:result:)`, no `output:`.
- **Agregar un tipo de escaneo a la biblioteca son cuatro lugares, no dos.** Columnas, celdas, pie y estado
  vacío — y **el watcher de su directorio**. `folder-scans/` y `similar-scans/` se quedaron sin vigilar cuando
  llegaron sus segmentos, así que un escaneo terminaba, su documento aterrizaba, y la lista seguía igual: se
  lee como "no encontró nada", no como "esta ventana no está mirando". El modo `library` fija el número de
  watchers justamente para que agregar un quinto tipo y olvidarlo falle ahí.
- **Un estado vacío y un pie que leen otra lista se dibujan encima de la lista que sí hay.** Lo destapó una
  captura: 31 escaneos perceptuales en pantalla, el pie diciendo "0 escaneos - 0 mostrados" y el placeholder de
  "todavía no hay escaneos" **encima de las filas**, porque los dos seguían leyendo el arreglo del detector
  exacto. Un arnés que cuenta filas no ve ninguna de las dos cosas; hay que afirmar sobre el pie y sobre el
  estado vacío también.
- **La similitud de un video no es una distancia de bits.** Es la fracción de cuadros muestreados que
  coinciden, así que imprimir "difieren 0 de 64 bits" bajo un par de video —lo que salió— afirma una medición
  que nunca se hizo. El encabezado cambia de texto según `media_type`.
- **Un panel vacío no distingue "el archivo ya no está" de "la miniatura todavía no llega".** Y en el corpus
  real pasa seguido: de los pares perceptuales, un lado del primero ya no existe. El panel lo dice.
- **La detección de tráiler va antes que la calidad, y el orden es lo que la hace correcta.** Un tráiler de 30 s
  en HEVC a alto bitrate **le gana en puntuación** a la película de dos horas en H.264 que anuncia, así que una
  cadena que preguntara calidad primero conservaría el tráiler y borraría la película. Hay test con esa inversión
  medida en el fixture.
- **Un codec desconocido vale 1.0 *y se marca*.** El `.get(codec, 1.0)` del CLI lo trata como H.264 en silencio,
  que es una adivinanza capaz de entregarle la decisión al archivo equivocado. Se conserva el número por paridad
  y se agrega la bandera.
- **La clave de una decisión de parecidos es `a||b` sin escapes**, formato del CLI, con el hueco que implica: una
  ruta que contenga `||` da una clave que no se puede volver a partir. Medido: **ninguna ruta del corpus lo
  contiene**, y `SimilarPairKey.isAmbiguous` lo reporta en vez de esconderlo.
- **Una rehúsa no es una falla, y mezclarlas entrena a ignorar las fallas.** El aplicar exacto mueve o falla; el
  perceptual además puede declinar porque el par ya no se parece — eso es el chequeo funcionando, y va primero en
  el reporte porque es lo que el lector tiene que atender: esos archivos siguen ahí.
- **En un par parecido no hay nada que prometer sobre espacio recuperado.** El exacto sabe que los archivos de un
  grupo son byte-idénticos; dos parecidos tienen tamaños distintos, y el único número honesto es el de los
  archivos que de verdad se movieron.
- **Afirmar sobre el texto de una hoja no prueba la compuerta.** La primera versión del arnés revisaba el titular
  y la lista, y **pasaba con `flow.advance(.dryRun,…)` quitado**: la negativa solo ocurre al presionar el botón, y
  el arnés no lo presionaba. Presionarlo ahí movería archivos de verdad, que es lo que el modo `similar-apply` ya
  hace con limpieza, así que la hoja expone si la compuerta la autorizaría **sin aplicar**.
- **Lo que el escaneo ya sabe se dice al decidir, no al aplicar.** Un par de carpetas carga `only_in_a` y
  `only_in_b`, así que la ventana puede avisar "mover la segunda perdería 5 archivos que tiene y la primera no"
  *mientras eliges* — en vez de dejarte elegir, presionar aplicar, y leerlo en una lista de rehúsas. El aplicar
  igual verifica: el escaneo puede estar viejo y sus conteos son lo que era cierto entonces.
- **Las carpetas colapsadas se nombran en la hoja.** Una que falta de la lista porque un ancestro ya está en ella
  no es una omisión, y quien cuente filas pensaría que se perdió una.
- **Para una carpeta, la verificación no es la similitud: es la contención.** "Estas dos son 95% iguales" es
  buena razón para *mirar* y pésima para borrar — el otro 5% es exactamente lo que se perdería. Antes de mover una
  carpeta, cada archivo suyo tiene que tener un gemelo byte-idéntico **en la misma ruta relativa** dentro de la que
  se conserva; si falta uno, se nombra y no se mueve nada. La caché de digests lo vuelve barato.
- **El journal guarda el digest del *manifiesto*** —el SHA-256 de las líneas `relpath\0hex` ordenadas— porque un
  directorio no tiene digest propio y el undo necesita uno para probar que lo que está en la Papelera sigue siendo
  lo que se puso ahí. Editar cualquier archivo adentro, o agregar o quitar uno, lo cambia. Y por eso el
  `Environment` del undo sabe digerir directorios: sin eso, restaurar una carpeta se bloquea como
  `contentChanged`.
- **Los pares anidados se colapsan.** Un escaneo de carpetas encuentra `Pole ↔ Pole` y `Pole/videos ↔
  Pole/videos` como pares separados —medido en el corpus real— y mover el padre se lleva al hijo. Un plan con los
  dos movería el padre y luego fallaría sobre una ruta que ya no existe, reportando un error por algo que
  funcionó.
- **Y una carpeta que contiene algo que otra decisión conserva se excluye.** Si el plan mueve `X` y otro par
  conserva `X/sub`, mover `X` borra `X/sub`; no hay orden que lo arregle.
- **`_folders_to_move` del CLI usa `decisions.get(key, [folder_a])`**, así que `folders-move` sobre un escaneo sin
  revisar **mueve el `folder_b` de todos los pares**. Para archivos eso borraba copias; para carpetas borra
  árboles. Aquí un par sin decidir no se toca.
- **`folder-decisions/` es la forma envuelta con listas** (`{scan_id, created_at, decisions:{"a||b":[conservadas]}}`)
  — tercera forma distinta de las tres. Y es **la única sin archivo real contra el cual verificar**: el CLI tiene el
  slot y nunca escribió uno, así que su round-trip se prueba contra un documento sintetizado y contra el código del
  CLI, no contra algo que el CLI haya escrito.
- **Un escaneo perceptual NO guarda ningún digest**, así que "verificar antes de actuar" no puede ser "¿son los
  bytes que vio el escaneo?". Lo que sí se puede re-chequear es la afirmación sobre la que se decidió: **estos dos
  se parecen**. Se re-hashean los dos archivos y se vuelve a puntuar el par contra el umbral del escaneo; una foto
  editada desde entonces, o un archivo reemplazado en la misma ruta, se rehúsa. Cuesta un decode de dos archivos
  (~7 ms imagen, ~300 ms video) y solo se paga por los que se van a borrar.
- **Si el contraparte no está, no se mueve nada.** Sin el otro lado no se puede re-chequear la afirmación, y mover
  sobre una afirmación no verificable es justo lo que esa verificación existe para evitar.
- **El digest del journal se calcula al mover, no se recuerda del escaneo** — es el único que hay. Y si no se puede
  calcular, **el archivo no se mueve**: una entrada con un digest inventado dejaría que un undo "verifique" un
  archivo restaurado contra nada, que es peor que negarse a borrar.
- **Una ruta que una decisión borra y otra conserva se excluye del plan, no se avisa.** Las dos decisiones son del
  usuario, y la única lectura que respeta las dos es no actuar sobre ninguna.
- **Narrowing no decide nada, y ese es todo el diseño.** 4,771 pares no se revisan de a uno, y la respuesta no es
  un botón que decida todos —ese botón es el defecto del CLI—. Se filtra, y después se acepta **exactamente lo que
  está en pantalla**, con el conteo de archivos y bytes dicho antes. Cada índice que llega a `confirmAll` es uno
  que la ventana mostró.
- **Con un filtro activo, la fila y el índice del par son números distintos.** Todo lo que decide, dibuja el
  consejo o pide facts va por el índice del escaneo; usar la fila decidiría el par equivocado. Y tras mutar hay que
  **reconstruir** la lista visible si el filtro es "sin decidir", o la fila se queda mostrando un par que el estado
  ya dejó atrás — exactamente lo que una captura real del detector exacto destapó.
- **La selección se restaura por par, no por fila.** Un filtro que quita filas de arriba movería la selección a
  otro par sin avisar.
- **Una sugerencia se dibuja como el *default*, no como algo ya elegido.** Si el botón de la sugerencia sale
  presionado igual que una decisión real, las dos se ven idénticas y el único que sabe la diferencia es el
  archivo. Aquí la sugerencia toma el `keyEquivalent` de Return y ninguna se ve pulsada hasta que alguien
  decide.
- **Las facts de media se piden por par, no por escaneo.** Probar los 2,460 archivos de un escaneo real antes de
  dibujar la ventana repetiría buena parte del escaneo; se piden para el par que se está viendo, con un contador
  de generación que tira la respuesta que llega después de que la selección se movió.
- **Las contradicciones se avisan al cerrar, no en cada clic.** El conflicto solo importa cuando el conjunto de
  decisiones está terminado, y una hoja tras cada elección haría imposible decidir 4,771 pares.
- **"Descartar los dos" va en rojo.** Es la única opción del visor que puede quitar dos archivos de una, y en el
  corpus real se usó **una vez en 943 decisiones**.
- **Un archivo puede estar en varios pares, y eso es lo normal, no un borde**: 4,771 pares sobre 2,460 archivos
  en el corpus real. Un plan que listara la misma ruta dos veces intentaría moverla dos veces, y el segundo
  intento fallaría sobre un archivo que ya está en la Papelera — un error reportado por algo que funcionó.
- **Y los pares que se traslapan pueden contradecirse, incluso con la *misma* decisión en los dos.** Con (a,b)
  keep_a y (b,c) keep_a: el primero borra `b` y el segundo **conserva** `b`. Actuar sobre los dos borra un archivo
  que el usuario eligió conservar un par después. Transitivamente puede ser lo que quiso —a ≈ b ≈ c, conservar a—
  pero nadie dijo "borra b" en el segundo par, e inferirlo es justo la clase de amabilidad que una acción
  destructiva no puede tener. Se reporta con `contradictions`, no se resuelve. Un test mío afirmaba lo contrario y
  estaba equivocado.
- **El orden de claves de `similar-decisions` es parte del formato.** Guardarlo en un `Dictionary` mezclaría las
  943 líneas reales y la comparación byte a byte fallaría sobre un archivo cuyo contenido es idéntico. Medido: los
  cuatro valores aparecen de verdad —`keep_a` 597, `keep_b` 337, `keep_both` 8, `keep_none` **1**— así que ninguno
  es teórico, y ordenar los miembros antes de escribir rompe **16 de 17** documentos.
- **Una decisión desconocida se rechaza, no se salta.** Saltarla convertiría en silencio un par revisado en uno
  sin revisar, y el siguiente aplicar dejaría los dos archivos donde están mientras la ventana dice que está
  decidido. El corpus real no tiene valores raros, así que eso lo prueba un test unitario y no el modo `decisions`.
- **`similar-decisions` es un mapa pelado**, sin el envoltorio `{scan_id, created_at, decisions}` que sí llevan
  `decisions/`. Un solo tipo no puede representar los dos honestamente.
- **El desempate final de un par parecido es la profundidad, y gana el más profundo** — contraintuitivo y a
  propósito: es la regla del detector exacto, y que los dos detectores propusieran sobrevivientes distintos para
  los mismos dos archivos sería peor que una regla rara.
- **`AttrListWalker` está rechazado con número, no por pereza.** `fs_usage` sobre 3,421 archivos: **0.12 syscalls
  de la familia stat por archivo** y 292 `getattrlistbulk` (~11.7 entradas por llamada), contra los **3-4 stats por
  archivo** que hace el CLI en Python. La regla del plan era "si la razón es < 1.2, `FoundationWalker` se queda";
  sale 0.12. Esas ~400 líneas de aritmética de punteros no se escriben. Necesita `sudo`, así que la corrió el
  usuario.
- **Y el mismo trazo mostró que el 61% de los `pread` de un escaneo eran la sonda de prefijo** (3,824 de 6,241),
  medido con el umbral viejo de 256 KiB. Dos instrumentos distintos —tiempos y syscalls— dijeron lo mismo.
- **La etapa de prefijo estaba mal calibrada y ahora el umbral es 8 MiB.** A los 256 KiB que se enviaron sondeaba
  **1,912 de 3,421 archivos, cobraba 54% del tiempo y ahorraba 1 MB de 1.5 GB**. El argumento del plan (dos
  imágenes de 4 GB del mismo tamaño) sigue en pie; el umbral no. A 8 MiB es indistinguible de apagarla sobre fotos.
- **`F_NOCACHE` da 4× menos page cache, no cero**: +0.10 GB contra +0.40 GB para las mismas 1.52 GB leídas, al
  mismo tiempo de reloj. La mayoría de los archivos están debajo del umbral y se cachean igual. Sale gratis, se
  queda.
- **En el corpus externo real no hay E/S que paralelizar**: 1,137 archivos, **29 candidatos por tamaño**, 0.011 GB
  leídos. El bucketing elimina el 97% antes de abrir nada, así que el caso que el plan llamaba el importante —el
  tope de 2 en externos— no se puede medir sobre estos datos.
- **El barrido interno no tiene codo**: sigue mejorando hasta c=16 y el tope de 8 deja ~13%. Pero 2,350 MB/s está
  por encima de lo que leen muchos SSD, o sea que esa corrida la sirvió el page cache y mide SHA-256, no disco. Un
  barrido en frío necesita `sudo purge`. **Por eso la política no se cambió**: cambiar un default enviado sobre una
  medición con esa salvedad sería el error que este archivo lleva cincuenta PRs registrando.
- **RSS pico entre 21.7 y 54.8 MB**, contra el objetivo de < 400 MB. Sobra un orden de magnitud.
- **La caché perceptual es la diferencia entre 177 s y 0.5 s**, medido sobre el árbol real de 2,779 imágenes y
  617 videos: **354×**, con el mismo resultado (4,771 pares las dos veces). No es optimización — un video son
  ocho decodes, así que sin caché un segundo escaneo del mismo árbol paga todo otra vez.
- **Su salt se deriva de los parámetros del pipeline, no de una constante que hay que acordarse de subir.**
  Cambiar el decode de 256 a 512 invalida cada hash guardado; con un número a mano eso se olvida exactamente una
  vez y después la caché sirve números que significan otra cosa. La constante sigue existiendo para lo que los
  parámetros no ven (la fórmula de grises, los pesos del resampler), o sea que hacen falta las dos mitades.
- **Las filas son de tamaño fijo con ocho huecos, aunque una imagen use uno.** Se desperdician 56 bytes por
  imagen —156 KB sobre 2,779, contra un escaneo de 177 s— y a cambio `(tamaño - header) % fila != 0` sigue
  detectando una cola truncada, que es toda la historia de recuperación tras un crash. Medido: el archivo de
  3,396 archivos pesa exactamente 32 + 3,396 × 112 = 380,384 bytes.
- **La caché verifica el *tipo*, no solo la clave.** Un inodo reusado por un archivo del otro tipo serviría ocho
  cuadros como si fueran una imagen.
- **El LSH no aplica al video.** Indexa hashes sueltos; el video compara *listas* con una regla codiciosa y
  asimétrica. Así que los videos se comparan por pares como en el CLI — 617 videos son 190,036 pares — y sale
  barato porque cada comparación son popcounts. Lo caro es hashear.
- **Cuatro decodes de video a la vez, medido, no elegido**: 60 videos reales dieron 213 ms cada uno en serie,
  151 ms con cuatro, y **151 ms con ocho**. `AVAssetImageGenerator` ya paraleliza adentro; más workers solo
  suben la memoria.
- **Una marca de tiempo pasada del final NO devuelve nada en `ffmpeg` y SÍ devuelve algo aquí.** Con tolerancia
  de un segundo, `AVAssetImageGenerator` contesta con el cuadro más cercano: un clip de 0.4 s volvió con **ocho
  hashes**, el último cuadro repetido cuatro veces, donde el CLI hashea cuatro. Eso cambia en silencio la
  fracción de cuadros a la que se aplica el 0.70, así que las marcas pasadas del final se filtran antes de
  pedirlas. Medido, no previsto.
- **La aritmética de muestreo de video se preserva exacta, y no es pedantería.** `interval = max(dur/(n+1), 0.1)`
  y cuadros en `interval·(i+1)`: el umbral de 0.70 se calibró contra *ese* muestreo, así que muestrear distinto
  cambia en silencio lo que el umbral significa mientras cada número en pantalla conserva su nombre. El `n+1`
  es lo que mantiene las muestras lejos de los dos extremos, que es donde un video suele estar negro. Y en un
  clip corto **algunas marcas caen pasado el final** —a medio segundo, cuatro de ocho— y eso también se
  preserva: el CLI hashea las que sí y compara sobre menos cuadros.
- **Toda la rama de fast-seek del CLI colapsa en `requestedTimeTolerance`.** El split por 200 MB existe porque
  `ffmpeg -ss` antes de `-i` busca barato al sync sample y después de `-i` decodifica hacia adelante; esa
  propiedad **es** la tolerancia. Y la tolerancia laxa es además la respuesta *mejor*: dos copias del mismo
  archivo caen en el mismo keyframe, y un re-encode con otro GOP cae distinto — justo la variación que el 0.70
  existe para absorber.
- **`video_similarity` es asimétrica y su `break` codicioso infla.** Ocho cuadros de una escena quieta contra un
  clip de un cuadro de la misma escena dan **1.0 en un sentido y 0.125 en el otro**, y un solo cuadro de B
  puede ser la pareja de todos los de A. Se preserva —el umbral se calibró contra eso— pero **cuál lado se
  recorre se fija por bytes**, o el resultado dependería del orden de `os.walk` y el mismo par podría caer de
  los dos lados del umbral entre corridas.
- **El video depende de que un cuadro plano hashee determinista.** Es la razón de fondo de la cuantización tras
  el resample: sin ella, dos cuadros negros de videos distintos darían ruido distinto y el ratio de cuadros
  compararía números ajenos.
- **Los fixtures de video son H.264 baseline y fallan ruidosamente.** Un runner `macos-15` es una VM y puede no
  tener encoder HEVC. Si ni H.264 hay, `SyntheticMovie.write` lanza: una prueba de video que pasa porque no
  hasheó nada es peor que una que falla.
- **La clave de un thumbnail no siempre es el digest.** En un grupo exacto los archivos son idénticos por
  construcción y uno solo sirve para todos; en un par perceptual son **fotos distintas** —es lo que el detector
  encontró— y compartir la miniatura dibujaría una encima de la otra, o sea el peor bug posible en una vista
  lado a lado: haría que todos los pares se vieran idénticos. Por eso `ThumbnailKey.Identity` es `.content` o
  `.path`.
- **El umbral de cada detector es otra cantidad en otra unidad**: carpetas es Dice en porcentaje, imágenes es
  distancia de Hamming en bits sobre 64. Un solo menú mostrando "90%" para los dos serían dos significados
  detrás de un número, así que los ítems se reconstruyen al cambiar de detector.
- **En `similar-scans`, `img_threshold` es entero y `vid_threshold` es float, en el mismo documento** — medido
  en los 31 reales, sin excepción. Es el mismo par de errores opuestos que en carpetas: escribir `10.0` rompe
  los 31, y escribir `similarity` como entero rompe 22 (los otros 9 documentos no tienen pares).
- **Un `media_type` desconocido se rechaza, no se adivina.** El valor decide contra cuál umbral se juzgó el par,
  así que leer uno raro como imagen reportaría mal lo que el escaneo encontró.
- **`file_a` de un par parecido también es la ruta menor por bytes.** `similar-decisions` guarda `keep_a` o
  `keep_b` contra una clave `"a||b"`, así que la orientación decide cuál archivo se borra — misma lección que
  las carpetas, aplicada antes de que costara.
- **Un escaneo perceptual de esta app no trae pares de video**, y eso cambia lo que encuentra. Se reporta en
  `scannedKinds` y el resumen separa los conteos de imagen y de video para que un total no lo esconda.
- **El índice LSH necesita `T + 1` bandas, no `T`.** Es la cota de palomar: con `T` bandas, `T` bits que
  difieren pueden tocar todas, y no queda ninguna idéntica que garantice el encuentro. Medido: bajarlo a `T`
  hace que **6 de 12 semillas pierdan pares** en el test de superconjunto. Y colapsar los hashes idénticos en
  clases antes de indexar no es una optimización de caso raro: **2,779 fotos reales dan 1,630 clases**.
- **Un pHash solo mira las ocho frecuencias más bajas**, así que un tablero de 8 px en una imagen de 128 hashea
  igual que un gris plano — `imagehash` también. No es bug; hay un test que lo fija con su razón, porque la
  alternativa es redescubrirlo como reporte de bug.
- **El tamaño de decode se barrió y 256 está en la meseta.** De 128 a 4096 los pares encontrados no se mueven
  (0.1% de rango); lo que cambia es la coincidencia con Python. Pedirle 32 px a ImageIO es un desastre (10.9%
  idéntico) porque a ese tamaño devuelve su reducción más barata. El Jaccard ≥0.98 que pedía el plan **solo se
  alcanza con decode completo**, a 2.65× el tiempo, y no compra mejores respuestas.
- **Las dos métricas obvias del diferencial contra `imagehash` son ciegas al error que importa.** Quitar el
  `+ 0x8000` de la conversión a grises —la fórmula truncada que el plan especificó mal— deja **88.0% de hashes
  idénticos y un peor caso de 4 bits**, o sea que una tasa de coincidencia y una distancia máxima las dos pasan.
  Lo que sí lo atrapa son **6 pares que una implementación llama casi idénticos (≤2 bits) y la otra ajenos
  (>5 bits)**: esa es la discrepancia que movería un archivo. Por eso el modo `phash-differential` afirma sobre
  los flips de clase y no solo sobre promedios.
- **El diferencial contra `imagehash` lee un archivo de referencia, no lanza Python.** Un subproceso desde el
  bundle firmado no es reproducible y no se puede diffear; la referencia sí, y su rancidez se maneja grabando
  cada ruta —un corpus con un archivo más falla en vez de comparar de menos.
- **Las únicas divergencias sistemáticas contra `imagehash` son las 16 imágenes con rotación EXIF**, de 2,779.
  Nosotros aplicamos la orientación y Pillow no: una copia que solo difiere en el flag debería coincidir con su
  original. Sin ellas el peor caso es de 4 bits.
- **El resultado del chequeo de disco se guarda en `Caches`, con su fecha, y nada destructivo lo cree.**
  Tarda lo suficiente para no valer repetirlo, y conserva casi todo su valor —un escaneo de mayo cuyos
  archivos ya no están seguirá sin tenerlos mañana— pero solo es cierto en el instante en que se tomó. El
  apply re-hashea cada archivo justo antes de moverlo, así que una foto vencida cuesta un archivo rehusado
  y un error honesto, nunca un movimiento equivocado.
- **Se guarda por clave de grupo, no por índice.** Un índice solo significa algo para un documento exacto;
  `size:digest` sobrevive un re-escaneo del mismo contenido, que es justo para lo que sirve guardarlo.
- **Un selftest que usa un default de `~/Library/Caches` contamina la siguiente corrida.** Pasó: la foto
  de una corrida anterior hizo que un chequeo de dientes fallara en la aserción equivocada. El directorio
  se inyecta y el modo apunta a `/tmp`.
- **`timestamp(from:)` omite el `.000000` en un segundo exacto, y eso es correcto**: medido,
  `datetime(2026,8,12,12,0,0).isoformat()` en Python tampoco lo pone. Un test que esperaba la forma
  rellenada estaba equivocado sobre el formato, no sobre el código.
- **Con un filtro activo, la fila de la barra lateral es un índice en la lista *visible*, no en el
  escaneo.** Y cualquier mutación puede cambiar esa lista: decidir un grupo con "sin decidir" encendido lo
  saca. Sin reconstruir después de mutar, la barra sigue mostrándolo mientras el estado ya avanzó — lo
  atrapó una captura real: la barra resaltando "Grupo 31" y el encabezado diciendo "Grupo 32 de 880".
- **Un nombre truncado por el final esconde justo lo que distingue dos duplicados.** Un grupo real era
  `grok-video-d4456bb8-…-1d380340c634.png` junto a `…_0002.mp4`: comparten 40 caracteres de prefijo y
  difieren al final. Truncación en el medio.
- **En AutoLayout el contenido dicta el tamaño de la ventana salvo que se le diga que ceda.** Tres cosas
  distintas pusieron piso al ancho de la ventana de revisión, una tras otra, y las tres se ven igual en
  `fittingSize`: un `NSTableView` reporta como ancho intrínseco **la suma de sus columnas** (718 pt aquí, y
  a través del scroll view eso se volvió requisito); una etiqueta reporta el ancho intrínseco de su texto,
  y un aviso de 110 caracteres pide ~900 pt; y una etiqueta de ruta con 150 caracteres, lo mismo. La cura
  es la misma en los tres: bajar `contentCompressionResistancePriority` en horizontal. Un scroll view
  existe justamente para poder ser más angosto que su contenido.
- **Un tope de ancho en la vista que *cede* dentro de un `NSSplitView` impide que la ventana crezca.** La
  división solo puede crecer creciendo la vista que cede; si esa está topada, no hay a dónde poner el
  ancho extra y la ventana se niega a ensancharse. El tope va en la que **retiene**, o en el contenido.
- **`Int(window.maxSize.width)` truena.** El default es `CGFloat.greatestFiniteMagnitude` y no cabe en un
  `Int`: `Swift runtime failure: Double value cannot be converted to Int`. Cinco reportes de crash de un
  diagnóstico de tres líneas.
- **Un `imageView` con la altura amarrada a su ancho le pone piso a la ventana.** `height == width` en un
  panel de 1,100 pt de ancho exige 1,100 pt de alto: empuja el resto del layout fuera y **AppKit rehúsa
  achicar la ventana**, porque un constraint requerido es requerido. Un síntoma ("no se deja redimensionar")
  y el otro ("no veo la tabla ni la imagen") tenían esa única causa.
- **`fittingSize` es la propiedad de layout que sí se puede afirmar.** Es el tamaño mínimo que los
  constraints exigen, o sea exactamente lo que decide si una ventana se puede achicar. La aserción falla con
  `996 points of height` contra el código que se envió y pasa con el arreglo. Las tres ventanas la llevan.
- **Un selftest que lee texto de celdas no ve un problema de layout.** Los modos pasaban con el bug
  enviado. Que una ventana muestre lo correcto y sea inusable son cosas distintas.
- **Una ventana necesita `minSize`, no confiar en sus constraints.** Arrastrada por debajo de lo que el
  layout necesita, AutoLayout empieza a romper constraints y el panel de detalle desaparece entero — visto
  en una captura real: ventana aplastada, mitad derecha vacía, sin pie.
- **`make lint` no ve los warnings del compilador.** Es `swift-format`, no `swiftc`. Un `try?` sin usar pasó
  el gate y salió en la consola del usuario.
- **Cambiar el valor por default de un campo no es un arreglo de copy.** Poner "1 KB" en el campo de
  tamaño mínimo se veía como aclarar la unidad y era una divergencia de comportamiento: el archivo de 6
  bytes dejó de contarse y el modo `scan-window` lo atrapó. El default del CLI es 1 byte y ahí se queda;
  un default que valga cambiar se cambia a propósito, en su propio cambio, y se dice en el README.
- **Una línea malformada rompe el parseo del `.strings` completo.** Un `\n` literal en vez de un salto real
  dejó `NSDictionary(contentsOf:)` sin poder leer el archivo, y el modo `l10n` reportó **todas** las claves
  como ausentes, no solo la de al lado. El síntoma no señala la causa.
- **`NSAlert` no renderiza markdown.** Los asteriscos de `**énfasis**` salen como asteriscos.
- **Un pie con dos botones que suenan a "confirmar" es un botón de más.** "Guardar decisiones" al lado de
  "Simular y aplicar" hacía preguntar si guardar era requisito de aplicar — y no lo es. Quedó un solo
  botón primario; guardar pasa solo, antes de aplicar y al cerrar. Reportado como poco intuitivo desde el
  uso real, y lo era.
- **Cerrar la última ventana ahora cierra la app**, y un clic en el Dock o un `open` traen la biblioteca de
  vuelta. La elección original —seguir viva sin ventanas— dejaba la app corriendo sin nada que hacer y sin
  forma de recuperar una ventana salvo Salir; y `make run` usa `open`, que activa la instancia corriendo en
  vez de lanzar otra, así que no aparecía nada hasta cerrarla a mano. Los dos se arreglan manejando el
  evento de reopen.
- **Un atajo de teclado no es una interfaz.** Simular y aplicar existía solo como ⌘⇧D y un ítem de menú,
  y nada en pantalla decía que una revisión se podía aplicar; revisar un escaneo solo se descubría por
  doble clic. Las dos acciones primarias de la app llevan botón: el de simular en el pie de la revisión,
  junto al conteo que ya atrae la vista, y el de revisar en la toolbar de la biblioteca. Los atajos siguen
  en los menús, que es donde un atajo se vuelve descubrible **después** de saber que existe. Lo reportó el
  uso real.
- **Todo lo que mueve archivos tiene que refrescar la presencia, y eso incluye deshacer.** El primer
  cableado solo lo hacía tras aplicar, así que la ventana seguía diciendo "este archivo ya no existe"
  sobre un archivo que acababa de volver. Lo encontró el uso real, no un test.
- **Probar cancelación necesita trabajo que no pueda terminar solo.** Cancelar antes de que empiece no prueba
  nada: el `Task` lanza en su primer punto de suspensión, así que el modo pasaba con **todos** los
  `checkCancellation` quitados. Y esperar a que el hasheo avance tampoco alcanza: con 400 archivos chicos el
  escaneo **termina entre el sondeo y el cancel** — pasó local y **falló en CI**, que es una carrera disfrazada de
  prueba. La cura es un hasher que envuelve al real y duerme 3 ms por archivo: con dos segundos de trabajo por
  delante, "se detuvo" y "se detuvo en menos de 300 ms" las dos significan algo.
- **Poner `AppleLanguages` en `UserDefaults` no cambia el locale de un proceso ya lanzado.** Un modo que lo hacía
  y recorría tres identificadores afirmaba lo mismo tres veces mientras decía haber probado tres locales. La
  propiedad real se prueba construyendo un `NumberFormatter` alemán explícito y mostrando qué escribiría él.
- **Un arnés que llama él mismo a la función arreglada no tiene dientes.** La primera versión de esa
  aserción invocaba `reloadFromDisk()` y luego afirmaba: pasaba con el arreglo quitado, porque probaba que
  la función sirve y no que algo la llame. Hay que manejar el camino de producción — el botón de la hoja —
  y no tocar nada más.
- **El panel muestra la ruta completa, no solo el nombre.** Con el padre común izado fuera de las filas,
  un panel con solo el nombre no deja distinguir dos archivos que se llaman igual. También lo encontró el
  uso real.
- **El plan de aplicar sale de `removalPlan`, no de `decisionsForSaving`.** Son dos funciones distintas
  sobre el mismo tri-estado, y confundirlas hace que un arnés pruebe la que no importa: medido, romper
  `decisionsForSaving` deja pasar la aserción de "una revisión intacta no planea mover nada", y romper
  `removalPlan` la hace fallar.
- **Confirmar es lo que convierte un preview en decisión.** Dejar el keep set correcto no alcanza: si el
  heurístico ya eligió bien, no hay nada que alternar y el grupo sigue `.undecided`. Eso es el
  tri-estado funcionando, y un arnés que solo alterna casillas obtiene un plan vacío — ya pasó.
- **Cancelar un apply no puede lanzar: tiene que devolver reporte.** Lanzar desde el chequeo al inicio del loop
  **se saltaba el `flush()` final**, así que hasta 31 archivos ya movidos quedaban en la Papelera **sin entrada en el
  journal** — o sea invisibles para el deshacer. Ahora rompe el loop, hace el flush y devuelve el reporte con
  `wasCancelled`, que es lo que la ventana necesita para ofrecer el undo de lo que sí se movió.
- **`Task.isCancelled` funciona en código síncrono**, así que el runner exacto honra un cancel sin volverse `async`:
  corre en una tarea desprendida y ahí la bandera se ve.
- **Y el botón de detener se queda vivo durante el apply.** Verificar y mover cientos de ítems toma minutos, y una
  barra de progreso sin salida no es una opción. Cerrar la hoja mientras corre **detiene y no cierra**, porque el
  reporte de lo que ya se movió es justo la razón para no cerrar.
- **Veinte fallas seguidas detienen un apply; una sola no.** Un archivo bloqueado por otro proceso no
  puede abortar los otros 3,997, pero un problema global —permiso revocado, volumen que se fue— no debe
  producir cuatro mil filas idénticas que leer.
- **El journal se escribe en lotes de 32 durante el apply, no al final.** Un crash a media corrida tiene
  que dejar un journal que describa lo que ya se movió, o esos archivos no se pueden devolver.
- **`Mutex` es noncopyable**, así que no se puede capturar en los closures que escapan (el de progreso y
  el del `Timer`). Una clase `Sendable` con un `Atomic` adentro sí.
- **El closure de un `Timer` es nonisolated**, así que pasarle el propio `timer` para invalidarse es una
  carrera que el compilador rechaza. Se guarda el timer en una propiedad `@MainActor` y se invalida ahí.
- **Launch Services arranca la app con `RLIMIT_NOFILE` blando en 256.** Quedarse sin descriptores no
  truena: sale como archivo ilegible, se cuenta como candidato saltado, y **el escaneo encuentra menos
  de lo que debía** — una falla que se ve como una respuesta más chica, no como un error. `main.swift`
  lo sube a 4096 antes de que nada abra un archivo.
- **Desde una terminal el límite blando ya viene en millones** (medido: 1048576), así que un arnés que
  solo mire el valor actual pasa exista o no el `setrlimit`. El modo `fdlimit` **baja el límite a 256 él
  mismo**, llama a la misma función que llama el arranque, y verifica que volvió a subir. Bajar siempre
  se puede; subir está acotado por el límite duro, que no se toca.
- **Guardar es lo último que pasa en un escaneo, y una falla al guardar se reporta, no se lanza.** Un
  escaneo de 800,000 archivos que terminó bien no se puede tirar porque el directorio de estado estaba
  de solo lectura: quien llama todavía puede revisarlo en memoria. Lanzar convertiría un problema
  recuperable en veinte minutos perdidos.
- **Un escaneo cancelado no escribe nada**, porque el save va después de que el finder regresa. Los
  appends de la caché de hashes **sí se conservan**: son hechos verdaderos, y tirarlos haría pagar el
  precio completo otra vez.
- **`ScanSession.run` toma un `Date` y resuelve el instante adentro.** Una versión anterior daba un
  identificador por un método y tomaba un instante por otro, lo que dejaba deduplicar uno y guardar bajo
  el otro — el identificador decide el nombre del archivo y el instante decide lo que va estampado
  adentro, y tienen que salir del mismo valor.
- **La clave de un thumbnail es el digest, no la ruta.** Los archivos de un grupo tienen contenido
  idéntico por construcción, así que ocho fotos necesitan **un** thumbnail. Keyear por ruta manda ocho
  viajes de XPC a `quicklookd` y guarda ocho copias del mismo bitmap.
- **La extensión también va en la clave, y está documentado por Apple, no es precaución.**
  `QLThumbnailGenerator.Request` dice que el content type *"is derived from the file extension"*, y el
  content type elige el **proveedor** del thumbnail. Así que los mismos bytes llamados `a.pdf` y `a.dat`
  se dibujan distinto con toda razón.
- **`QLThumbnailGenerator` es XPC y puede colgarse.** Toda petición corre contra un plazo de 2 s; perder
  la carrera cancela la petición y cae al icono del archivo, que `NSWorkspace` saca de la base local y no
  se puede colgar. Una ventana que se congela porque una extensión de thumbnails se trabó es peor que una
  que muestra un icono genérico.
- **`attributesOfItem` NO sigue symlinks** — medido, y lo contrario es la suposición fácil. Aquí es el
  comportamiento correcto: un symlink nunca es miembro de un escaneo, así que uno parado en una ruta
  registrada significa que el archivo fue reemplazado. Y `trashItem` sobre un symlink manda el enlace y
  deja los bytes, o sea espacio "liberado" que ningún `df` confirma.
- **Contar entradas de una caché de thumbnails es inestable.** El tamaño en píxeles viene del ancho del
  panel, el ancho se asienta durante el layout, y una ventana que nunca se muestra hace layout cuando le
  toca. Tres de seis corridas guardaban dos entradas —una por tamaño— con código correcto. La propiedad
  estable, y la que la clave por digest existe para dar, es que el **segundo archivo del grupo no falle**
  la caché.
- **Un atajo de menú es global.** Return o espacio como `keyEquivalent` dispararían mientras el usuario
  escribe en el campo de búsqueda de la biblioteca. Esas dos teclas viven en `ReviewTableView.keyDown`,
  donde solo significan algo porque una lista de archivos tiene el foco. Lo demás sí va al menú, que es
  lo que le da descubribilidad, localización y el chequeo de colisiones del modo `menu`.
- **Y tampoco llega sin `windowWillReturnUndoManager`.** AppKit le pide el manager al *delegate de la ventana*; sin
  eso el `undo:` del menú Edición no alcanza nada y el ítem sale gris — una revisión con deshacer perfecto e
  invisible.
- **`UndoManager` agrupa por vuelta del run loop, y eso es correcto para escribir y falso para un lote.** Aceptar
  2,106 pares en una llamada sería indistinguible de una decisión. Se agrupa a mano (`groupsByEvent = false` más
  `beginUndoGrouping`), **y nunca durante un undo**: abrir un grupo dentro de `undo()` rompe el seguimiento de fase
  del manager y la registración que hace el undo aterriza otra vez en la pila de undo en vez de la de redo.
- **Cuántos pasos de ⌘Z se pueden dar es propiedad del run loop, no del código.** Un arnés que llama dos hooks
  seguidos no son dos eventos, así que afirmar "dos undos" ahí prueba el agrupamiento del arnés. Lo que sí se puede
  afirmar: que algo quedó registrado, que deshacer cambia el estado, y que **el archivo deja de tener la decisión que
  la ventana ya no muestra** — porque estas revisiones guardan al decidir, así que un undo que solo toque memoria
  dejaría al CLI leyendo lo contrario.
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
- **La regla de compactación por filas muertas era imposible de disparar, y está medido.** Una fila queda
  superseded solo si la misma clave se escribe con otro digest — y la clave carga tamaño, mtime y generation, así
  que un archivo con contenido nuevo produce una clave **nueva** en vez de matar la vieja. En las dos cachés
  reales de esta máquina: `hashes.v1` tiene 6,661 filas y 6,661 claves distintas, `phashes.v1` tiene 3,396 y
  3,396. **Razón exactamente 1.0000 tras 119 escaneos.** El test que ejercitaba la regla tenía que escribir diez
  digests bajo una clave, o sea fabricar un estado que producción no alcanza.

  Lo que sí es alcanzable es basura: una cola parcial de un crash a media escritura, y una fila con CRC roto.
  Esas se releen y se descartan en **cada** carga, para siempre. Ese es el disparador de la reescritura, y ahora
  producción la llama: `loadAndRepair()` en las cuatro sesiones que abren una caché.
- **Un archivo que este build no puede leer se deja quieto, no se pisa.** Magic o versión desconocidos pueden ser
  de un build **más nuevo**; reescribirlo le costaría su caché a ese build para no ganar nada, porque las filas se
  ignoran igual. Por eso `discardedFile` no dispara la reescritura y `hadTornTail`/`corruptRecords` sí.
- **La caché perceptual no tenía `flock` y la de digests sí**, lo cual era una inconsistencia y no una decisión:
  dos procesos agregando filas de 112 bytes al mismo archivo las intercalan, y un CRC puede decir que una fila
  está rota sin poder decir cuáles dos escritores la hicieron. Ya lo tiene, con la misma degradación a solo
  lectura: el que pierde el lock sirve todos sus hits y no escribe.
- **El lock se sostiene mientras el objeto vive, y eso rompió tres tests y un arnés.** Dos instancias vivas sobre
  el mismo archivo son un perdedor de lock, no dos pipelines: en producción cada sesión crea su caché dentro de
  `run()` y la suelta al volver, pero un test que deja la primera en scope hace que la segunda salga read-only y
  —correctamente— se niegue a escribir. Los tests van con `do { }` por instancia y el modo `cache` usa su propio
  archivo para el chequeo de reparación.
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
