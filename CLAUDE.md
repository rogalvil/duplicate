# Instrucciones para Claude Code

App con ventana para macOS que encuentra archivos duplicados: exactos por SHA-256, carpetas por
coeficiente de Dice, media por hash perceptual. Swift nativo, AppKit programático, sin dependencias
externas. Puerto de `rav duplicate`, un CLI en Python del mismo autor.

El detalle de arquitectura y las alternativas descartadas están en
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). **Lo que la app hace hoy, capacidad por capacidad, está en
[`docs/CAPACIDADES.md`](docs/CAPACIDADES.md), y se actualiza en el mismo PR que cambia la funcionalidad** —
incluida su sección de solapamientos, que es donde se anota el código que calcula algo que nadie muestra.

**Los pendientes viven en los issues del repo**, con etiquetas `priority:p1`…`p4` y `bloqueado`, no en un
markdown: dos listas de lo mismo garantizan que una quede vieja. `gh issue list --label bloqueado` dice además
*por qué* algo no se ha podido hacer, que es lo que cuesta reconstruir.

## Comandos

`make help` lista todos los objetivos, incluidos los modos de `make selftest MODE=…`.

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

**Todo pasa por PR. `main` está protegido por dos rulesets y lo rechaza del lado del servidor.**
`protect main`, sin bypass para nadie: se exige PR, CI verde y rama al día con `main`, solo merge commit, y no
hay force-push ni borrado. `approval for collaborators` exige además la aprobación de un **code owner**
(`.github/CODEOWNERS`), que caduca con un push nuevo, y exime **solo** al admin, porque GitHub no deja aprobar el PR
propio. Van separados a propósito: un bypass en el primero eximiría al dueño también del CI. La única excepción ya
ocurrió: el commit inicial de boilerplate que creó la rama, porque GitHub no puede abrir un PR sin rama base.

**En un PR del dueño, el review `APPROVED` del bot de Greptile cumple ese segundo ruleset**, aun con el requisito de
code owner puesto. Está medido con `GET /rulesets/rule-suites`: #208 y #209 lo pasaron sin excepción. Cuando el bot
solo comenta, como en #210, la regla falla ("At least 1 approving review is required by reviewers with write
access") y el PR queda `BLOCKED`. Entonces, con CI verde y la rama al día, se mergea con
`gh pr merge <n> --merge --admin --delete-branch`. Eso salta solo esa regla: `protect main` no tiene excepción, se
evalúa igual, y la suite queda registrada como `bypass`. No está probado si el requisito de code owner frena al bot en
el PR de un colaborador, porque hace falta una segunda cuenta (#212).

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

Las trampas de un área viven en `.claude/rules/`, una por área, y se cargan solas cuando se toca un archivo
de esa área. Antes de un cambio que cruce áreas, leer las que apliquen:

| Archivo | Área |
|---|---|
| [`walk-tcc.md`](.claude/rules/walk-tcc.md) | Recorrido, TCC y directorio de estado |
| [`apply-undo.md`](.claude/rules/apply-undo.md) | Aplicar, deshacer, journal y disposer |
| [`hash-cache.md`](.claude/rules/hash-cache.md) | Hasheo, cachés, escaneo y mediciones de rendimiento |
| [`folders.md`](.claude/rules/folders.md) | Detector de carpetas |
| [`media.md`](.claude/rules/media.md) | Detector perceptual: imagen y video |
| [`interop.md`](.claude/rules/interop.md) | Formatos compartidos con el CLI |
| [`review.md`](.claude/rules/review.md) | Revisión y decisiones |
| [`appkit.md`](.claude/rules/appkit.md) | Ventanas, menús y AppKit |
| [`l10n.md`](.claude/rules/l10n.md) | Localización |
| [`selftest.md`](.claude/rules/selftest.md) | Selftest, tests, build y CI |

Las de aquí cruzan todo el proyecto. No re-descubrirlas:

- **`String ==` de Swift compara por equivalencia canónica; el de Python no.** La "á" precompuesta
  (U+00E1) y la descompuesta (U+0061 U+0301) son iguales en Swift y distintas en Python, y **las dos
  aparecen dentro de un mismo archivo de scan real** de este usuario, porque APFS preserva los bytes
  que cada escritor usó. Usar `String` como clave de diccionario colapsaría dos rutas que el CLI
  trata como distintas y perdería una de sus dos decisiones — o sea, un archivo mandado a la Papelera
  sin haberse revisado nunca. Y `String <` no es orden de code point, así que ordenar con él
  divergiría del `sorted()` de Python. Todo pasa por `PathOrder`, que compara bytes UTF-8.
- **Los métodos de ruta de `NSString` limpian lo que devuelven.** `deletingLastPathComponent` y
  `appendingPathComponent` colapsan un `//`, así que una ruta armada con ellos deja de ser, byte a byte, la ruta de
  la que salió, y todo lo que aquí empata rutas por bytes deja de verla. Pasó con el destino de un renombrado (#228),
  que el deshacer ya no reconocía como la ruta que el otro archivo dejó libre. Una ruta que se va a comparar se corta
  sobre sus bytes UTF-8.
- **el externo es APFS case-sensitive.** `Foo.jpg` y `foo.jpg` son dos archivos ahí y uno en el volumen
  de arranque. Otra razón para no normalizar rutas nunca.
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
- **Un `defaults write` sobre `AppleLanguages` cambia la preferencia real del sistema del usuario.** Lo hice a
  mano "para simular inglés" y le cambié el idioma a su máquina. Es la misma trampa que ya está escrita para el
  arnés, cometida fuera del arnés: el locale de un proceso no se simula desde afuera, y para probar la otra
  tabla se lee la tabla, no se cambia el sistema.

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

**Antes de abrir un PR, `make ui`.** Abre cada ventana en dos idiomas, al tamaño con que abre y, si se puede
redimensionar, también a su mínimo y al de una laptop. Busca texto cortado, controles encimados, claves sin
traducir y paneles aplastados, y deja capturas en `build/ui/`. **CI no lo corre, a propósito**: la
mitad de su valor son las capturas, y en CI nadie las mira. Así que nada lo exige salvo esta regla: su salida
va en la verificación del PR, y las capturas de las ventanas que el cambio toca se miran antes de abrirlo. Si
falla por un problema que ya tiene issue, el PR lo dice con su número.

**Lo que se puede verificar desde código no se pide a mano.** Si una duda no la contesta `make ui` (arrastrar la
esquina, un caso que el árbol de prueba no arma, confirmar la causa de un bug), se escribe un **chequeo
temporal**: código dentro del selftest que reproduce el caso y lo mide. Se corre, su salida y sus capturas van al
issue o al PR, y **se borra antes del commit**. Si lo que verificó puede volver a romperse, no se borra sin más:
se vuelve un assert permanente, en un modo de CI o en una regla de `make ui`, con su prueba de que falla contra
la versión rota. A mano solo queda lo que ninguna herramienta puede simular sin cambiar lo que mide: los
permisos de TCC, cuyo guion está al final de [`docs/SELFTEST.md`](docs/SELFTEST.md).

**El manual de uso ([`docs/MANUAL.md`](docs/MANUAL.md)) muestra capturas de `make ui`.** Un PR que cambia una ventana
que aparece ahí sube las capturas nuevas y actualiza el manual en el mismo cambio, igual que `CAPACIDADES.md`.

**Un cambio que se ve lleva capturas**, antes y después, de `build/ui/`, en el PR y en el issue. Se suben con
`scripts/push-captures.sh` a la rama `ui-captures`, que nunca se mergea y no se borra, porque los PR las citan
por URL. Solo capturas de `make ui`, nunca la pantalla del usuario: el repo es público. Las trampas técnicas
de los chequeos temporales (eventos sintéticos, autosave, live resize) están en
[`docs/SELFTEST.md`](docs/SELFTEST.md).

**Un issue se trabaja con evidencia visual comprobada.** Al confirmar que un issue sigue vigente, se le agrega
la captura que lo muestra, de `make ui` o de un chequeo temporal, y su PR lleva el antes y el después. Si el
issue no tiene pantalla (un tiempo, el contenido de un archivo, un menú del sistema, ⌘Q), no se fabrica una
captura que no muestra nada: **se le dice al usuario, y se decide con él qué evidencia vale**. Puede ser un
selftest que falla y pasa, un archivo antes y después, o una medición.

**Un issue se cierra solo cuando se demostró que no existe, nunca porque no se pudo reproducir.** Hay dos
resultados distintos y no se confunden:
- **No existe:** la causa está medida y explica por qué el problema no puede pasar. Ejemplo: #145, donde la hoja
  de aplicar hace que AppKit rechace la salida antes de consultar a la app, trazado sobre la app real y
  confirmado a mano. Se cierra con esa evidencia.
- **No se pudo reproducir:** el entorno de prueba no alcanza el caso (un permiso de TCC, un volumen de red, un
  clic que no se puede emular, un tiempo que no se puede forzar). **El issue se queda abierto**, con un comentario
  que dice qué se intentó y qué límite técnico lo impidió, y se le dice al usuario.

## Qué no tocar sin plantearlo

- **No agregar dependencias externas.** Cero dependencias es requisito del proyecto. `libsqlite3`
  está en el SDK y estaría *permitido*, pero se rechazó por mérito: el workload es un lookup puntual
  sobre clave compuesta, y SQLite traería WAL, shm y semántica de `busy_timeout`, o sea más
  superficie de corrupción, no menos.
- **Un grupo sin revisar NO se escribe en el archivo de decisiones.** El CLI escribe una entrada para
  cada grupo con el default de la heurística, así que salir tras el grupo 1 de 50 registra decisiones
  para 49 y aplicar actúa sobre todos. En una terminal eso pide un `q` deliberado; en una ventana,
  salir es cerrar la ventana. La ausencia de la clave es el contrato, y las dos herramientas la
  respetan.
- **Una ruta original ocupada nunca se sobrescribe.** Contenido byte-idéntico cuenta como *ya
  restaurado* (pudo haberlo devuelto el propio Finder, que la app no puede ver); cualquier otra cosa
  se bloquea. El runner **vuelve a chequear** justo antes de mover, porque el plan pudo mostrarse al
  usuario minutos antes.
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
- **Una pieza que calcula un dato "para que alguien lo reporte" es peor que código muerto.** Tiene test y
  comentario, así que **parece una capacidad**. El inventario de `docs/CAPACIDADES.md` encontró cuatro en su
  primera pasada; la regla es decidir cada una: se cablea o se borra. Se cablearon `isAmbiguous` (aviso al cerrar)
  y `usableCount` (cuántos cuadros sostienen un veredicto de video); se borraron `HashCache.verify` —dos caminos
  de verificación para un chequeo destructivo es peor que uno, porque quien lee no sabe cuál corre— y
  `VideoSimilarity.directionsDisagree`, informativo y a costa de una segunda pasada sobre 190,036 pares.
- **`make lint` no ve los warnings del compilador.** Es `swift-format`, no `swiftc`. Un `try?` sin usar pasó
  el gate y salió en la consola del usuario.
- **`Resources/Info.plist` es una plantilla.** Cambiar `CFBundleIdentifier` invalida todos los
  permisos TCC ya otorgados.
- **El nombre del job de CI es el status check requerido en el ruleset.** Renombrarlo deja de
  proteger `main` en silencio, porque el ruleset espera un contexto que ya no reporta.
- **No pedir Full Disk Access.** No hay API para pedirlo, solo un toggle manual, así que "pedirlo"
  significa molestar. Los duplicados dentro de `~/Library` son abrumadoramente cachés donde quitar un
  "duplicado" rompe una app. Y una app que pide Acceso Total al Disco para ordenar Descargas es
  indistinguible de malware para un usuario cuidadoso. `~/Library` se excluye por default.
- **No sandboxear.** `~/.local/state/rav/` está fuera del contenedor, y el estado compartido con el
  CLI es el punto de la app.
