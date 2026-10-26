---
paths:
  - "Sources/DuplicateCore/Action/**"
  - "Sources/Duplicate/*ApplySheetController.swift"
  - "Sources/Duplicate/UndoCoordinator.swift"
  - "Sources/Duplicate/SessionHistoryWindowController.swift"
---

# Aplicar, deshacer, journal y disposer

Se carga sola al tocar los archivos de arriba. Viene de `CLAUDE.md`, tal cual.

- **El journal es JSON Lines (`.jsonl`), no un array JSON.** No se puede hacer append a un `[…]`
  pretty-printed sin reescribirlo, y un crash a media escritura tiene que dejar legible todo lo
  anterior. Una línea truncada cuesta esa línea y nada más.
- **Podar un journal necesita una regla *provable*, no probable.** El journal es el único registro de dónde
  quedó un archivo. La única condición que se ofrece es "todos sus archivos ya volvieron", y lo dice el journal
  mismo con sus `undone_at`. Rechazadas por escrito: "sus ítems de Papelera ya no están" leería un **volumen
  externo desmontado** como una Papelera vaciada —y el corpus de este usuario vive en uno—, y "más viejo que N
  días" cambia una capacidad real por kilobytes.
- **Una sesión vacía o ilegible NO es podable**, y el diente lo prueba: quitando el `movedCount > 0` de la regla,
  el journal que no se pudo parsear se vuelve borrable y se borra —o sea que se destruye la única evidencia de que
  hubo algo ahí.
- **Los `undone_at` los escribe `UndoCoordinator`, en el ejecutable, no `UndoRunner`.** Así que un arnés que
  maneje el runner directo nunca produce una sesión podable: la aserción de poda tiene que pasar por el
  coordinador, o estaría afirmando sobre un journal que ningún undo real produce.
- **Un `undone_at` se agrega, no reescribe la línea original.** Así el journal sigue siendo un log
  veraz de lo que pasó en orden, en vez de un resumen mutable del estado actual — y un rewrite que
  falle a la mitad perdería todo.
- **El digest de un directorio es su manifiesto, y construirlo dentro del entorno del planificador costaba 33.8
  segundos de ventana congelada.** El entorno es síncrono —eso es su diseño, para que la decisión se revise aparte
  de la mutación—, así que no podía consultar la caché, que es un actor. Medido: 979 MB/s sobre 200 archivos de 3 MB,
  o sea 33.8 s extrapolados a una carpeta de 10,506 fotos, **justo después del apply que puso esos mismos digests en
  la caché**. Y el comentario en el call site decía que venían de la caché: era falso, `buildSynchronously` no
  recibía ninguna. Ahora los precalcula `UndoPreflight` (async, cacheado, cancelable) y el planificador sigue siendo
  puro.
- **Con eso `FolderManifest.buildSynchronously` desaparece, y con ella dos implementaciones del mismo manifiesto.**
  Un manifiesto es lo que decide si una carpeta se borra; dos versiones que podían discrepar sobre qué archivos
  cuentan era el riesgo de fondo, más grande que la asimetría de cancelación que lo destapó.
- **Un digest ausente NO es `contentChanged`.** Bloquea igual —este planificador nunca actúa sobre lo que no pudo
  verificar— pero la razón verdadera es `unverifiable`. Decir "esto cambió" cuando el digest nunca se calculó le
  afirma al usuario algo sobre sus datos que nadie estableció. Tercera vez que aparece este patrón en el proyecto.
- **Los obstáculos del deshacer se pintaban con `rawValue`**, o sea `originalPathOccupied` en pantalla. Esa
  distinción es la diferencia entre "la app está rota" y "la app se negó a sobrescribir mi trabajo".
- **Volver `async` el undo convierte los hooks del arnés en carreras.** El `undoNow` de las hojas lanza un `Task` y
  regresa; el arnés afirmaba de inmediato y salía `the file was not put back`. Cada hoja guarda su `undoTask` y
  expone un `awaitUndoForSelftest()`. **Ojo**: `undoForSelftest()` existe con ese nombre también en las revisiones,
  donde significa ⌘Z —otra cosa—, y un `sed` sobre el nombre se los llevó a los dos.
- **La cuarentena no puede rescatar un volumen de solo lectura, y ese era la mitad de su razón de ser.** Mover un
  archivo *fuera* de un volumen read-only tiene que borrar el origen, así que ahí falla igual que la Papelera. La
  respuesta honesta es una rehúsa con el archivo todavía en su lugar, no una copia que deja dos. Probado con una
  imagen APFS de solo lectura hecha con `hdiutil` y sin root, que es lo que también cubre las ramas de error del
  disposer: **79.86% → 93.06%** en `Disposer.swift`.
- **Y el miedo a exFAT del plan está muerto: medido, `trashItem` funciona en FAT32** y crea `.Trashes/501` igual que
  en APFS. Así que el único caso que la cuarentena de verdad rescata es un montaje de red — que no se puede fabricar
  en esta máquina sin servidor.
- **Dos ramas del disposer no son alcanzables con un `FileManager` real y se quedan documentadas, no cubiertas**:
  que `trashItem` no lance y tampoco reporte destino, y el default de `Application Support` cuando
  `urls(for:in:)` devuelve vacío. Las dos se conservan porque su alternativa es prometer algo que el journal no
  puede cumplir.
- **Y el único volumen donde falla es uno de red, medido por fin.** `mount_smbfs //roger@localhost/roger` da un
  `smbfs` real, y ahí `trashItem` falla con `NSCocoaErrorDomain` **3328**: *"el volumen «roger» no tiene"* —no hay
  Papelera en un volumen SMB—. Esa es la rama que la cuarentena existe para atender, y la cadena completa corrió:
  la Papelera rehúsa, el fallback mueve a una cuarentena local, el journal lo registra como `.quarantine`, y el
  deshacer lo devuelve al share **byte-idéntico**. Era el último camino del código destructivo sin probar.
- **El `mechanism` del journal NO es load-bearing para el deshacer**, y creía que sí. Escribir `.trash` donde iba
  `.quarantine` no cambia nada: el undo restaura desde `resultingPath` y nunca consulta el mecanismo. El campo
  existe para que un reporte le diga a alguien cuyos duplicados viven en un NAS **dónde ir a buscar**, no cómo
  recuperarlos. Se afirma por el journal por esa razón, no por la del undo.
- **`FileManager.trashItem` funciona en todos los volúmenes de esta máquina.** Medido: boot y `$HOME`
  aterrizan en `~/.Trash`, los dos externos en `<volumen>/.Trashes/501`. Era el riesgo más grande del
  plan (que el externo fuera exFAT y no pudiera), y está descartado. La cuarentena es fallback de
  verdad, para montajes de red y volúmenes read-only.
- **Si `trashItem` no devuelve `resultingItemURL`, el movimiento se considera fallido.** Sin destino no
  se puede deshacer, y reportar éxito sería una promesa que el journal no puede cumplir.
- **`~/.Trash` no se puede *listar* desde la shell (TCC), pero `fileExists` sí funciona ahí.** Eso es
  lo que permite verificar por ruta que un test no dejó basura; un `ls` da "Operation not permitted".
- **La lista de fallos de un apply estaba imprimiendo Swift.** `contentChanged(path: "/Users/…")` nombra un caso
  de enum en la única lista que el usuario **tiene** que leer después de borrar algo, y lo que necesita de ahí son
  dos cosas: qué pasó y si su archivo sigue en su lugar. Las rehúsas sí estaban localizadas desde el principio, lo
  que hacía el contraste peor. Una sola función para las tres hojas, porque un fallo significa lo mismo venga del
  detector que venga y tres copias son tres formas de describir el mismo estado.
- **Una rehúsa no es una falla, y mezclarlas entrena a ignorar las fallas.** El aplicar exacto mueve o falla; el
  perceptual además puede declinar porque el par ya no se parece — eso es el chequeo funcionando, y va primero en
  el reporte porque es lo que el lector tiene que atender: esos archivos siguen ahí.
- **En un par parecido no hay nada que prometer sobre espacio recuperado.** El exacto sabe que los archivos de un
  grupo son byte-idénticos; dos parecidos tienen tamaños distintos, y el único número honesto es el de los
  archivos que de verdad se movieron.
- **Una ruta que una decisión borra y otra conserva se excluye del plan, no se avisa.** Las dos decisiones son del
  usuario, y la única lectura que respeta las dos es no actuar sobre ninguna.
- **Agregar un punto de cancelación a una función envuelta en ocho `try?` es el cambio, no la línea.** Cada `try?`
  convierte la cancelación en el error local de su sitio. Auditados: en `VerifyingDisposer` salía `.missing`, o sea
  "tu archivo ya no está" por presionar Detener; en el runner perceptual salía `.unreadable`; y en
  `FolderManifest.build` el `try?` dejaba una entrada afuera. Los tres se arreglaron; los otros cinco fallan hacia
  el lado seguro y quedan documentados en el sitio.
- **Una cancelación tragada por un `try?` acusa a los datos del usuario.** Cancelar durante la verificación de una
  carpeta hacía que `FolderManifest.build` lanzara `CancellationError`, el `try?` la volviera `nil`, y el runner
  reportara `.unreadable` sobre una carpeta perfectamente sana —con `wasCancelled: false`, o sea que ni la ventana
  sabía que se había detenido—. Y `unreadable` es justo la rehúsa que manda a alguien a buscar daño. Lo mismo pasaba
  en el perceptual: un decode de video cancelado volvía como "no pude leer este archivo". Las dos ahora viajan como
  cancelación: `catch is CancellationError` en el runner de carpetas, y un veredicto `.cancelled` en el verificador
  perceptual que **no** es una rehúsa —nada se decidió sobre ese par, así que no puede aparecer en una lista que se
  lee como "estos los revisé y los dejé en paz".
- **Y para imágenes hay que chequear `Task.isCancelled` a mano.** `ImageHasher` es síncrono y no tiene punto de
  cancelación, así que sin ese chequeo un par de imágenes en vuelo se terminaba de verificar y **se movía** después
  de presionar Detener. Medido con el diente puesto: el veredicto salía `.stillAlike` y `allowsMove == true`.
- **Cancelar un apply no puede lanzar: tiene que devolver reporte.** Lanzar desde el chequeo al inicio del loop
  **se saltaba el `flush()` final**, así que hasta 31 archivos ya movidos quedaban en la Papelera **sin entrada en el
  journal** — o sea invisibles para el deshacer. Ahora rompe el loop, hace el flush y devuelve el reporte con
  `wasCancelled`, que es lo que la ventana necesita para ofrecer el undo de lo que sí se movió.
- **`Task.isCancelled` funciona en código síncrono**, así que el runner exacto honra un cancel sin volverse `async`:
  corre en una tarea desprendida y ahí la bandera se ve.
- **Y el botón de detener se queda vivo durante el apply.** Verificar y mover cientos de ítems toma minutos, y una
  barra de progreso sin salida no es una opción. Cerrar la hoja mientras corre **detiene y no cierra**, porque el
  reporte de lo que ya se movió es justo la razón para no cerrar.
- **Una barra que solo cuenta ítems miente sobre el apply de carpetas.** Verificar un par digiere **cada archivo
  de las dos carpetas** antes de mover nada —10,506 archivos en uno de los árboles medidos de este usuario— así que
  la barra se queda en "1 de 8" durante minutos mientras lo único en pantalla dice que está moviendo. Una barra
  quieta sin texto es indistinguible de un cuelgue, y lo que un usuario hace ante un cuelgue es forzar la salida de
  una app que va a la mitad de mover sus fotos. Por eso el progreso lleva **etapa** además de conteo, y la etapa es
  un valor (`ApplyStage`), no una frase: "verificando" y "verifying" son el mismo estado.
- **La etapa necesita un tercer caso, `done`, o el reporte es ambiguo.** Con solo `verifying` y `moving`, un reporte
  `.moving` con `itemsDone: 1` significa a la vez "el ítem 1 terminó" y "el ítem 2 empezó a moverse". Lo destapó un
  test que esperaba `[1, 2, 3, 4, 5]` y recibió `[1, 1, 2, 2, 3, 3, 4, 4, 5]`. Con `.done`: la barra avanza y la
  etiqueta conserva lo último que dijo, en vez de parpadear una línea de un ítem que ya pasó.
- **Los dos manifiestos de un par cuentan en un solo número.** Para quien lee, es un par siendo revisado; que el
  contador se reinicie a cero a la mitad se ve como que algo se reinició.
- **Veinte fallas seguidas detienen un apply; una sola no.** Un archivo bloqueado por otro proceso no
  puede abortar los otros 3,997, pero un problema global —permiso revocado, volumen que se fue— no debe
  producir cuatro mil filas idénticas que leer.
- **El journal se escribe en lotes de 32 durante el apply, no al final.** Un crash a media corrida tiene
  que dejar un journal que describa lo que ya se movió, o esos archivos no se pueden devolver.
- **`attributesOfItem` NO sigue symlinks** — medido, y lo contrario es la suposición fácil. Aquí es el
  comportamiento correcto: un symlink nunca es miembro de un escaneo, así que uno parado en una ruta
  registrada significa que el archivo fue reemplazado. Y `trashItem` sobre un symlink manda el enlace y
  deja los bytes, o sea espacio "liberado" que ningún `df` confirma.
- **Deshacer cualquier sesión ya era posible y nada lo nombraba.** `UndoCoordinator.undo(sessionID:in:)` toma un
  identificador arbitrario desde que se escribió, pero la única entrada era "deshacer la última": aplicar dos veces
  y querer la primera de vuelta no tenía camino. La ventana de historial no agregó capacidad, agregó una fila por
  sesión.
- **Un solo lector de journals para el historial y para la poda.** Dos parseos son dos oportunidades de discrepar
  sobre si una sesión está terminada, y una de esas respuestas **borra un archivo**. `JournalPruner` clasifica
  sobre `SessionHistory.rows(in:)`.
- **El historial no refresca la presencia de otras ventanas, y es a propósito.** Hacerlo significa arrancar un
  chequeo de disco que hace `stat` por archivo del escaneo —trabajo que nadie pidió, a espaldas del usuario, porque
  deshizo algo en otra ventana—. Una etiqueta vieja que se refresca con un botón es el error más chico.
- **Lo que no se puede registrar no se mueve.** El journal se escribía en lotes **después** de mover, así que un
  directorio de journal sin permiso de escritura se descubría con hasta 31 archivos ya movidos y ninguna línea que
  dijera adónde (#175, reproducido con un test temporal: `moved to quarantine: 2 | journal files: []`). Ahora los
  tres runners llaman a `MoveJournal.ensureWritable` antes del primer movimiento. Con `access`, no creando el
  archivo: un journal vacío sería una sesión que el historial lista y la poda nunca puede quitar. Un disco que se
  llena a media corrida sigue siendo posible.
- **Conservar con el nombre de otro es un renombrado exclusivo, al final (#228).** `renamex_np` con `RENAME_EXCL`,
  medido en el volumen de arranque: con el destino ocupado devuelve `EEXIST` y deja el otro archivo intacto, y con un
  nombre que solo cambia mayúsculas **sí** renombra. Un `fileExists` antes del renombrado habría rehusado ese segundo
  caso, porque en un volumen que ignora mayúsculas el nombre viejo contesta por el nuevo. Corre solo si la corrida
  terminó (ni cancelada ni detenida) y solo si el archivo que presta el nombre ya no está: el nombre se libera
  cuando el otro se va.
- **Al deshacer, los renombrados van primero, del último al primero.** El nombre nuevo suele ser la ruta original de
  un archivo que la misma sesión mandó al basurero; planeado en orden de journal, ese archivo quedaba bloqueado como
  "ruta ocupada" por el archivo que el mismo deshacer iba a quitar de ahí. El resto se planea contra el sistema de
  archivos **como quedará** tras esos renombrados, construido **una vez**: reconstruirlo por cada una de 4,000
  entradas sería cuadrático, y sin renombrados es el entorno mismo.
- **Y un renombrado que solo cambia mayúsculas no está "ya devuelto".** `IMG.png` → `img.png` deja el nombre viejo
  "existiendo" en un volumen que ignora mayúsculas, y el planificador lo leía como restaurado. El entorno pregunta
  ahora si dos rutas son el mismo archivo (`FileIdentity.same`, por dispositivo e inodo).
- **Los métodos de ruta de `NSString` limpian lo que devuelven, y eso rompió el deshacer.** `deletingLastPathComponent`
  y `appendingPathComponent` colapsan un `//`, así que el destino del renombrado dejó de ser, byte a byte, la ruta que
  el otro archivo dejó libre, y el plan de deshacer —que empata rutas por bytes— lo bloqueó. Lo destapó el test de
  punta a punta, porque `NSTemporaryDirectory()` termina en `/`. El destino se corta sobre bytes UTF-8.
- **Un `try?` sobre `fullDigest` vuelve "ilegible" un Detener a media lectura.** El hasher lanza `CancellationError`
  entre dos chunks, y el chequeo de `Task.isCancelled` *antes* de leer no cubre eso. Lo encontró la revisión de #229 en
  el renombrado, y el mismo `try?` estaba desde antes en el digest de cada ítem del runner perceptual: los dos atrapan
  ahora el error y preguntan por la cancelación antes de culpar al archivo.
- **Los renombrados son pasos de la barra (#228)**: cada uno lee su archivo entero, y una barra llena mientras se
  hashea un video de 4 GB parece terminada o colgada. Tienen su propia etapa, `renaming`.
- **La proyección del deshacer se actualiza paso a paso.** La primera versión la reconstruía con todos los renombrados
  anteriores en cada paso: n²/2 preguntas al sistema de archivos, síncronas, con la ventana esperando. Un test cuenta
  las preguntas para 300 renombrados.
- **Un test de cancelación que cancela antes de que el nombre se libere no prueba la guarda.** El primero pasaba
  con las dos guardas de cancelación quitadas: el archivo que prestaba el nombre seguía ahí, y la otra guarda
  ("su dueño sigue") detenía el renombrado. El que muerde cancela **después** de que ese archivo se movió, con un
  hasher que cancela su propia tarea al contestar.
