---
paths:
  - "Sources/DuplicateCore/Hash/**"
  - "Sources/DuplicateCore/Scan/**"
  - "Sources/DuplicateCore/Runtime/**"
  - "Sources/DuplicateCore/Media/PerceptualCache.swift"
---

# Hasheo, cachés, escaneo y mediciones de rendimiento

Se carga sola al tocar los archivos de arriba. Viene de `CLAUDE.md`, tal cual.

- **La fase `.finished` se marca antes de que el escaneo termine de trabajar.** `DuplicateFinder` la pone tras
  agrupar, y después `ScanSession` todavía persiste la caché y escribe el documento — sobre 1.3 millones de
  archivos, minutos con la palabra "Terminado" en pantalla y un botón de Cancelar que ya no cancela nada. Es la
  lección de la barra quieta del apply, en una fase que ni siquiera tiene barra, y peor: la etiqueta no es
  ambigua, **afirma** que acabó.
- **`AttrListWalker` está rechazado con número, no por pereza.** `fs_usage` sobre 3,421 archivos: **0.12 syscalls
  de la familia stat por archivo** y 292 `getattrlistbulk` (~11.7 entradas por llamada), contra los **3-4 stats por
  archivo** que hace el CLI en Python. La regla del plan era "si la razón es < 1.2, `FoundationWalker` se queda";
  sale 0.12. Esas ~400 líneas de aritmética de punteros no se escriben. Necesita `sudo`, así que la corrió el
  usuario.
- **Y el mismo trazo mostró que el 61% de los `pread` de un escaneo eran la sonda de prefijo** (3,824 de 6,241),
  medido con el umbral viejo de 256 KiB. Dos instrumentos distintos —tiempos y syscalls— dijeron lo mismo.
- **La etapa de prefijo estaba mal calibrada y ahora el umbral es 8 MiB.** A los 256 KiB que se enviaron sondeaba
  **1,912 de 3,421 archivos, cobraba 54% del tiempo y ahorraba 1 MB de 1.5 GB**. El argumento del plan (dos
  imágenes de 4 GB del mismo tamaño) sigue en pie; el umbral no. A 8 MiB es indistinguible de apagarla sobre fotos.
- **`F_NOCACHE` da 4× menos page cache, no cero**: +0.10 GB contra +0.40 GB para las mismas 1.52 GB leídas, al
  mismo tiempo de reloj. La mayoría de los archivos están debajo del umbral y se cachean igual. Sale gratis, se
  queda.
- **En el corpus externo real no hay E/S que paralelizar**: 1,137 archivos, **29 candidatos por tamaño**, 0.011 GB
  leídos. El bucketing elimina el 97% antes de abrir nada, así que el caso que el plan llamaba el importante —el
  tope de 2 en externos— no se puede medir sobre estos datos.
- **El barrido de concurrencia es plano de c=1 a c=16, y la afirmación anterior era ruido.** Este archivo decía
  que "sigue mejorando hasta c=16 y el tope de 8 deja ~13%". Con **mejor de tres** por nivel, sobre 5 GB de
  archivos de 64 MiB: 3,230 / 3,056 / 3,200 / 2,998 / 3,375 / 3,275 / 3,108 / 3,108 MB/s. ±6% alrededor de 3,170,
  sin tendencia. **Un solo worker ya satura.** La corrida única que produjo el 13% también produjo 939 MB/s en c=4
  entre vecinos de 3,084 y 2,896 — un 3× de swing entre vecinos no es una curva.

  Consecuencia: el tope de 8 **no deja rendimiento en la mesa**, y la predicción del plan —"hashear con un hilo es
  CPU-bound por factor 2-4, hacen falta 3-4 hasheadores para saturar"— está **falsada** en esta máquina: un hilo
  llega a 3.0 GB/s.
- **Y el frío contra el caliente es una distinción vacía arriba de 1 MiB, por construcción.** `noCacheThreshold`
  es 1 MiB, así que esos archivos se leen con `F_NOCACHE` y **saltan el page cache**: `purge` no cambia nada para
  ellos. Confirmado empíricamente sobre el corpus real, que sí tiene muchos archivos chicos y cacheables:
  **2,300 MB/s en frío contra 2,350 caliente**, o sea 2%. El barrido en frío que este archivo pedía no podía
  arrojar otra cosa.
- **Un benchmark de una sola corrida por punto produjo una afirmación falsa que vivió aquí semanas.** El ruido de
  disco es siempre hacia abajo —nada hace que un disco lea más rápido de lo que puede—, así que la corrida más
  rápida es la menos contaminada y promediar mezcla señal con interferencia. Mejor de tres, como en la línea base
  de video.
- **RSS pico entre 21.7 y 54.8 MB**, contra el objetivo de < 400 MB. Sobra un orden de magnitud.
- **La etapa de prefijo, por fin medida sobre el caso que existe para atender.** 80 archivos de 64 MiB del mismo
  tamaño con colas distintas: con la sonda **0 B leídos y 0.03 s**; sin ella **5.0 GB y 1.75 s**. **58×.** Y el
  contador no cuenta los 16 KiB por archivo que la sonda sí lee (1.25 MB en total), así que ese "0 B" es del
  hasher completo, no del disco.
- **Un archivo grande tenía la cancelación de rehén.** `ContentHasher.fullDigest` no revisaba nada, así que el
  "detenido en menos de 300 ms" del plan valía solo para bibliotecas de archivos chicos —justo las que no importa
  detener—. Ahora revisa `Task.isCancelled` **entre chunks**, así que el límite es una lectura de 1 MiB. Funciona en
  código síncrono, y fuera de una tarea es `false`, o sea que un test o el selftest leen cada byte como antes.
- **Guardar es lo último que pasa en un escaneo, y una falla al guardar se reporta, no se lanza.** Un
  escaneo de 800,000 archivos que terminó bien no se puede tirar porque el directorio de estado estaba
  de solo lectura: quien llama todavía puede revisarlo en memoria. Lanzar convertiría un problema
  recuperable en veinte minutos perdidos.
- **Un escaneo cancelado no escribe nada**, porque el save va después de que el finder regresa. Los
  appends de la caché de hashes **sí se conservan**: son hechos verdaderos, y tirarlos haría pagar el
  precio completo otra vez.
- **`ScanSession.run` toma un `Date` y resuelve el instante adentro.** Una versión anterior daba un
  identificador por un método y tomaba un instante por otro, lo que dejaba deduplicar uno y guardar bajo
  el otro — el identificador decide el nombre del archivo y el instante decide lo que va estampado
  adentro, y tienen que salir del mismo valor.
- **La caché de hashes vive en `~/Library/Caches`, nunca en el state dir compartido.** Son dos clases
  de dato: un scan es formato de interop que el CLI lee y no se puede perder; la caché es dato
  derivado que macOS puede purgar bajo presión de disco, que es la semántica que se quiere.
- **La regla de compactación por filas muertas era imposible de disparar, y está medido.** Una fila queda
  superseded solo si la misma clave se escribe con otro digest — y la clave carga tamaño, mtime y generation, así
  que un archivo con contenido nuevo produce una clave **nueva** en vez de matar la vieja. En las dos cachés
  reales de esta máquina: `hashes.v1` tiene 6,661 filas y 6,661 claves distintas, `phashes.v1` tiene 3,396 y
  3,396. **Razón exactamente 1.0000 tras 119 escaneos.** El test que ejercitaba la regla tenía que escribir diez
  digests bajo una clave, o sea fabricar un estado que producción no alcanza.

  Lo que sí es alcanzable es basura: una cola parcial de un crash a media escritura, y una fila con CRC roto.
  Esas se releen y se descartan en **cada** carga, para siempre. Ese es el disparador de la reescritura, y ahora
  producción la llama: `loadAndRepair()` en las cuatro sesiones que abren una caché.
- **Un archivo que este build no puede leer se deja quieto, no se pisa.** Magic o versión desconocidos pueden ser
  de un build **más nuevo**; reescribirlo le costaría su caché a ese build para no ganar nada, porque las filas se
  ignoran igual. Por eso `discardedFile` no dispara la reescritura y `hadTornTail`/`corruptRecords` sí.
- **La caché perceptual no tenía `flock` y la de digests sí**, lo cual era una inconsistencia y no una decisión:
  dos procesos agregando filas de 112 bytes al mismo archivo las intercalan, y un CRC puede decir que una fila
  está rota sin poder decir cuáles dos escritores la hicieron. Ya lo tiene, con la misma degradación a solo
  lectura: el que pierde el lock sirve todos sus hits y no escribe.
- **El lock se sostiene mientras el objeto vive, y eso rompió tres tests y un arnés.** Dos instancias vivas sobre
  el mismo archivo son un perdedor de lock, no dos pipelines: en producción cada sesión crea su caché dentro de
  `run()` y la suelta al volver, pero un test que deja la primera en scope hace que la segunda salga read-only y
  —correctamente— se niegue a escribir. Los tests van con `do { }` por instancia y el modo `cache` usa su propio
  archivo para el chequeo de reparación.
- **El `mtime` de la clave y el de `stat` no son la misma cantidad, y compararlos habría borrado la caché
  entera.** `modifiedNanoseconds` sale de `contentModificationDate`, que es un `Date` —un `Double` cuya
  granularidad cerca de 1.79e18 nanosegundos son cientos de nanosegundos—, mientras `stat` da un `st_mtimespec`
  exacto. La primera versión de la poda comparaba los dos y clasificaba **cada fila viva como superseded**: el
  diente lo imprime como `0 rows survived the prune, wanted the 4 live ones`. El **tamaño** sí es entero en los
  dos lados y es lo único que se compara.

  Y de paso: esa misma comparación infló la primera medición de 55.8% a 79.2% de desperdicio. Las 1,812 filas
  "superseded" eran **enteramente** el artefacto.
- **Un identificador de volumen plegado puede significar varios `st_dev`.** macOS hace firmlink del volumen de
  arranque: `/` y `/private/tmp` reportan el **mismo** identificador de volumen desde dispositivos distintos. Un
  mapa con un dispositivo por identificador busca un inodo del volumen de datos bajo el del sistema, no encuentra
  nada, y llama muerta a la fila. El mapa se construye con `getmntinfo` y guarda una **lista**.
- **Solo `ENOENT` prueba que un archivo se fue.** Cualquier otro errno es este proceso sin poder mirar: revocar el
  acceso al Escritorio hace que cada fila de un archivo de ahí deje de resolver, y esos archivos nunca se
  movieron. Medido hoy: 0 filas irresolubles, y la distinción está puesta antes de que haga falta.
- **La caché perceptual real tiene 0% de desperdicio, y aun así se poda.** Sus 3,396 filas describen archivos que
  existen: una biblioteca de fotos rota mucho más despacio que los árboles temporales que habían dejado la caché de
  digests con 55.8% de peso muerto. Lo que sigue siendo cierto es que crece una fila por (archivo, versión) y no
  recupera ninguna, así que la poda se construye por **el límite, no por el reclamo** — y el mecanismo es el mismo,
  o sea que no agrega riesgo.
- **Y la poda de digests ya se vio funcionar sobre datos reales**: la caché del usuario pasó de 7,741 filas con
  55.8% de desperdicio a 3,481 con 1.7%, sola, en cuanto un modo abrió la caché default. Eso es la única evidencia
  de producción que este proyecto va a tener de esa regla, así que queda escrita.
- **La clasificación de liveness es una sola función para las dos cachés.** Dos copias serían dos oportunidades de
  discrepar sobre si una fila está muerta, y una de esas respuestas la borra — el mismo argumento que colapsó los
  dos constructores de manifiesto en uno.
- **La caché de digests real tenía 55.8% de desperdicio**: 7,741 filas, 3,421 describiendo un archivo que existe,
  4,320 con el archivo borrado. El issue #75 preguntaba si valía la pena podar; ese número dijo que sí. La poda
  cuesta un lookup de inodo por fila —3.4 µs medidos, 26 ms sobre 7,741, ~340 ms sobre cien mil— así que no se
  paga en cada carga: el header recuerda cuántas filas había en la última limpieza, en sus 8 bytes de padding, y
  un build viejo lo ignora.
- **La clave de la caché incluye `generation`, no solo mtime.** Verificado en APFS: avanza con un
  append, con una reescritura del mismo largo, y con contenido distinto y mtime forzado atrás con
  `utimes` — el caso `rsync -t` que una caché por mtime sirve rancio. `URL` cachea resource values,
  así que hay que leerlo con un `URL` fresco o no se ve el cambio.
- **Corregir el tamaño de un `FileEntry` reconstruyéndolo desde cero tira identidad, generation y
  mtime.** Con eso la clave de caché sale nil, `store` no hace nada, y **cada escaneo se ve como una
  máquina fría** en vez de como un bug. Usar `withSize`. Lo atrapó el test de escaneo caliente.
