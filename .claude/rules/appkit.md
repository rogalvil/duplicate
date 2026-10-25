---
paths:
  - "Sources/Duplicate/**"
---

# Ventanas, menús y AppKit

Se carga sola al tocar los archivos de arriba. Viene de `CLAUDE.md`, tal cual.

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
- **Un panel vacío no distingue "el archivo ya no está" de "la miniatura todavía no llega".** Y en el corpus
  real pasa seguido: de los pares perceptuales, un lado del primero ya no existe. El panel lo dice.
- **`return refreshAdvice()` compila y no avisa.** Un `return` seguido de una llamada a `Void` en la línea
  siguiente se parsea como devolver ese `Void`, así que funcionaba por accidente de formato y sin warning; había
  además tres llamadas redundantes que recomputaban el consejo hasta cuatro veces por selección. Un `sed` que
  inserta en cada match las deja así.
- **La clave de un thumbnail no siempre es el digest.** En un grupo exacto los archivos son idénticos por
  construcción y uno solo sirve para todos; en un par perceptual son **fotos distintas** —es lo que el detector
  encontró— y compartir la miniatura dibujaría una encima de la otra, o sea el peor bug posible en una vista
  lado a lado: haría que todos los pares se vieran idénticos. Por eso `ThumbnailKey.Identity` es `.content` o
  `.path`.
- **El umbral de cada detector es otra cantidad en otra unidad**: carpetas es Dice en porcentaje, imágenes es
  distancia de Hamming en bits sobre 64. Un solo menú mostrando "90%" para los dos serían dos significados
  detrás de un número, así que los ítems se reconstruyen al cambiar de detector.
- **El resultado del chequeo de disco se guarda en `Caches`, con su fecha, y nada destructivo lo cree.**
  Tarda lo suficiente para no valer repetirlo, y conserva casi todo su valor —un escaneo de mayo cuyos
  archivos ya no están seguirá sin tenerlos mañana— pero solo es cierto en el instante en que se tomó. El
  apply re-hashea cada archivo justo antes de moverlo, así que una foto vencida cuesta un archivo rehusado
  y un error honesto, nunca un movimiento equivocado.
- **Se guarda por clave de grupo, no por índice.** Un índice solo significa algo para un documento exacto;
  `size:digest` sobrevive un re-escaneo del mismo contenido, que es justo para lo que sirve guardarlo.
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
- **Una ventana necesita `minSize`, no confiar en sus constraints.** Arrastrada por debajo de lo que el
  layout necesita, AutoLayout empieza a romper constraints y el panel de detalle desaparece entero — visto
  en una captura real: ventana aplastada, mitad derecha vacía, sin pie.
- **Cambiar el valor por default de un campo no es un arreglo de copy.** Poner "1 KB" en el campo de
  tamaño mínimo se veía como aclarar la unidad y era una divergencia de comportamiento: el archivo de 6
  bytes dejó de contarse y el modo `scan-window` lo atrapó. El default del CLI es 1 byte y ahí se queda;
  un default que valga cambiar se cambia a propósito, en su propio cambio, y se dice en el README.
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
- **El panel muestra la ruta completa, no solo el nombre.** Con el padre común izado fuera de las filas,
  un panel con solo el nombre no deja distinguir dos archivos que se llaman igual. También lo encontró el
  uso real.
- **`Mutex` es noncopyable**, así que no se puede capturar en los closures que escapan (el de progreso y
  el del `Timer`). Una clase `Sendable` con un `Atomic` adentro sí.
- **El closure de un `Timer` es nonisolated**, así que pasarle el propio `timer` para invalidarse es una
  carrera que el compilador rechaza. Se guarda el timer en una propiedad `@MainActor` y se invalida ahí.
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
- **Contar entradas de una caché de thumbnails es inestable.** El tamaño en píxeles viene del ancho del
  panel, el ancho se asienta durante el layout, y una ventana que nunca se muestra hace layout cuando le
  toca. Tres de seis corridas guardaban dos entradas —una por tamaño— con código correcto. La propiedad
  estable, y la que la clave por digest existe para dar, es que el **segundo archivo del grupo no falle**
  la caché.
- **Quick Look no se abre solo: pide permiso al responder chain y luego una fuente de datos.** Sin
  `acceptsPreviewPanelControl` más `begin/endPreviewPanelControl`, el panel abre **vacío**, que se ve igual que
  una vista previa rota y no como cableado faltante. Y los tres son `nonisolated` porque vienen de `NSResponder`,
  mientras `QLPreviewPanel.dataSource` sí está aislado al main actor: van con `MainActor.assumeIsolated` o el SDK
  de CI lo vuelve error duro. **Sexta divergencia entre SDKs.**
- **`QLPreviewPanelDataSource` no está anotado**, así que declarar la conformancia en un tipo `@MainActor` es
  error de compilación por cruzar código aislado. La conformancia va en una extensión `nonisolated` con
  `assumeIsolated` adentro.
- **⌘Y y no la barra espaciadora.** El espacio ya es el toggle de conservar en la revisión exacta, donde una
  lista de archivos tiene el foco; robarlo sería cambiar un gesto por otro. ⌘Y es el otro atajo de Vista rápida
  de Finder.
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
- **`toggleDiskCheck` alterna: llamarlo mientras corre lo cancela.** Un observador de notificación que lo invocara
  a ciegas cancelaría el chequeo en curso.
- **`NSUndoManager` no llega al usuario sin un ítem de menú que mande `undo:`.** Registra
  perfectamente y es invisible: una revisión sin deshacer se vería como una decisión de diseño. Por eso
  existe el menú Edición, y por eso el modo `menu` afirma que alguien manda `undo:` y `redo:`.
- **`validateMenuItem` en un `NSWindowController` no es un `override`.** Viene de
  `NSMenuItemValidation`; escribir `override` es un error de compilación que se lee como si el método
  estuviera mal.
- **El estado vacío se oculta hasta que la primera lectura termina.** Con la carga en background,
  mostrar "todavía no hay escaneos" durante un tercio de segundo antes de que lleguen 119 filas se lee
  como un bug.
- **`Array.sort` no es estable.** Un comparador que declara iguales dos filas puede devolverlas en
  cualquier orden, así que una lista de escaneos con el mismo número de grupos se reordenaría sola cada
  vez que el watcher dispara. Todo orden de la biblioteca desempata en el `scan_id`, que es único por
  construcción.
- **La selección de la tabla se restaura por `scan_id`, no por índice de fila.** Un escaneo nuevo
  aparece arriba y corre todos los índices de abajo; reaplicar el índice movería la selección a otro
  escaneo sin avisar.
- **Con una hoja pegada a una ventana, AppKit no deja salir, y ni le pregunta a la app.** `terminate` (⌘Q, Salir
  del Dock) se rechaza **antes** de llamar a `applicationShouldTerminate`; sin hoja, el mismo `terminate` sí llega
  y la app sale. Medido con trazas sobre la app real. Por eso la hoja de aplicar ya protege el apply y #145 no se
  reproducía, y por eso ⌘Q "no funciona" mientras la hoja de resultado sigue abierta: es lo esperado.
