---
paths:
  - "Sources/DuplicateCore/Folders/**"
  - "Sources/DuplicateCore/Action/FolderApplyRunner.swift"
  - "Sources/Duplicate/Folder*.swift"
---

# Detector de carpetas

Se carga sola al tocar los archivos de arriba. Viene de `CLAUDE.md`, tal cual.

- **`NSString.deletingLastPathComponent` colapsa un doble slash y una cadena de root no.** Un root de
  `…/T//tree` con archivos de `…/T//tree/a/x.bin` daba un padre de `…/T/tree/a` —un solo slash— y el test
  de prefijo tiraba **todos** los archivos: árbol vacío, escaneo que no encuentra nada, en silencio. Y
  `NSTemporaryDirectory()` termina en slash, así que no es un caso raro. `DirectoryTree` canonicaliza
  partiendo por `/` los dos lados, y solo los slashes: nada de case folding, normalización Unicode ni
  symlinks.
- **El detector de carpetas hashea *todos* los archivos**, no solo los que colisionan por tamaño — 244 de
  10,506 en un árbol medido, 986 de 15,242 en otro. Ahí la caché de hashes deja de ser optimización y es
  la diferencia entre minutos y segundos en la segunda corrida.
- **En un par de carpetas, la orientación se mantiene estable.** El documento se usa para aplicar decisiones,
  así que la orientación no es cosmética — un escaneo que escriba la app se puede aplicar con el CLI. Se normaliza por bytes:
  `folder_a` es la ruta menor. Tomarla del orden de índices del árbol la tomaba del orden de enumeración,
  que nada promete reproducir. Medido: mismo conjunto de 42 pares que el CLI sobre un árbol real, y **los
  42 al revés**. El caso que lo destapa es una carpeta cuyo nombre es **prefijo del de su hermana** (`wen`
  y `wen 2`): el recorrido visita `wen` primero porque el nombre corto ordena antes, y el orden de bytes
  pone `wen 2/s` primero porque el espacio (0x20) le gana al slash (0x2F). **Sesenta árboles aleatorios
  nunca produjeron un hermano-prefijo** — el corpus real lo produjo en el primer intento, y es el
  recordatorio de que un fixture generado cubre lo que se le ocurrió al generador.
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
- **El recorrido de la verificación no es el del escaneo (#190).** El manifiesto usaba el `ScanPolicy()` por defecto,
  que se salta ocultos, `.git`, `node_modules`, paquetes y archivos vacíos: una carpeta cuyo único contenido propio
  era un `.git` pasaba la contención y se movía. Ahora `FolderManifest.verificationPolicy` recorre todo lo que el
  movimiento se lleva menos el ruido de Finder, porque un `.DS_Store` difiere entre dos copias en cuanto se abre una
  y exigirlo rechazaría casi todo. **El undo prueba el recorrido viejo si el nuevo no coincide**: las carpetas
  movidas antes se registraron con el otro digest, y sin eso un undo las bloquearía como editadas.
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
- **Una carpeta no tiene tamaño propio, y eso decide qué se muestra.** El visor de carpetas dice nombre, conteo
  y **fecha** por lado —la fecha es lo que contesta "conservar la más nueva" y cuesta un `stat`—, y el tamaño no
  aparece: producirlo es recorrer el árbol, que el apply ya paga una vez para el manifiesto a decenas de segundos,
  y pagarlo en cada tecla de flecha para un número que nadie decide es el trueque equivocado.
- **Y por eso los bytes movidos salen del manifiesto, no del disposer (#166).** `TrashDisposer` lee `.size`, que
  para un directorio es el tamaño de su lista de nombres: la hoja decía «1.3 KB» por una carpeta de 160 MB, y el
  journal guardaba lo mismo para el historial. El manifiesto acaba de leer cada archivo, así que la suma no cuesta
  otro recorrido.
- **Los defaults de la app desactivan el peor caso del detector de carpetas.** La clase patológica del plan es
  10,000 `__init__.py` idénticos; medido, un `__init__.py` **vacío** cae bajo el mínimo de 1 byte y un `.DS_Store`
  está en la lista de ruido, así que ninguno de los dos llega al detector. Hace falta un archivo **no vacío, no
  oculto y fuera de la lista** —un `conftest.py`— para alcanzar la ruta cuadrática.
- **Y alcanzada, la mitigación funciona y se nombra.** 7,866 `conftest.py` idénticos son **30.9 millones de
  pares**: el detector trunca la clase, la reporta como `conftest.py with 7866 files`, y el escaneo termina en
  43.6 s en vez de moler los 30.9 millones.
- **La única posición donde un manifiesto corto se escapa es el último archivo de un build.** El checkpoint por
  archivo atrapa todas las demás. Medido: cancelar en el último archivo de la carpeta *conservada* —lo único entre
  ese hash y la comparación— reportaba `wouldLoseFiles(count: 1, examples: ["f2.txt"])` sobre un archivo que está
  en las dos carpetas. Cancelar en el último de la carpeta condenada es inocuo, porque el segundo build lanza en su
  primer checkpoint. Mi comentario decía "una carpeta movida que no debía" y estaba exagerado.
