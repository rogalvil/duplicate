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
- **Una sugerencia se dibuja como el *default*, no como algo ya elegido.** Si el botón de la sugerencia sale
  presionado igual que una decisión real, las dos se ven idénticas y el único que sabe la diferencia es el
  archivo. Aquí la sugerencia toma el `keyEquivalent` de Return y ninguna se ve pulsada hasta que alguien
  decide.
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
