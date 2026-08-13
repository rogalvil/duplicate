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

### La biblioteca se mantiene al día sola, y el watch tiene un hueco conocido

La ventana lista todo escaneo bajo el estado compartido, sin importar qué herramienta lo escribió, y
se actualiza mientras está abierta: un `rav duplicate scan` que termina en una terminal aparece sin
que nadie pida nada. Eso es el punto de compartir el formato — si hubiera que apretar Actualizar, las
dos herramientas serían dos programas y no uno visto de dos maneras.

Se hace con `DispatchSource.makeFileSystemObjectSource` sobre `scans/` y `decisions/`, no con un poll:
un sondeo de un segundo sobre un directorio que nadie está mirando es un despertar por segundo para
siempre, y uno de diez segundos hace que la app se sienta rota junto a la terminal que acaba de
imprimir el `scan_id`.

Lo medido, que decidió la forma del tipo:

| acción sobre el directorio | evento |
|---|---|
| se crea o se borra una entrada | `.write` |
| cambia el **contenido** de un archivo existente | **nada** |
| escritura con `.atomic` (temporal + rename) | `.write` dos veces |
| se borra el directorio vigilado | `.write` y luego `.delete`, y la fuente sigue viva |

La segunda fila es el hueco, y se documenta en vez de descubrirse: el `write_text` del CLI sobre un
documento que ya existe no dispara nada. Para esta ventana alcanza, porque cada fila depende de que el
archivo *exista* y no de lo que diga adentro. Una vista que mostrara conteos de decisiones no.

La tercera es la razón del debounce de 150 ms: **una sola escritura son dos eventos**.

La cuarta es la razón de reabrir por ruta en vez de confiar en que la fuente se detenga. Un descriptor
a un directorio borrado se queda abierto y callado, así que sin eso la app se vería sana y no volvería
a actualizarse nunca.

Y hay un test que **afirma el hueco** — reescribir en sitio no dispara nada — para que sea un hecho
verificado y no una frase en un comentario que puede dejar de ser cierta en silencio.

### La ventana se prueba a través de su propio camino de dibujo

`swift test` no puede importar el ejecutable, así que la tabla se verifica en `--selftest --mode
library`: se construye el `LibraryWindowController` de verdad contra un directorio de estado en `/tmp`
y se lee de vuelta llamando al mismo `tableView(_:viewFor:row:)` con el que la ventana dibuja. Leerlo
de una segunda copia de las reglas de formato pasaría mientras la ventana muestra otra cosa.

Incluye la afirmación que importa: se guarda un escaneo desde fuera y la fila aparece en la tabla sin
que nadie la pida. Ese es el comportamiento que justifica la ventana entera.

### La revisión: tres honestidades y un teclado

La ventana de revisión existe para que tres cosas sean imposibles de hacer mal, cada una una forma de
perder la confianza del usuario para siempre:

1. **Un grupo que nadie vio no es una decisión.** La marca del heurístico se muestra atenuada como
   *preview*, con una advertencia que lo dice, y cerrar la ventana no registra nada para ese grupo. El
   CLI escribe una decisión para cada grupo incluido el que nadie abrió — salir tras el grupo 1 de 50
   registra 49. En una terminal eso pide un `q` deliberado; en una ventana, salir es cerrar la ventana.
2. **Un archivo que comparte almacenamiento con el que se conserva no se ofrece.** Su casilla está
   deshabilitada y su nota dice por qué. Mandarlo a la Papelera liberaría cero, y a una herramienta
   cachada exagerando espacio recuperado no se le cree nada más.
3. **Conservar nada se rehúsa, no se trata como salida.** La TUI del CLI lee esa condición como "ya
   terminamos" y sale de la revisión, así que Enter con nada marcado pierde la sesión.

Las vistas-modelo viven en Core (`GroupPresentation`, `PathElision`) para que las reglas estén
cubiertas por tests y no por mirar la pantalla. Core produce números, banderas y rutas; la ventana
convierte `sharesStorageWithKeeper` en una frase, en el idioma que esté corriendo.

**El izado del padre común se compara por componentes, no por bytes.** `/a/bc/x` y `/a/bd/y` comparten
el prefijo de bytes `/a/b`, que no es una carpeta en la que esté ninguno de los dos: izarlo al
encabezado pondría en pantalla una ruta que no existe. La respuesta es `/a`. Y la elisión se come el
*medio*, no el final — la cola de una ruta es lo que la identifica.

**Espacio y Return no son atajos de menú.** Un `keyEquivalent` es global y dispararía mientras el
usuario escribe en el campo de búsqueda de la biblioteca. Viven en `ReviewTableView.keyDown`, donde solo
significan algo porque una lista de archivos tiene el foco. Lo demás sí va al menú Grupo, que es lo que
le da descubribilidad, traducción y el chequeo de colisiones de atajos.

**⌘Z es deshacer de revisión y nunca de aplicación.** Deshacer una casilla y deshacer cuatro mil
archivos mandados a la Papelera no son el mismo acto, y toda otra app de macOS le enseñó al usuario que
⌘Z significa "lo que acabo de escribir". El deshacer de sesión vivirá en su propio menú, sin
equivalente de teclado.

### La vista previa, y la razón por la que la app existe

En una terminal se decide entre dos rutas leyendo dos rutas. Aquí se mira la cosa. Eso es lo que el CLI
no puede hacer y es la mitad del argumento para escribir la app.

**El reparto sigue la regla del bootstrap.** `QLThumbnailGenerator` es XPC a `quicklookd`: puede ser
lento, puede fallar, puede colgarse, y su salida es lo que decidió dibujar una extensión de terceros. No
hay nada determinista que afirmar, así que la llamada vive en el ejecutable. Lo que sí es afirmable vive
en Core: qué identifica un thumbnail (`ThumbnailKey`), de qué tamaño pedirlo (`ThumbnailPolicy`) y qué
conservar (`LRUCache`).

**La clave es el digest, no la ruta.** Los archivos de un grupo tienen contenido idéntico por
construcción, así que ocho fotos necesitan un thumbnail. Keyear por ruta manda ocho viajes de XPC y
guarda ocho copias del mismo bitmap para un grupo que el usuario mira una vez.

**La extensión también va en la clave**, y eso no es precaución: el header de
`QLThumbnailGenerator.Request` dice que el content type *"is derived from the file extension"*, y el
content type elige el proveedor del thumbnail. Los mismos bytes llamados `a.pdf` y `a.dat` se dibujan
distinto con toda razón. Raro en un grupo de duplicados; gratis hacerlo bien.

**El plazo de 2 segundos es la parte que sostiene todo.** Una ventana que deja de responder porque una
extensión de thumbnails de algún formato se trabó es peor que una que muestra un icono genérico. Cada
petición corre contra un plazo; perder la carrera cancela la petición y cae al icono del archivo, que
`NSWorkspace` saca de la base local y no puede colgarse. El icono se guarda bajo la misma clave: un
archivo cuyo thumbnail no se puede hacer no va a empezar a funcionar en la siguiente selección, y volver
a preguntar cuesta otros dos segundos de espera.

### Lo que el panel dice cuando el archivo ya no está

**El corpus hizo esto necesario, no bonito.** Los escaneos más viejos de esta máquina son de mayo, y de
las 501 rutas de uno de ellos **473 ya no existen**. Un panel que dibujara un blanco para esas le estaría
pidiendo al usuario decidir sobre archivos ya borrados. Y peor: un escaneo cuyo archivo *cambió* es un
grupo que ya no es verdad, así que decidir quitar un "duplicado" de él quitaría algo que no es duplicado.

`FilePresence` distingue cinco estados —presente, ausente, tamaño cambiado, ilegible, ya no es archivo—
y `GroupPresence` agrega dos preguntas que la ventana necesita: si el grupo **sigue siendo** un duplicado
(hacen falta **dos** sobrevivientes: con uno no hay nada que quitar ni que conservar, y ofrecerlo
invitaría a borrar la única copia) y si está vencido.

El chequeo va fuera del hilo principal, con guardia de generación, por la misma razón que la biblioteca:
un `stat` sobre un disco externo que se durmió tarda segundos en la primera respuesta.

**`attributesOfItem` no sigue symlinks** — medido, y lo contrario es la suposición fácil. Aquí es el
comportamiento correcto: un symlink nunca es miembro de un escaneo porque `WalkFilter` los rechaza, así
que uno parado en una ruta registrada significa que el archivo fue reemplazado. Llamar a eso "presente"
sería activamente falso, porque `trashItem` sobre un symlink manda el enlace y deja los bytes donde
están.

### Escanear desde la app, y las dos cosas que eso obliga

`ScanSession` es la costura que faltaba. `DuplicateFinder` produce un escaneo y `ScanStore` escribe uno,
pero decidir **cuál** identificador, **cuáles** exclusiones, **si** usar la caché compartida y **cuándo**
el documento llega a disco son decisiones con consecuencias, y estaban repartidas entre un test y un
selftest en vez de vivir en algún lado.

En Core porque todas son valores, y porque la ventana no puede ser el lugar que las sabe: un escaneo
lanzado desde una ventana y uno lanzado desde una futura línea de comandos tienen que producir el mismo
documento.

**Guardar es lo último que pasa, y una falla al guardar se reporta en vez de lanzarse.** Un escaneo de
800,000 archivos que terminó bien no se puede tirar porque el directorio de estado estaba de solo
lectura: quien llama todavía puede revisarlo en memoria y el reporte dice que no está en disco. Lanzar
convertiría un problema recuperable en veinte minutos perdidos.

**Un escaneo cancelado no escribe nada**, porque el save va después de que el finder regresa — y el
finder revisa la cancelación en cuatro puntos. Los appends de la caché de hashes **sí se conservan**, a
propósito: son hechos verdaderos, y tirarlos haría pagar el precio completo en el siguiente intento.

**El `Date` entra y el instante se resuelve adentro.** Una versión anterior daba un identificador por un
método y tomaba un instante por otro, lo que dejaba deduplicar uno y guardar bajo el otro: el
identificador decide el nombre del archivo, el instante decide lo que va estampado adentro, y tienen que
salir del mismo valor.

### El progreso se jala, no se empuja

Los hooks del CLI disparan una vez por archivo. A 800,000 archivos, un update empujado serían 800,000
saltos de actor para redibujar una etiqueta que nadie puede leer más de diez veces por segundo.

El escáner cuenta con atómicos y la ventana lee un `snapshot()` en un `Timer` a **10 Hz**. Diez lecturas
por segundo en vez de 800,000 empujones. El timer se agrega en modo `.common`, porque sin eso un escaneo
que termina con un menú abierto deja de actualizarse.

Dígitos monoespaciados en los contadores: un numeral proporcional actualizándose diez veces por segundo
salta de lado.

### El límite de descriptores, y por qué el arnés lo baja él mismo

**Launch Services arranca una app con `RLIMIT_NOFILE` blando en 256.** Un escaneo tiene un descriptor por
hash concurrente más el del recorrido, y junto a la caché de hashes, la conexión XPC de Quick Look y lo
que Foundation guarde, 256 no es un margen cómodo. Quedarse sin descriptores **no truena**: sale como
archivo ilegible, se cuenta como candidato saltado, y el escaneo encuentra menos de lo que debía.

Y ahí está la trampa del arnés: **desde una terminal el límite blando ya viene en millones** —medido,
1048576— así que un modo que solo mirara el valor actual pasaría exista o no el `setrlimit`. El modo
`fdlimit` baja el límite a 256 él mismo, llama a la misma función que llama el arranque, y verifica que
volvió a subir. Bajar siempre se puede; subir está acotado por el límite duro, que no se toca.

### Lo medido en el corpus real, y lo que dice del diseño

Cuatro escaneos completos por el motor de la app, de solo lectura, con el binario corriendo directo
(sin el costo de `make`):

| Corpus | Archivos | Bytes | Frío | Caliente | Grupos | Recuperable |
|---|---|---|---|---|---|---|
| `~/me/code` (SSD interno) | 10,506 | 664 MB | **0.11 s** | — | 6 | 6.1 KB |
| `_____check` (USB externo) | 1,138 | 2 GB | **0.93 s** | — | 11 | 6.3 MB |
| `JulianaPalvin` (USB externo) | 696 | 245 GB | **0.61 s** | — | 0 | 0 |
| `OF` (USB externo) | 15,242 | 806 GB | **130.2 s** | **7.1 s** (18.3×) | 12 | 3.1 GB |

**La fila de 245 GB es la que explica el diseño.** Tardó 0.61 s porque ningún par de archivos comparte
tamaño, así que el bucketing los elimina todos y **no se leyó un solo byte de contenido**. El mismo
efecto en `~/me/code`: 10,506 archivos, 244 candidatos.

**La fila de 806 GB es el caso donde sí hay trabajo**, y es donde la caché de hashes se paga: 986
candidatos, 130.2 s en frío contra 7.1 s en caliente, **18.3×**. (Una medición anterior sobre otro
directorio dio 33.5×; el factor depende de cuántos candidatos haya y de qué tan grandes sean, así que
citar uno solo sería citar el que conviene.)

**Una conclusión falsa que casi publiqué**: corrí el mismo directorio dos veces por el modo `storage` y
el segundo pase dio 128.6 s contra 131.8 s, o sea "la caché no sirve". No era eso: `storage --dir` corre
con la `Configuration` por default, que trae `cache: nil`, así que **las dos corridas fueron frías**. El
modo `cache` es el único que la enciende. La lección es del arnés, no del código: un modo que no dice
qué configuración usa invita a leer su número como si midiera otra cosa.

### Aplicar: lo que se muestra es lo que se mueve

`ApplyRunner` camina un plan, un archivo a la vez. **Serial a propósito**: el cuello es metadata de
filesystem, la concurrencia no compra nada, y volvería no determinista el orden del journal — que es el
orden que un deshacer reproduce.

**La primera falla no detiene la corrida.** Un archivo bloqueado por otro proceso no puede abortar los
otros 3,997. **Pero veinte fallas seguidas sí la detienen**: un problema global —un permiso revocado, un
volumen que se fue— no debe producir cuatro mil filas idénticas que leer.

**El journal se escribe en lotes de 32, no al final.** Un crash a media corrida tiene que dejar un
journal que describa lo que ya se movió, o esos archivos no se pueden devolver desde la app. El lote
mantiene eso cierto costando una escritura por 32 archivos en vez de una por archivo.

**Cada archivo se vuelve a hashear justo antes de moverse.** Un digest rancio —porque el archivo cambió
después del escaneo— tiene que impedir que ese archivo se mueva, no descubrirse después. Y una ruta que
nadie avaló se rehúsa en vez de permitirse: disponer de algo ausente del plan es exactamente el error que
`VerifyingDisposer` existe para evitar.

**La hoja lista todas las rutas, no una muestra.** La confirmación de una acción destructiva que dice "y
3,997 más" está pidiendo consentimiento sobre algo que el usuario no puede ver.

**La compuerta se revisa en el handler, no se confía del estado del botón.** Un control deshabilitado que
un atajo de teclado todavía alcanza no es una regla. Y la huella se calcula una vez y sirve para los dos
pasos, así que lo que el usuario vio y lo que `ApplyGate` autoriza son el mismo plan por construcción y
no por coincidencia.

### Deshacer, y por qué no es ⌘Z

Deshacer una casilla y deshacer cuatro mil archivos mandados a la Papelera no son el mismo acto. Toda
otra app de macOS le enseñó al usuario que ⌘Z significa "lo que acabo de escribir", así que alguien
apretando ⌘Z para destildar una casilla y moviendo 4,000 archivos de vuelta sería una catástrofe.

Por eso el deshacer de sesión vive en un menú `Sesiones` **sin equivalente de teclado**, y ⌘Z se queda en
el `NSUndoManager` de la revisión.

**Nunca se sobrescribe una ruta original ocupada.** Contenido byte-idéntico cuenta como *ya restaurado*
—pudo haberlo devuelto Finder, que la app no puede ver— y cualquier otra cosa se bloquea. El runner
**vuelve a chequear** justo antes de mover, porque el plan pudo mostrarse al usuario minutos antes.

**Una Papelera vaciada da un plan que no puede hacer nada, y entonces no se muestra un plan**: una línea
que lo dice. Nunca un botón Restaurar que no va a hacer nada.

Y `applicationShouldTerminate` devuelve `.terminateLater` mientras un apply corre: salir a medias dejaría
archivos medio movidos y un journal que se corta.

### Bookmarks security-scoped: rechazados, y por qué

El plan pedía bookmarks security-scoped para que una carpeta elegida sobreviviera a un relanzamiento. Se
rechazaron después de mirar para qué existen.

`.withSecurityScope` existe para que una app **en sandbox** vuelva a alcanzar una carpeta que el usuario
eligió en un panel, porque el sandbox lo olvida. Esta app **no está en sandbox** —verificado: no hay
entitlement `com.apple.security.app-sandbox` en la firma— porque el estado compartido vive fuera de un
contenedor y ese requisito lo decidió.

Lo que gobierna el acceso aquí es TCC, que recuerda por **app**, con la llave del designated requirement,
no por selección de carpeta. Un bookmark no compraría nada que TCC no dé ya, y escribirlo sería ceremonia
con aspecto de seguridad.

Lo que sí faltaba era mucho más chico: el panel olvidaba dónde escaneaste, así que cada escaneo empezaba
navegando otra vez. Eso es `RecentRootsStore` — diez rutas, la más reciente primero, comparadas por bytes
como todo lo demás, en `Application Support` y no en `Caches` porque una lista de carpetas que el usuario
eligió no es dato derivado que se pueda reconstruir.

### Lo que las capturas de pantalla enseñaron

Tres capturas de uso real destaparon cosas que ningún test veía, porque ninguna es incorrecta — solo
ilegible:

- **Las etiquetas del escaneo eran comentarios de documentación.** "Incluir archivos ocultos (el CLI lo
  hace; una carpeta de .DS_Store idénticos entierra los hallazgos reales)" es un párrafo, y se cortaba
  contra el borde de la ventana. Título corto, razón debajo en gris.
- **La barra lateral de grupos cortaba en "Grupo 864 - 41.1 KB - 2 ar…".** Tres datos en 210 puntos no
  caben; en dos líneas sí.
- **El encabezado de la columna decía "Cons…"** — una columna que no puede mostrar su propio nombre no la
  interpreta nadie.
- **El naranja se gastaba en el caso común.** El aviso de "todavía no hay nada decidido" sale en cada grupo
  sin abrir, así que colorearlo como peligro deja al naranja sin significado para cuando de verdad hay uno.
- **El total del pie era una mentira reconfortante.** Sumaba los bytes recuperables de escaneos que se
  solapan —veinte de la misma carpeta en una tarde— y salía "hasta 422.5 GB recuperables" sobre un corpus
  donde una muestra de doce escaneos encontró el 0.67% de sus rutas todavía en disco. Ahora el pie cuenta
  escaneos y ya; las cifras por escaneo siguen, y esas sí son honestas sobre sus propias cotas.
- **No había forma de borrar un escaneo**, y la biblioteca tenía 119 de cuatro días de mayo.

### 880 grupos, y la línea que no se cruza

El escaneo real de este usuario tiene **880 grupos**, y revisarlos de uno en uno no lo hace nadie. La
salida obvia —un botón que acepta la sugerencia en todos— es exactamente el defecto del CLI, el que hizo
que esta app tenga tri-estado: ahí cada grupo recibe una decisión como efecto secundario de salir, sin
preguntar y sin mostrar nada.

La observación que resuelve el problema es que **la mayoría de esos 880 no merece una decisión**. En ese
escaneo los grupos van de 20.5 MB a 346 B, y la cola es donde vive el conteo: decidir los veinte más
grandes recupera casi todo el espacio, y el resto puede quedarse sin decidir para siempre sin costar nada.

Así que hay dos piezas, y las dos son de Core:

- **`GroupFilter`** estrecha la lista por tamaño y por estado de decisión. **Estrechar no decide nada**:
  los grupos que desaparecen quedan exactamente como estaban, sin decidir, sin escribir, sin accionar.
  Los tamaños que ofrece son números redondos que una persona reconoce —"1 MB o más"— y no percentiles:
  "el 12% más grande" no es una decisión que alguien pueda tomar sobre su propio disco.
- **`confirmAll`** acepta lo que está en pantalla para los grupos seleccionados. Para uno que nadie abrió,
  eso es la sugerencia del heurístico.

**La diferencia con el CLI no es el resultado para un grupo, es que esto es un acto.** El usuario
selecciona un conjunto, ve cuántos son y cuántos bytes representan, y una hoja se lo dice antes. El ítem
de menú **no tiene atajo de teclado**: un atajo para esto sería un atajo para "decidir 800 cosas".

Y `confirmAll` no mueve el cursor, a diferencia de `confirm()`: avanzar 800 veces dejaría al usuario en un
grupo que nadie pidió ver.

### El filtro que más sirve para un escaneo viejo, y por qué se pide

De las tres formas de estrechar la lista, la que más cambia lo que ves en este corpus es **cuáles todavía
existen**: una muestra de doce escaneos de mayo encontró **73 de 10,934 rutas todavía en disco, 0.67%**.
Sin eso, revisar uno de esos escaneos son cientos de filas sobre archivos ya borrados.

Y es la única que **no puede correr sola**: es un `stat` por archivo — 2,259 para uno de esos escaneos,
9,949 para otro, sobre un disco externo que pudo haberse dormido. Así que es un botón, corre fuera del
hilo principal, reporta progreso a 10 Hz y se puede cancelar. Cancelarla **tira** lo que aprendió en vez
de aplicarlo a medias: un mapa parcial escondería grupos a los que simplemente nunca llegó.

Hasta que alguien lo pida, la casilla está deshabilitada y ningún grupo se esconde. **No revisado y
ausente son cosas distintas**, y esconder por la primera perdería grupos en silencio.

### Carpetas: el rediseño con prueba, y su peor caso honesto

El CLI arma un diccionario `{ruta relativa → digest}` para **cada** directorio y compara los `D²` pares
(`folder_duplicates.py:144-169`). Eso hashea cada archivo una vez por directorio ancestro —un archivo a
ocho niveles se hashea ocho veces— y guarda `Θ(N·d)` cadenas.

**La reformulación que lo colapsa a una pasada.** Un elemento de `FP(a) ∩ FP(b)` es un par de archivos con
digest igual *y* ruta relativa igual. Una ruta relativa siempre termina en el nombre del archivo, así que
**rutas relativas iguales fuerzan basenames iguales**. Por lo tanto solo pares de archivos que comparten
digest *y* basename pueden aportar algo a cualquier par de directorios.

**Y el conteo es exacto, no una cota.** Para dos archivos de esa clase, sea `K` la cantidad de componentes
del sufijo común más largo de sus rutas. El par aporta exactamente 1 a `matching(a, b)` para exactamente
los `K` pares de ancestros a profundidades 1…K, y para ningún otro.

> **Prueba de completitud.** Si `Dice(a,b) ≥ t > 0` entonces `matching(a,b) ≥ 1`, así que existen
> `fa ∈ subtree(a)`, `fb ∈ subtree(b)` con digests y rutas relativas iguales. Rutas relativas iguales
> implican basenames iguales, así que el par vive en alguna clase `(digest, basename)` de tamaño ≥ 2 y se
> enumera. Rutas relativas iguales de `k` componentes implican que el sufijo común es de al menos `k`, o
> sea `k ≤ K`, y el loop interno alcanza `(a, b)` en su paso `k`. Ningún par por encima de un umbral
> positivo se pierde. ∎

**La poda por tamaño, con su derivación.** De `Dice = 2M/(|A|+|B|) ≥ t` y `M ≤ min(|A|,|B|)` sale
`|B|/|A| ≤ (2−t)/t`. A `t = 0.9` eso es **1.2222**: cualquier par cuyos conteos de archivos difieran más
del 22% se descarta con un test entero. La derivación es lo que hace sano el descarte — y hay un test que
recorre todos los pares de conteos hasta 40 comprobando que **la cota nunca descarta un par que sí podría
alcanzar el umbral**.

**Dos propiedades del árbol cargan el resto.** Los intervalos de Euler vuelven la pregunta de ancestría una
comparación entera, en vez del `relative_to` dentro de un `try/except` que el CLI hace por par. Y el orden
depth-first hace que los archivos de cualquier subárbol sean un **rango contiguo**, que es lo que permite
comparar un sobreviviente leyendo dos slices en vez de armar dos diccionarios.

**El peor caso, dicho en voz alta.** Una clase `(digest, basename)` grande es cuadrática en su propio
tamaño: diez mil `__init__.py` idénticos dan cincuenta millones de pares. Hay un tope de 512 por clase, y
cuando se aplica **el resultado lo reporta con el nombre de la clase que se truncó**, en vez de devolver
respuestas silenciosamente incompletas.

**Y una divergencia deliberada:** los empates de similitud se ordenan por bytes de las dos rutas. El CLI los
deja en orden de `os.walk`, que no es reproducible entre máquinas; la alternativa a un orden determinista es
un archivo que cambia entre corridas.

**Dentro de un par, la orientación también se normaliza por bytes, y eso no es cosmético.**
`rav duplicate folders-move` conserva `folder_a` y manda `folder_b` a cuarentena, así que en un documento
compartido cuál ruta va en cuál campo decide cuál carpeta se destruye. Tomarla de los índices del árbol la
tomaba del orden de enumeración del recorrido, que nada promete reproducir en otra máquina ni después de
mover un archivo. Ninguna de las dos es semánticamente la sobreviviente —la del CLI es orden de `os.walk`—
pero arbitraria y reproducible le gana a arbitraria y dependiente del enumerador cuando un comando borra uno
de los dos lados. Medido contra el CLI sobre un árbol real: **el mismo conjunto de 42 pares, y los 42 al
revés** antes del arreglo. Lo destapa una carpeta cuyo nombre es prefijo del de su hermana, que sesenta
árboles aleatorios del test diferencial nunca produjeron.

### El hash perceptual: cuatro etapas y una propiedad numérica que decide todo

El pipeline es grises → Lanczos-3 a 32×32 → DCT-II 2D → recortar 8×8 → umbralar contra la mediana de esos 64.
Cada etapa está anclada a una medición contra la referencia (`imagehash` sobre Pillow 12.2.0), no a lo que
parecía razonable.

**La conversión a grises: Pillow redondea.** El plan decía que truncaba. Medido sobre diez triples,
`(19595·R + 38470·G + 7471·B + 0x8000) >> 16` acierta los diez y la forma truncada falla tres —
`(0,255,0)` da 149 contra los 150 de Pillow. Un tercio de los píxeles de una foto real corrido en uno mueve
coeficientes del DCT y puede voltear un bit.

**El DCT tiene que cancelar exacto, y eso decidió la implementación.** Una imagen plana transforma a un solo
coeficiente y 63 ceros; la mediana es cero y solo el bit del DC prende. Pero esos ceros son cero **únicamente
si la aritmética cancela exactamente**:

| transformada de una constante | max&#124;AC&#124; en el bloque 8×8 |
|---|---|
| `vDSP.DCT`, `Float` | **0.0, exacto** |
| matriz de la base vía `vDSP_mmul`, `Float` | ~1e-3, de signo mezclado |
| `scipy.fftpack.dct`, `Float64` | **0.0, exacto** |

Y una mediana tomada sobre 63 valores diminutos de signo mezclado **es** uno de ellos, así que la mitad quedan
arriba: una perturbación de 1e-3 prende **32 bits en vez de 1**, verificado en Python metiéndole ese ruido a
una constante. La precisión no es lo que lo arregla — las mariposas de una FFT restan valores iguales y dan
ceros exactos; una suma de 32 cosenos que matemáticamente cancela, no, a ninguna precisión. Así que la forma
matricial es la definición más clara y la implementación equivocada, y vive en los tests como el oráculo que sí
es bueno siendo.

Eso importa mucho más allá de un fixture plano: **una barra de letterbox, un fondo sólido, un frame negro.**
El camino de video se apoya en que frames idénticos den hashes idénticos.

**Por eso también se cuantiza a `UInt8` después del resample.** El ringing de Lanczos y los pesos en `Float`
dejan una región plana en `255 ± 1e-3` en vez de exactamente 255, y ahí vuelve el volado de los 32 bits.
Redondear después del resample lo cierra. **Cuantizar también *entre* las dos pasadas —lo que hace Pillow— se
midió y empeora**: 89.97% de coincidencia exacta contra 90.88%. El instinto del plan de rechazarlo era
correcto, y ahora tiene número en vez de estética.

**El tamaño de decode se barrió sobre 2,763 fotos reales**, y el barrido mata dos suposiciones: pedirle a
ImageIO un thumbnail de 32 px es un desastre (10.9% de coincidencia, 2.5% menos pares encontrados), y la
respuesta de este pipeline **deja de moverse en 128** — 4,329 / 4,332 / 4,328 / 4,331 pares de 128 a 4096, un
rango de 0.1%. Pasado 256, el decode extra compra coincidencia con Python, no mejores respuestas. La tabla
completa está en el doc comment de `ImageHasher`.

**Qué tan cerca queda, medido:** 90.4% idéntico bit a bit sobre 2,779 fotos, 99.2% dentro de dos bits. Las 16
que quedaron a más de cinco bits son **las 16 únicas del corpus con etiqueta de rotación EXIF** — la
divergencia elegida a propósito, porque una copia que solo difiere en un flag de rotación debería coincidir con
su original y el `phash` de Pillow diría que no. Sin ellas, el peor caso sobre 2,763 imágenes es de **4 bits**.

**Y el criterio de aceptación del plan no se cumple:** pedía Jaccard ≥ 0.98 del conjunto de pares a distancia
≤5, y a 256 sale **0.9670**. Solo el decode completo llega (0.9879), a 2.65× el tiempo. Lo que sí se cumple es
el criterio duro: **cero pares** que una herramienta llame ≤2 y la otra >5.

**Lo que un pHash no puede distinguir**, y conviene saberlo antes de reportarlo como bug: solo mira las ocho
frecuencias espaciales más bajas. Un tablero de ajedrez de 8 px en una imagen de 128 tiene toda su energía
fuera de ese bloque, así que el hash ve un gris plano y responde lo mismo que para un gris plano. `imagehash`
responde igual. Hay un test que lo fija con su razón.

### El índice LSH: una cota de palomar, y el colapso que importa más

El CLI compara todos los pares: dos loops anidados sobre cada par de archivos
(`perceptual.py:229-236, 264-271`). A 50,000 imágenes son 1,250 millones de comparaciones.

**La cota.** Partiendo los 64 bits en `k` bandas: si `popcount(x ^ y) <= T`, los bits que difieren tocan a lo
más `T` bandas, así que al menos `k - T` bandas son idénticas. Para garantizar **una** idéntica hace falta
`k >= T + 1`. Al umbral del CLI (5) eso son **seis bandas** de 11, 11, 11, 11, 10 y 10 bits. Indexar cada hash
por sus seis valores de banda y mirar solo los que comparten uno no puede perder un par dentro del umbral.

Bandas de 11 bits dan 2,048 buckets; ocho bandas de 8 bits darían 256, o sea ocho veces más hashes ajenos por
bucket y una lista de candidatos llena de trabajo que la comparación exacta tira. `T + 1` es el mínimo que la
prueba permite, y bandas más anchas son más selectivas.

**Y el colapso de hashes idénticos, que resultó más importante que la asintótica.** Medido sobre 2,779 fotos
reales: **1,630 clases**, o sea que 1,149 imágenes comparten su hash exacto con otra. Sin colapsar, un bucket
con diez mil frames negros enumera cincuenta millones de pares; colapsado, la clase entra una vez al índice y
los pares de adentro no necesitan comparación —son distancia cero por construcción.

**Cada par sale una vez, sin un `Set`.** Un par que choca en varias bandas se acepta solo desde la primera:
al encontrarlo en la banda `j` se revisan las bandas `0 ..< j` y se salta si alguna también coincide. Son a lo
más seis comparaciones de dos `UInt64` que ya están en registros, contra hashear el par y hacer crecer un set a
millones de entradas.

**Medido, contra fuerza bruta sobre los hashes reales:** el mismo conjunto de 4,340 pares, exacto, examinando
**0.41%** de los 3,860,031 pares posibles. Y sobre conjuntos sintéticos el ahorro se sostiene al crecer:

| n | candidatos | pares posibles | veces menos | tiempo |
|---|---|---|---|---|
| 5,000 | 46,422 | 12,497,500 | 269× | 0.00 s |
| 20,000 | 742,869 | 199,990,000 | 269× | 0.02 s |
| 50,000 | 4,628,582 | 1,249,975,000 | 270× | 0.13 s |

El plan estimaba ~255× a n=50,000; medido son 270×. **Lo que no se sostiene es la ganancia de tiempo a escala
chica**: sobre 2,779 hashes el índice tarda 0.003 s y la fuerza bruta 0.004 s. A ese tamaño el cuadrático
todavía no muerde, y el índice existe para el corpus que no cabe, no para este.

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
