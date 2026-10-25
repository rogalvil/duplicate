---
paths:
  - "Sources/DuplicateCore/Store/**"
  - "Sources/DuplicateCore/Support/**"
  - "Sources/DuplicateCore/Model/**"
  - "docs/FORMATO.md"
---

# Formatos compartidos con el CLI

Se carga sola al tocar los archivos de arriba. Viene de `CLAUDE.md`, tal cual.

- **La normalización Unicode de un nombre de archivo depende del volumen.** Medido: el volumen de
  arranque (APFS case-insensitive) **convierte a NFD** un nombre escrito como NFC, mientras el externo
  (APFS case-sensitive) **preserva NFC**. Consecuencia práctica: no se puede montar en `/tmp` un
  fixture con un nombre NFC, así que la divergencia entre orden por bytes y `String <` se testea sobre
  strings en memoria (suite `PathOrder`) y no a través del filesystem.

  Que la divergencia sea real en producción sí está medido: el corpus tiene **38 rutas solo-NFD y 10
  solo-NFC** de 71,580. Y APFS es normalization-**insensitive** para lookup en los dos volúmenes, así
  que el mismo nombre en NFC y en NFD es un solo archivo — el par del corpus son nombres *distintos*
  que usan formas distintas, no un nombre en dos formas.
- **Rehidratar un archivo de decisiones del CLI hace que *todos* los grupos salgan decididos**, porque el
  CLI escribe una entrada por grupo incluidos los que nadie abrió. Medido en este corpus: **55 de 56
  archivos tienen exactamente una decisión por grupo**, y el único parcial es el que escribió esta app. La
  app los carga —son el formato compartido— y avisa: ni rehusarlos ni tirarlos en silencio serían mejores,
  los dos son la app decidiendo por el usuario.
- **`threshold` es float y los conteos son enteros, en el mismo documento.** Escribir `5.0` donde el CLI
  pone `5` rompe la comparación byte a byte igual que escribir `1` donde pone `1.0`. Los dos errores
  existen y son opuestos; hay un test para cada uno.
- **La clave de una decisión de parecidos es `a||b` sin escapes**, formato del CLI, con el hueco que implica: una
  ruta que contenga `||` da una clave que no se puede volver a partir. Medido: **ninguna ruta del corpus lo
  contiene**, y `SimilarPairKey.isAmbiguous` lo reporta en vez de esconderlo.
- **`folder-decisions/` es la forma envuelta con listas** (`{scan_id, created_at, decisions:{"a||b":[conservadas]}}`)
  — tercera forma distinta de las tres. Y es **la única sin archivo real contra el cual verificar**: el CLI tiene el
  slot y nunca escribió uno, así que su round-trip se prueba contra un documento sintetizado y contra el código del
  CLI, no contra algo que el CLI haya escrito.
- **El orden de claves de `similar-decisions` es parte del formato.** Guardarlo en un `Dictionary` mezclaría las
  943 líneas reales y la comparación byte a byte fallaría sobre un archivo cuyo contenido es idéntico. Medido: los
  cuatro valores aparecen de verdad —`keep_a` 597, `keep_b` 337, `keep_both` 8, `keep_none` **1**— así que ninguno
  es teórico, y ordenar los miembros antes de escribir rompe **16 de 17** documentos.
- **Una decisión desconocida se rechaza, no se salta.** Saltarla convertiría en silencio un par revisado en uno
  sin revisar, y el siguiente aplicar dejaría los dos archivos donde están mientras la ventana dice que está
  decidido. El corpus real no tiene valores raros, así que eso lo prueba un test unitario y no el modo `decisions`.
- **`similar-decisions` es un mapa pelado**, sin el envoltorio `{scan_id, created_at, decisions}` que sí llevan
  `decisions/`. Un solo tipo no puede representar los dos honestamente.
- **En `similar-scans`, `img_threshold` es entero y `vid_threshold` es float, en el mismo documento** — medido
  en los 31 reales, sin excepción. Es el mismo par de errores opuestos que en carpetas: escribir `10.0` rompe
  los 31, y escribir `similarity` como entero rompe 22 (los otros 9 documentos no tienen pares).
- **Un `media_type` desconocido se rechaza, no se adivina.** El valor decide contra cuál umbral se juzgó el par,
  así que leer uno raro como imagen reportaría mal lo que el escaneo encontró.
- **`file_a` de un par parecido también es la ruta menor por bytes.** `similar-decisions` guarda `keep_a` o
  `keep_b` contra una clave `"a||b"`, así que la orientación decide cuál archivo se borra — misma lección que
  las carpetas, aplicada antes de que costara.
- **`timestamp(from:)` omite el `.000000` en un segundo exacto, y eso es correcto**: medido,
  `datetime(2026,8,12,12,0,0).isoformat()` en Python tampoco lo pone. Un test que esperaba la forma
  rellenada estaba equivocado sobre el formato, no sobre el código.
- **`ScanStore.summaries()` decodifica cada grupo de cada escaneo para producir un puñado de
  conteos.** Medido en el corpus real: 119 escaneos y 0.34 s al principio, y luego **134 escaneos, 60,719
  grupos, 3.1 s en release**, casi todo en un solo documento de 194 MB. El watcher hacía que la ventana
  lo volviera a pagar en cada cambio. Va fuera del hilo principal, con un contador de generación que
  descarta una lectura que aterriza después de una más nueva, y desde #162 con un `SummaryCache` en
  memoria por documento (tamaño, fecha de modificación e inodo): **la relectura bajó a 4.3 ms**. La
  primera lectura sigue costando lo mismo; un decodificador que no materialice las rutas para contarlas
  la bajaría, a costa de una segunda implementación del conteo de recuperables. Los dos números se
  imprimen en `--selftest --mode library`.
- **La caché de resúmenes no va a disco, a propósito.** Un índice junto a los documentos sería estado que
  el CLI no conoce, y el CLI reescribiendo un escaneo lo dejaría viejo para quien lo lea después. En
  memoria, cada ventana paga una vez la primera lectura y nada más.
- **Restaurar una fecha con `setAttributes` no la restaura exacta.** Un test que guardaba la
  `modificationDate`, reescribía el archivo y la volvía a poner, fallaba: APFS guarda nanosegundos y la
  escritura de la fecha conserva microsegundos. El test fija una fecha redonda antes de las dos lecturas.
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
