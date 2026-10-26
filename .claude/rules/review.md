---
paths:
  - "Sources/DuplicateCore/Review/**"
  - "Sources/Duplicate/ReviewWindowController.swift"
  - "Sources/Duplicate/SimilarPairWindowController.swift"
  - "Sources/Duplicate/FolderPairWindowController.swift"
---

# Revisión y decisiones

Se carga sola al tocar los archivos de arriba. Viene de `CLAUDE.md`, tal cual.

- **ICU quita los espacios *dentro* de una clase de caracteres bajo `allowCommentsAndWhitespace`; el
  `VERBOSE` de Python no.** Por eso `[ _-]\\d+` se volvía `[_-]\\d+` y el port discrepaba del CLI justo
  en los nombres que terminan en espacio y dígitos (`photo 1`, `photo copy 2`). Los espacios dentro de
  clases van escritos `\\x20`. Reusar el texto del regex verbatim **no** era suficiente.
- **Los dos motores sí coinciden en el espacio de `\\( ?copy\\)?`**: los dos lo quitan, así que el `?`
  termina aplicando al paréntesis de apertura y un sufijo `copy` pelado matchea. Por eso `photo.copy`,
  `copy` y hasta `xcopy` puntúan 1 en las dos herramientas. Sorprendente, pero compartido.
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
- **Una sugerencia no se dibuja como algo ya decidido.** Cuando el visor de parecidos decidía con botones, la
  sugerencia tomaba el `keyEquivalent` de Return y ninguno se veía pulsado hasta que alguien decidía: si el botón
  sugerido saliera presionado igual que una decisión real, el único que sabría la diferencia sería el archivo. Con
  los grupos (#217) la sugerencia es la casilla marcada, como en la revisión exacta, y la columna de decisión solo dice
  «conserva 1 de 3» para un grupo confirmado.
- **Las contradicciones se avisan al cerrar, no en cada clic.** El conflicto solo importa cuando el conjunto de
  decisiones está terminado, y una hoja tras cada elección haría imposible decidir 4,771 pares.
- **Los parecidos se revisan por grupo, y el archivo sigue siendo por par (#217).** Tres copias de un video son tres
  pares, y decididos uno a uno el tercero solo podía contradecir a los dos primeros. Medido en los 84 escaneos de este
  usuario: 8,288 pares de video en 1,254 grupos, y uno de 23 copias eran 253 pares. Un grupo es un conjunto que se
  conserva, escrito como `keep_a`/`keep_b`/`keep_both`/`keep_none` por par, así que no se puede contradecir y el CLI lo
  lee igual.
- **Un archivo solo se descarta junto a uno que se queda y al que se parece.** 46 de 683 grupos de imágenes de tres o
  más están encadenados (A~B~C sin A~C). Conservar solo A descartaría C por B, que también se va, y el verificador,
  que puntúa cada archivo contra su contraparte, no tendría nada que se quede contra qué medirlo. Por eso el plan
  prefiere una contraparte conservada, y "descartar todo el grupo" no se ofrece.
- **Las claves de los grupos son bytes.** Un `String` uniría una ruta NFC y una NFD en un solo nodo, o sea dos archivos
  revisados bajo un nombre.
- **"Descartar los dos" ya no es un botón (#217).** Iba en rojo porque era la única opción que quitaba dos archivos
  de una, y en el corpus real se usó **una vez en 943 decisiones**. Con los grupos, `keep_none` solo sale entre dos
  archivos que se descartan junto a uno que se queda; el codec lo sigue leyendo.
- **Un archivo puede estar en varios pares, y eso es lo normal, no un borde**: 4,771 pares sobre 2,460 archivos
  en el corpus real. Un plan que listara la misma ruta dos veces intentaría moverla dos veces, y el segundo
  intento fallaría sobre un archivo que ya está en la Papelera — un error reportado por algo que funcionó.
- **Y los pares que se traslapan pueden contradecirse, incluso con la *misma* decisión en los dos.** Con (a,b)
  keep_a y (b,c) keep_a: el primero borra `b` y el segundo **conserva** `b`. Actuar sobre los dos borra un archivo
  que el usuario eligió conservar un par después. Transitivamente puede ser lo que quiso —a ≈ b ≈ c, conservar a—
  pero nadie dijo "borra b" en el segundo par, e inferirlo es justo la clase de amabilidad que una acción
  destructiva no puede tener. Se reporta con `contradictions`, no se resuelve. Un test mío afirmaba lo contrario y
  estaba equivocado.
- **En parecidos, la calidad va antes que el nombre (#223), y eso se aparta del CLI a propósito.** El CLI ponía primero
  el nombre que parece copia, así que «foto copia.jpg» perdía contra «foto.jpg» aunque tuviera cuatro veces la
  resolución; lo reportó el uso real. Ahora: consejo de video, resolución y bytes, nombre, profundidad. La sugerencia
  no es formato compartido —nada llega al archivo sin confirmar—, así que divergir del CLI ahí no rompe nada.
- **Un grupo sin abrir no tiene resolución, así que el lote pesa por tamaño.** La sonda lee cada archivo (300 ms un
  video) y solo corre al abrir un grupo; sin eso, «Aceptar los N sin decidir» caía al nombre. El tamaño es un `stat`.
  Y **parejo contra parejo**: si de un par solo se sondeó un archivo, los dos se pesan por tamaño, porque una
  resolución contra un cero desconocido ganaría siempre.
- **El desempate final de un par parecido es la profundidad, y gana el más profundo** — contraintuitivo y a
  propósito: es la regla del detector exacto, y que los dos detectores propusieran sobrevivientes distintos para
  los mismos dos archivos sería peor que una regla rara.
- **Con un filtro activo, la fila de la barra lateral es un índice en la lista *visible*, no en el
  escaneo.** Y cualquier mutación puede cambiar esa lista: decidir un grupo con "sin decidir" encendido lo
  saca. Sin reconstruir después de mutar, la barra sigue mostrándolo mientras el estado ya avanzó — lo
  atrapó una captura real: la barra resaltando "Grupo 31" y el encabezado diciendo "Grupo 32 de 880".
- **El plan de aplicar sale de `removalPlan`, no de `decisionsForSaving`.** Son dos funciones distintas
  sobre el mismo tri-estado, y confundirlas hace que un arnés pruebe la que no importa: medido, romper
  `decisionsForSaving` deja pasar la aserción de "una revisión intacta no planea mover nada", y romper
  `removalPlan` la hace fallar.
- **Confirmar es lo que convierte un preview en decisión.** Dejar el keep set correcto no alcanza: si el
  heurístico ya eligió bien, no hay nada que alternar y el grupo sigue `.undecided`. Eso es el
  tri-estado funcionando, y un arnés que solo alterna casillas obtiene un plan vacío — ya pasó.
- **El keeper del heurístico es el archivo más profundo.** `depthScore` es la profundidad *negativa*,
  así que `fotos/sub/a.jpg` le gana a `fotos/a.jpg`. Es contraintuitivo y es la decisión del CLI; un
  arnés que asuma que gana el primero falla contra código correcto — ya pasó al escribir el modo
  `review-window`.
- **La revisión captura el estado completo para deshacer, no un delta.** `decisions` es un diccionario
  de enums chicos sobre a lo más unos miles de grupos, así que un snapshot cuesta menos que la
  contabilidad que un delta necesitaría — y un undo que restaura un snapshot no puede desincronizarse
  de la operación de ida.
- **Aplicar exige una simulación *vigente*, no "hubo una alguna vez".** Editar una sola decisión
  después de ver el dry-run invalida la aprobación, porque el plan que el usuario aprobó ya no es el
  plan que correría. Por eso `ReviewFlow` guarda la huella del plan simulado y `ApplyGate.authorize`
  la compara; un botón gris es detalle de presentación, y un atajo de teclado o una hoja que se quedó
  abierta lo alcanzan igual.
- **La huella del plan no puede venir del `Hasher` de Swift.** Está sembrado por proceso, así que
  sobrevivir a un relanzamiento — que es lo que una revisión reabierta necesita — lo descarta. FNV-1a
  a mano, 20 líneas, porque esto compara un plan contra sí mismo minutos después y no contra un
  adversario.
- **El nombre elegido se guarda como se eligió y se valida al leer (#228).** Con dos archivos conservados, "este
  archivo con aquel nombre" no nombra ningún archivo, así que `nameSource` devuelve `nil`; volver a conservar uno
  recupera la elección en vez de perderla, **también en disco**: `renamesForSaving` escribe toda elección guardada,
  activa o no, porque guardar solo las activas borraba el nombre al confirmar dos conservados (revisión de #229). No
  es una decisión: se guarda al elegir, también en un grupo sin decidir, pero solo `renamePlan` —grupos decididos que
  conservan uno— actúa. Y va en `similar-renames/`, no en el archivo
  de decisiones: es el mapa de pares del CLI y no tiene dónde poner un nombre.
