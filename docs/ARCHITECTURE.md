# Arquitectura

Este documento explica **por qué** el proyecto está armado así. El *qué* se lee del código; lo que no
se lee del código son las alternativas que se descartaron.

## Flujo

```
       elegir raíz
            │
            ▼
    ┌───────────────┐   recorrido de un hilo, 13 claves de recurso en un batch
    │ DirectoryWalk │   poda por identidad de directorio, no por string
    └───────┬───────┘
            ▼
    ┌───────────────┐   agrupar por tamaño → prefijo (4 KiB inicio + fin) → SHA-256
    │  ContentHash  │   TaskGroup acotado, caché de hashes por (dev, ino, size, mtime, gen)
    └───────┬───────┘
            ▼
    ┌───────────────┐   partir cada grupo por (volumen, inode) y por contentID:
    │  GroupBuilder │   hardlinks y clones no cuentan como espacio recuperable
    └───────┬───────┘
            ▼
      scans/<id>.json ──────────► también legible por `rav duplicate`
            │
            ▼
    ┌───────────────┐   tri-estado por grupo: sin decidir / decidido / omitido
    │  ReviewState  │   solo lo decidido llega a decisions/
    └───────┬───────┘
            ▼
      decisions/<id>.json ──────► también legible por `rav duplicate`
            │
            ▼
    ┌───────────────┐   re-hashea antes de actuar; Papelera real; journal append-only
    │   Disposer    │   fallback a cuarentena solo si trashItem falla
    └───────┬───────┘
            ▼
      journal/<id>.jsonl ───────► solo de esta app; habilita deshacer
```

## Decisiones

### Swift nativo, no una GUI sobre el CLI en Python

**Descartado: que la app hiciera `subprocess` a `rav duplicate --json` y parseara la salida.** Menos
código y una sola implementación de la lógica. Se rechazó por tres razones: requeriría Python
instalado y en la versión correcta; heredaría el escaneo serial y sin caché, que es justamente el
problema a resolver; y TCC sobre un subprocess es un dolor — el proceso responsable sería el
intérprete de Python, no la app.

### Tres targets, y la división es load-bearing

**Un `executableTarget` de SwiftPM no se puede importar desde un target de test.** Cualquier cosa que
viva en el ejecutable es permanentemente no testeable. De ahí la división: `DuplicateCore` es una
librería con toda la lógica, `Duplicate` es el ejecutable con solo el glue de AppKit.

La línea no es "framework sí o no", es **valores contra dispositivos**. CryptoKit, Accelerate, ImageIO
y `AVAssetImageGenerator` sobre un URL de archivo son valores y van en Core. `NSWorkspace`,
`NSWindow` y `NSOpenPanel` necesitan sesión gráfica y van en el ejecutable.

`FileManager.trashItem` va en **Core**, y esa es la decisión menos obvia de la lista: son valores, no
hay dispositivo, no hay prompt de TCC, y solo necesita permiso de escritura ordinario — que el test
target tiene en `tmp`. Un test manda un archivo temporal a la Papelera, verifica que la ruta original
quedó vacía y que el URL devuelto existe, y luego lo deshace y verifica que el archivo volvió
byte-idéntico. La acción destructiva es la pieza más riesgosa de la app; precisamente por eso está del
lado testeable.

### Cobertura solo sobre Core, con piso de 80%

La reducción es el punto, no un atajo. La mitad de una app de macOS es glue que no puede correr sin
window server, y nunca se ejecuta bajo test. Un porcentaje de todo el repo mezcla eso y produce un
número que se mueve por razones que no tienen que ver con la calidad del código. Reducido a Core, un
80% significa algo.

### Rutas como `String`, y comparación por bytes

**Descartado: usar `URL` como representación primaria y `String ==` para comparar.** Dos fallos
concretos, los dos silenciosos:

`URL(filePath:)` resuelve una ruta relativa contra el directorio de trabajo. Un `XDG_STATE_HOME`
relativo se volvería absoluto sin aviso y no habría forma de detectarlo — y Launch Services arranca la
app con `/` como directorio de trabajo.

`String ==` de Swift compara por equivalencia canónica Unicode; el de Python no. La "á" precompuesta
(U+00E1) y la descompuesta (U+0061 U+0301) son iguales en Swift y distintas en Python, y **las dos
aparecen dentro de un mismo archivo de scan real** de este usuario, porque APFS preserva los bytes que
cada escritor usó. Usar `String` como clave de diccionario colapsaría dos rutas que el CLI trata como
distintas y perdería una de sus dos decisiones — un archivo mandado a la Papelera sin revisarse nunca.
Y `String <` no es orden de code point, así que ordenar con él divergiría del `sorted()` sobre `Path`
de Python, y dos herramientas reportarían el mismo scan en órdenes distintos.

Un matiz que se midió después y conviene tener escrito: **la forma en que un nombre queda almacenado
depende del volumen.** El disco de arranque convierte a NFD un nombre escrito como NFC; el externo
case-sensitive preserva NFC. Por eso el corpus real tiene las dos formas (38 solo-NFD, 10 solo-NFC de
71,580 rutas) y por eso un fixture en `/tmp` no puede contener un nombre NFC — esa aserción vive sobre
strings en memoria, no sobre el filesystem.

Como el orden de bytes UTF-8 *es* orden de code point, comparar los bytes crudos reproduce Python
exactamente. Regla: **la identidad canónica de una ruta es la secuencia cruda de bytes UTF-8 que
produjo el recorrido.** Nunca normalizar.

Un detalle que cae del mismo lugar: `URL.appending(path:directoryHint: .isDirectory)` agrega slash
final, y `FileManager.fileExists(atPath:)` nunca matchea una ruta con slash final contra un archivo
regular. Un archivo sentado donde va un directorio se lee como "aquí no hay nada". La suite de tests de
`StateDirectory` encontró ese bug la primera vez que corrió.

### `Digest32` en vez de un hex `String`

Un scan de 800,000 archivos necesitaría 800,000 strings de 64 caracteres: 60+ MB de heap, y cada
comparación de grupo haciendo trabajo Unicode. Cuatro `UInt64` son 32 bytes inline y cuatro
comparaciones enteras.

Los words se cargan big-endian para que el orden entero coincida con el orden de bytes, que a su vez
coincide con el orden del hex minúscula — porque los dígitos hex son monótonos en valor de nibble. Esa
equivalencia es lo que permite reproducir el `key=(-size, digest)` del CLI sin materializar un solo
string. Hay un test que la fija; si dejara de valer, las dos herramientas ordenarían distinto.

### JSON escrito a mano

**Descartado: `JSONEncoder` y `JSONSerialization` con `.prettyPrinted`.** Ninguno produce los bytes
que produce Python, y el formato es un contrato compartido con una herramienta que ya está en uso.
Cinco diferencias, verificadas contra los archivos reales:

1. Python usa `ensure_ascii=True`, así que el no-ASCII sale como `\uXXXX`. `JSONEncoder` emite UTF-8
   crudo.
2. Los `Double` enteros se escriben `1.0`; `JSONEncoder` escribe `1`.
3. Indent de 2, separador `": "`, contenedores vacíos inline, `\n` final.
4. El orden de claves es de inserción, no ordenado.
5. `created_at` trae **seis** dígitos fraccionarios. `ISO8601DateFormatter` maneja segundos enteros o
   exactamente tres; no puede ni emitir ni parsear seis. Se guarda como `String` opaco, igual que el
   dataclass de Python.

### Papelera real más journal, no cuarentena

**Descartado: mover a una carpeta de cuarentena, como hace el CLI.** Dos defectos concretos: no da
"Devolver" de Finder, porque un `shutil.move` a `~/.Trash/rav-duplicates` no es una operación de
papelera real; y el CLI no excluye `~/.Trash` del recorrido, así que correr `rav duplicate ~` dos veces
re-descubre todo lo que la primera corrida acaba de poner en cuarentena, y ofrece volver a ponerlo.

`FileManager.trashItem` da "Devolver" gratis. El journal — JSON Lines append-only, un registro por
archivo con ruta original, URL resultante, digest y mecanismo — da un deshacer por sesión dentro de la
app y un reporte honesto cuando un movimiento falla a la mitad.

**`.jsonl` y no `.json`** porque no se puede hacer append a un `[…]` pretty-printed sin reescribirlo, y
un crash a media escritura tiene que dejar legible todo lo anterior. La extensión es la señal honesta
de que no es el formato del CLI.

La cuarentena sobrevive como **fallback**, para cuando `trashItem` falla en un volumen de red o
read-only, journaleada idénticamente para que el deshacer funcione por cualquiera de los dos caminos.

### Verificar antes de actuar, no al escanear

Un digest corrupto pero con CRC válido, o un inode reusado dentro del mismo nanosegundo de mtime,
pondría dos archivos no idénticos en un grupo, y el usuario mandaría a la Papelera algo que no es
duplicado. "Improbabilísimo" es el estándar equivocado para una acción destructiva.

Así que: inmediatamente antes de mover, re-hashear el keeper y cada archivo a mover, y abortar la
acción completa si algún digest discrepa con el scan. Son lecturas solo de los archivos sobre los que
se actúa — trivial junto al scan — y convierte un bug de caché de "pérdida de datos" en "un mensaje de
error".

### Caché de hashes en `~/Library/Caches`, no en el estado compartido

Son dos clases de dato distintas. El JSON de scan es un formato de interop documentado que el CLI lee
y que nunca debe perderse. La caché es dato derivado reconstruible, y `~/Library/Caches` es el
directorio que macOS puede purgar bajo presión de disco — exactamente la semántica que se quiere.
Ponerla en el estado compartido contaminaría un directorio de interop con un formato binario privado y
lo volvería un pasivo de respaldo.

**Descartado: SQLite.** `libsqlite3.tbd` está en el SDK y `.linkedLibrary("sqlite3")` no descarga
nada, así que estaría *permitido* bajo "cero dependencias SPM" — es librería del sistema igual que
CryptoKit. Se rechazó por mérito: el workload es un lookup puntual sobre clave compuesta, sin range
queries y con un solo proceso escritor. SQL, índices, planner y WAL no compran nada, y traen un WAL
file, un shm file, semántica de `busy_timeout` y un loop de `sqlite3_step` en C — o sea más superficie
de corrupción, no menos. Un log append-only de registros fijos con CRC-32C tiene una historia de
corrupción que se dice en una oración: un registro parcial final se detecta por aritmética de tamaño,
uno corrupto por su CRC, y un magic que no coincide descarta el archivo entero. No existe estado en que
la caché pueda estar *equivocada* sin además fallar su CRC.

### Localización: Core no produce prosa

Con dos idiomas, una cadena en español dentro de Core es una cadena que no se puede traducir. Core
devuelve valores estructurados — `MediaAdvice.preferB(EfficiencyComparison)` — y el ejecutable arma la
frase. Efecto secundario deseable: los tests afirman sobre estructura en vez de sobre prosa, que es
más estable y más honesto.

**Descartado: declarar los `.lproj` como `resources:` de SwiftPM.** SwiftPM los entierra en un
`Duplicate_Duplicate.bundle` donde `Bundle.main` no los encuentra. El bundle de la app lo arma el
Makefile, así que la localización también.

### AppKit programático, no SwiftUI

Mismo criterio que el proyecto hermano: control explícito sobre el `NSTableView` de miles de filas y
sobre `QLPreviewPanel`, que en SwiftUI se envuelve igual pero con una capa de indirección más. También
significa que no hay `.xib` ni `.xcassets`, y que el menú principal se arma a mano — de ahí el modo de
selftest que verifica que no haya atajos colisionados, porque un menú hecho a mano las acumula en
silencio y no hay chequeo del compilador.

### Sin sandbox, y sin pedir Full Disk Access

**Descartado: sandboxear con bookmarks security-scoped del `NSOpenPanel`.** La elección en el panel
*es* la concesión, que es un modelo de consentimiento genuinamente mejor que los prompts de TCC. Pero
`~/.local/state/rav/` está fuera del contenedor, y el estado compartido con el CLI es el punto de la
app. Alcanzarlo pediría un entitlement `temporary-exception.files.home-relative-path`, frágil e
indocumentado, del tipo que se rompe en una actualización de OS. Ese requisito decide.

**Descartado también: pedir Full Disk Access.** No hay API para pedirlo, solo un toggle manual, así
que "pedirlo" significa molestar. Los duplicados dentro de `~/Library` son abrumadoramente cachés y
bases de datos gestionadas por apps, donde quitar un "duplicado" rompe una app. Y una app que pide
Acceso Total al Disco para ordenar Descargas es indistinguible de malware para un usuario cuidadoso.
`~/Library` se excluye por default, con un toggle avanzado apagado.

### La cifra de espacio recuperable cuenta almacenamiento, no archivos

Medido, y contraintuitivo: **copiar un archivo en APFS produce un clon.** `FileManager.copyItem` y
`cp` pasan por `clonefile`, así que un archivo duplicado en Finder comparte sus bytes con el original
y borrarlo no libera nada. Solo escribir los bytes de nuevo produce una segunda copia.

Por eso `DuplicateGroup` lleva una `StoragePartition` y expone dos números distintos:
`redundantByteCountUpperBound` (contando archivos, que es lo que haría un port ingenuo) y
`reclaimableBytes` (contando clases de almacenamiento). En el árbol de prueba con las cinco variantes
difieren 4×.

Fuera de APFS no hay `contentIdentifier`: los hardlinks se siguen detectando por inodo, los clones no,
y la cifra pasa a ser cota superior. `isExact` reporta cuál de los dos casos es, para que la UI lo
etiquete en vez de redondearlo a un número confiado.

Medición sobre el corpus real: de 6,414 grupos distintos, solo 12 conservan todos sus archivos en
disco (el corpus es de mayo y se limpió), y **esos 12 tienen almacenamiento independiente** — cero
clones. Tiene sentido para este corpus: los duplicados vienen de descargar lo mismo dos veces, no de
copiar local. Muestra chica, y se reporta como tal.

### Escrituras atómicas, y por qué es mejora gratis

`ScanStore` escribe con `Data.write(options: .atomic)`: archivo temporal más rename. El CLI usa
`Path.write_text` (`src/rav/core/duplicates.py:107`), que no lo es — un crash o un disco lleno a media
escritura deja un JSON truncado donde había un scan, y la siguiente lectura de ese scan falla. El
formato no cambia en un byte, así que es mejora estricta sin costo de interop.

Lo que un test puede afirmar de eso no es la atomicidad — no hay forma de matar el proceso a la mitad
desde `swift test` — sino que **no queda basura**: guardar dos veces deja exactamente un archivo en
`scans/`. Una escritura atómica que filtrara su archivo de staging seguiría siendo atómica y ensuciaría
el directorio compartido que el CLI lista.

Y un scan que no decodifica **se salta**, no aborta la lista. La biblioteca es la única entrada a los
datos de la app; fallar cerrada dejaría 118 scans buenos escondidos detrás de uno malo.

### La compuerta de aplicar: una simulación vigente, no una simulación cualquiera

El CLI también impone "aplicar solo después de simular", pero de forma implícita, en las ramas de su
loop de comandos (`src/rav/core/duplicate_flow.py:49-71`). Ahí la regla vive donde el loop resulte
estar correcto. En una ventana eso no alcanza: un botón gris es detalle de presentación, y un atajo de
teclado o una hoja que quedó abierta lo alcanzan igual.

`ReviewFlow` es un value type que Core posee y la UI *consulta*. Guarda la huella del plan que se
simuló, y `ApplyGate.authorize` la compara contra el plan que pide correr. Las tres formas de rodear la
regla quedan cerradas: aplicar sin ninguna simulación, aplicar después de editar una decisión, y
aplicar un plan distinto del que se mostró. `make selftest MODE=gate` afirma las tres.

**La huella es de contenido**, sobre las claves de grupo y las rutas que se removerían, ordenadas: dos
planes que tocarían exactamente los mismos archivos coinciden, y cualquier otro no. No usa el `Hasher`
de Swift porque está sembrado por proceso y una revisión reabierta después de un relanzamiento tiene
que reconocer su propia huella. FNV-1a a mano, 20 líneas — esto compara un plan contra sí mismo minutos
después, no contra un adversario, así que SHA-256 sería ceremonia.

Y `hasDecisions` **sí se lee**, a diferencia del CLI, que lo recibe como parámetro en `menu_options` y
nunca lo consulta: su "ver decisiones" se ofrece incluso cuando no hay nada que mostrar.

## Testing

### Lo que no se puede probar con `swift test`, y se dice

- Si el Makefile sustituyó los placeholders del `Info.plist` — no hay bundle bajo `swift test`.
- Si los `.lproj` aterrizaron donde `Bundle.main` los busca.
- Si el menú principal tiene atajos colisionados.
- Que devolver `false` en el `errorHandler` de `FileManager.enumerator` detenga la enumeración.
  Foundation lo documenta; medido en este SDK, **no pasa**. La afirmación estaba en el plan como
  hecho y era falsa. Lo que el handler sí compra es poder reportar el hueco: sin él, la lista de
  archivos es idéntica y la app no puede decir que no vio nada.
- El estado real de TCC de la app. **Un selftest verde no dice nada sobre eso**: lanzada desde la
  terminal, macOS atribuye el acceso a la terminal y la app hereda sus permisos; lanzada por Launch
  Services la app es su propio proceso responsable. Los dos hechos son verdad y ninguno implica el
  otro.

Para lo primero existe `make selftest`, con dos reglas: tiene que **afirmar**, y tiene que **probarse
fallando contra la versión rota**. Lo segundo no es ceremonia — en el proyecto anterior un arnés pasaba
contra código conocidamente roto porque llamaba un método de Swift directo en vez de despachar por el
existencial del protocolo, y el defecto vivía en el thunk `@objc`.

Reversiones verificadas para este scaffolding:

| Rotura | Modo que falla |
|---|---|
| borrar una línea de `es.lproj/Localizable.strings` | `l10n`, nombrando la clave |
| tratar `XDG_STATE_HOME` vacío como puesto | `state-dir`, reportando que resolvió a `/rav` |
| quitar una sustitución `sed` del Makefile | `bundle`, nombrando el placeholder |
| dar el mismo atajo a dos ítems de menú | `menu`, nombrando los dos títulos |
| cambiar el indent del JSON de 2 a 4 | `json-roundtrip`, en los 226 documentos, "differs at byte 4" |
| renombrar la clave `sha256` a `digest` en el codec | `scans`, "differs at byte 191" |
| poner `created_at` antes de `root` al codificar | `scans`, "differs at byte 44" |
| caer al preview para los grupos sin decidir | `review`, "an untouched review already had 50 decisions" |
| que `skip` reescriba el keep set al índice 0 | `review`, "a skip added a decision: 2" |
| quitar el guard de `fileExists` en `UndoRunner` | el test `refusesLateOccupant`; el archivo nuevo del usuario desaparece |
| reescribir la línea del journal en vez de agregar `undone_at` | el test `restorationIsAppended` |
| ignorar `resultingItemURL` y devolver la ruta original | `trash`, "nothing at the reported destination" |
| sacar la verificación de contenido | `trash`, "a file whose digest did not match was still moved" |
| sobrescribir en vez de renombrar en la cuarentena | `trash`, la colisión resuelve al nombre ocupado |
| agrupar por ruta en vez de por `contentIdentifier` | `storage`, "expected 2 distinct copies, got 5" |
| volver a `files[1:]` en `removalCandidates` | `storage`, el set de remoción incluye el clon del keeper |
| reconstruir el `FileEntry` en vez de usar `withSize` | `cache`, el pase caliente vuelve a leer todo |
| corromper un byte de un registro de caché | el test de CRC: una fila cae, el resto sobrevive |
| quitar la sustitución `__BUILD_NUMBER__` del Makefile | `about`, nombrando el placeholder |
| no copiar el `.icns` al bundle | `icon`, "is missing from the bundle's Resources" |
| perder el `%@` al traducir `about.builtOn` | `about`, "does not contain the date" |
| dejar de hashear el último chunk parcial | `digest` en el tamaño 1; 14 de los tests de frontera |

### Por qué los fixtures de JSON son sintéticos

Los fixtures en `Tests/DuplicateCoreTests/Fixtures/` los genera
`scripts/make-json-fixtures.py` con el mismo `json.dumps(obj, indent=2) + "\n"` que usa
`save_scan` del CLI, así que son bytes que un Python real escribió — esa procedencia es el punto.

Pero el contenido es sintético a propósito: el directorio de estado real del usuario tiene rutas
privadas, y un fixture commiteado es un archivo publicado. La compatibilidad byte a byte es una
propiedad del *formato*, así que rutas sintéticas que ejerciten cada regla de escape la prueban igual
de bien. El corpus real se cubre en runtime, con `make selftest MODE=json-roundtrip`, que es de solo
lectura.

### Un parser propio, además del escritor

**Descartado: usar `JSONSerialization` para leer.** Devuelve un `NSDictionary` sin orden y colapsa `1`
y `1.0` en el mismo `NSNumber`, así que un re-encode nunca podría ser byte-idéntico — y entonces la
prueba de compatibilidad contra archivos reales no existiría. `JSONReader` preserva el orden de claves
y la distinción entero/flotante, que es exactamente lo que `json.loads` preserva.

Es más estricto que Python en un punto, a propósito: rechaza los literales `NaN` e `Infinity`, que
`json.loads` acepta. Una similitud no finita en un archivo de scan es un bug para sacar a la
superficie, no un valor para arrastrar.

## CI y su costo

Los runners de macOS facturan **10×**, así que los 2,000 minutos del plan gratuito son en realidad
~200 minutos de reloj. Por eso CI corre **solo en pull requests**, nunca en push.

Cubre las bases apiladas (`main`, `feat/**`, `fix/**`) y el tipo de evento `edited`: con
`branches: [main]` solo, un PR basado en otra rama de feature no reporta ningún check, y re-apuntarlo a
`main` después dispara un `edited` que no está entre los tipos por default. En el proyecto anterior eso
dejó llegar a `main` una rama apilada que nunca se probó.

El runner está pineado a `macos-15`, el deployment target, no a `macos-latest`. Es lo que atrapa código
que alcanza una API más nueva de la declarada — y es lo que atrapa la divergencia de anotaciones
`Sendable` entre SDKs, que no se puede reproducir localmente cuando solo está instalado el SDK nuevo.

Pasos: `make lint`, `make build CONFIG=debug`, `make coverage`. Debug y no release porque `swift test`
compila debug igual y reusa los artefactos. El build explícito es necesario aparte porque `swift test`
**no** compila el target ejecutable, así que un `AppDelegate` roto pasaría inadvertido.

El nombre del job es el status check requerido en el ruleset de `main`. **Renombrarlo deja de proteger
`main` en silencio**, porque el ruleset espera un contexto que ya no reporta.
