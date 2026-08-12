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

Modos actuales: `bundle`, `state-dir`, `l10n`, `menu`, `json-roundtrip`, `scans`, `digest`.

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
- **`Resources/Info.plist` es una plantilla.** Cambiar `CFBundleIdentifier` invalida todos los
  permisos TCC ya otorgados.
- **El nombre del job de CI es el status check requerido en el ruleset.** Renombrarlo deja de
  proteger `main` en silencio, porque el ruleset espera un contexto que ya no reporta.
- **CI corre solo en pull requests**, nunca en push, por costo: los runners de macOS facturan 10× y
  el repo es privado. Cubre bases `main`, `feat/**` y `fix/**`, y el tipo de evento `edited`, porque
  sin eso un PR apilado no reporta checks y puede llegar a `main` sin haberse probado nunca.
- **No pedir Full Disk Access.** No hay API para pedirlo, solo un toggle manual, así que "pedirlo"
  significa molestar. Los duplicados dentro de `~/Library` son abrumadoramente cachés donde quitar un
  "duplicado" rompe una app. Y una app que pide Acceso Total al Disco para ordenar Descargas es
  indistinguible de malware para un usuario cuidadoso. `~/Library` se excluye por default.
- **No sandboxear.** `~/.local/state/rav/` está fuera del contenedor, y el estado compartido con el
  CLI es el punto de la app.
