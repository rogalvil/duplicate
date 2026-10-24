---
paths:
  - "Sources/DuplicateCore/Media/**"
  - "Sources/DuplicateCore/Action/SimilarApplyRunner.swift"
  - "Sources/Duplicate/Similar*.swift"
  - "scripts/phash-reference.py"
---

# Detector perceptual: imagen y video

Se carga sola al tocar los archivos de arriba. Viene de `CLAUDE.md`, tal cual.

- **Pillow redondea al convertir a grises, no trunca.** Medido sobre diez triples:
  `(19595·R + 38470·G + 7471·B + 0x8000) >> 16` acierta los diez y la forma truncada falla tres — `(0,255,0)`
  da 149 contra 150. El plan decía lo contrario.
- **El DCT del hash perceptual tiene que cancelar exacto, y solo el de Accelerate lo hace.** Una imagen plana
  debe dar un coeficiente y 63 ceros; con la matriz de la base quedan ~1e-3 de signo mezclado, la mediana cae
  entre ellos y prenden **32 bits en vez de 1**. No es precisión: una FFT resta valores iguales y da cero
  exacto, una suma de 32 cosenos que cancela matemáticamente no lo hace a ninguna precisión. Por eso también se
  **cuantiza a `UInt8` después del resample**, o el ringing de Lanczos deja la región plana en `255 ± 1e-3` y
  vuelve el volado. Y por eso los frames negros de dos videos distintos dan el mismo hash, que es de lo que
  depende el agrupamiento del camino de video. Cuantizar además *entre* las dos pasadas de Lanczos, como hace
  Pillow, **se midió y empeora** (89.97% contra 90.88%).
- **El setup de `vDSP.DCT` cuesta 1 µs**, no lo que el plan supuso: 1,000 setups de tamaño 32 en 1.0 ms. No hay
  que reusarlo por worker, y así el tipo se queda siendo un valor sin discusión de `Sendable`. Su método es
  `transform(_:result:)`, no `output:`.
- **La similitud de un video no es una distancia de bits.** Es la fracción de cuadros muestreados que
  coinciden, así que imprimir "difieren 0 de 64 bits" bajo un par de video —lo que salió— afirma una medición
  que nunca se hizo. El encabezado cambia de texto según `media_type`.
- **La detección de tráiler va antes que la calidad, y el orden es lo que la hace correcta.** Un tráiler de 30 s
  en HEVC a alto bitrate **le gana en puntuación** a la película de dos horas en H.264 que anuncia, así que una
  cadena que preguntara calidad primero conservaría el tráiler y borraría la película. Hay test con esa inversión
  medida en el fixture.
- **Un codec desconocido vale 1.0 *y se marca*.** El `.get(codec, 1.0)` del CLI lo trata como H.264 en silencio,
  que es una adivinanza capaz de entregarle la decisión al archivo equivocado. Se conserva el número por paridad
  y se agrega la bandera.
- **Un escaneo perceptual NO guarda ningún digest**, así que "verificar antes de actuar" no puede ser "¿son los
  bytes que vio el escaneo?". Lo que sí se puede re-chequear es la afirmación sobre la que se decidió: **estos dos
  se parecen**. Se re-hashean los dos archivos y se vuelve a puntuar el par contra el umbral del escaneo; una foto
  editada desde entonces, o un archivo reemplazado en la misma ruta, se rehúsa. Cuesta un decode de dos archivos
  (~7 ms imagen, ~300 ms video) y solo se paga por los que se van a borrar.
- **Si el contraparte no está, no se mueve nada.** Sin el otro lado no se puede re-chequear la afirmación, y mover
  sobre una afirmación no verificable es justo lo que esa verificación existe para evitar.
- **El digest del journal se calcula al mover, no se recuerda del escaneo** — es el único que hay. Y si no se puede
  calcular, **el archivo no se mueve**: una entrada con un digest inventado dejaría que un undo "verifique" un
  archivo restaurado contra nada, que es peor que negarse a borrar.
- **El bitrate ya se mostraba y escribí un issue diciendo que no.** Vive dentro de la frase del consejo
  (`SimilarAdviceText.swift:66`) y `MediaAdvice` solo lo emite cuando los dos son conocidos y distintos — que es
  exactamente la política de "mostrarlo cuando decide" que el issue proponía. Antes de abrir un issue sobre algo
  que falta, buscarlo.
- **Las facts de media se piden por par, no por escaneo.** Probar los 2,460 archivos de un escaneo real antes de
  dibujar la ventana repetiría buena parte del escaneo; se piden para el par que se está viendo, con un contador
  de generación que tira la respuesta que llega después de que la selección se movió.
- **El guard de `frames > 0` en el encabezado de video no es paranoia.** Las facts llegan por sonda asíncrona, así
  que antes de que responda la duración es nil: sin el guard, un par recién seleccionado anuncia "juzgado con 0 de
  8 cuadros". El diente lo destapa.
- **La caché perceptual es la diferencia entre 177 s y 0.5 s**, medido sobre el árbol real de 2,779 imágenes y
  617 videos: **354×**, con el mismo resultado (4,771 pares las dos veces). No es optimización — un video son
  ocho decodes, así que sin caché un segundo escaneo del mismo árbol paga todo otra vez.
- **Su salt se deriva de los parámetros del pipeline, no de una constante que hay que acordarse de subir.**
  Cambiar el decode de 256 a 512 invalida cada hash guardado; con un número a mano eso se olvida exactamente una
  vez y después la caché sirve números que significan otra cosa. La constante sigue existiendo para lo que los
  parámetros no ven (la fórmula de grises, los pesos del resampler), o sea que hacen falta las dos mitades.
- **Las filas son de tamaño fijo con ocho huecos, aunque una imagen use uno.** Se desperdician 56 bytes por
  imagen —156 KB sobre 2,779, contra un escaneo de 177 s— y a cambio `(tamaño - header) % fila != 0` sigue
  detectando una cola truncada, que es toda la historia de recuperación tras un crash. Medido: el archivo de
  3,396 archivos pesa exactamente 32 + 3,396 × 112 = 380,384 bytes.
- **La caché verifica el *tipo*, no solo la clave.** Un inodo reusado por un archivo del otro tipo serviría ocho
  cuadros como si fueran una imagen.
- **El LSH no aplica al video.** Indexa hashes sueltos; el video compara *listas* con una regla codiciosa y
  asimétrica. Así que los videos se comparan por pares como en el CLI — 617 videos son 190,036 pares — y sale
  barato porque cada comparación son popcounts. Lo caro es hashear.
- **Cuatro decodes de video a la vez, medido, no elegido**: 60 videos reales dieron 213 ms cada uno en serie,
  151 ms con cuatro, y **151 ms con ocho**. `AVAssetImageGenerator` ya paraleliza adentro; más workers solo
  suben la memoria.
- **Una marca de tiempo pasada del final NO devuelve nada en `ffmpeg` y SÍ devuelve algo aquí.** Con tolerancia
  de un segundo, `AVAssetImageGenerator` contesta con el cuadro más cercano: un clip de 0.4 s volvió con **ocho
  hashes**, el último cuadro repetido cuatro veces, donde el CLI hashea cuatro. Eso cambia en silencio la
  fracción de cuadros a la que se aplica el 0.70, así que las marcas pasadas del final se filtran antes de
  pedirlas. Medido, no previsto.
- **La aritmética de muestreo de video se preserva exacta, y no es pedantería.** `interval = max(dur/(n+1), 0.1)`
  y cuadros en `interval·(i+1)`: el umbral de 0.70 se calibró contra *ese* muestreo, así que muestrear distinto
  cambia en silencio lo que el umbral significa mientras cada número en pantalla conserva su nombre. El `n+1`
  es lo que mantiene las muestras lejos de los dos extremos, que es donde un video suele estar negro. Y en un
  clip corto **algunas marcas caen pasado el final** —a medio segundo, cuatro de ocho— y eso también se
  preserva: el CLI hashea las que sí y compara sobre menos cuadros.
- **Y ahora está medido, porque "además es más rápido" era un eslogan.** Contra los dos comandos exactos del CLI,
  sobre el mismo archivo concatenado a tres tamaños:

  | archivo | duración | ffmpeg rápida (N llamadas, `-ss` antes de `-i`) | ffmpeg lenta (una llamada, filtro `fps`) | esta app |
  |---|---|---|---|---|
  | 10.7 MB | 29 s | 1.451 s | **0.446 s** | 0.617 s |
  | 211.7 MB | 581 s | 1.497 s | 6.575 s | **0.621 s** |
  | 1,058.7 MB | 2,904 s | 1.488 s | 33.584 s | **0.611 s** |

  **El costo de esta app es plano**: ~0.62 s a 10 MB, a 212 MB y a 1 GB, porque la tolerancia lo vuelve ocho
  saltos a keyframe sin importar el largo. La rama rápida de ffmpeg también es plana y **2.4× más lenta**, y lo
  que la domina son los ocho `fork`+`exec`. La rama lenta escala con la duración: a 1 GB es **55× más lenta**.
- **Pero para un archivo chico y corto, la llamada única de ffmpeg nos gana 1.4×** (0.446 s contra 0.617 s). El
  eslogan no es universal y ahora la excepción tiene número.
- **El umbral de 200 MB del CLI está sobre la cantidad equivocada.** Lo que hace caro a la rama lenta es la
  **duración**, no los bytes: un archivo de 190 MB y diez minutos se queda debajo del umbral y paga ~6 s. Bien
  comprimido y largo es justo el caso que peor le sale.
- **La tolerancia le importa mucho menos a AVFoundation que la posición de `-ss` a ffmpeg.** Seek exacto contra
  ±1 s: **1.14×–1.18×** en los tres tamaños, contra el 3×–55× que separa las dos ramas de ffmpeg.
- **Sin calentamiento, la primera medición mintió al revés.** La primera corrida del proceso paga el setup de
  AVFoundation, y la tolerancia que iba primero cargaba con él: seek exacto salía **23% más rápido** que la
  tolerancia enviada, lo opuesto a lo que dice una segunda corrida. El modo hace una pasada de calentamiento y
  toma el mejor de tres.
- **Toda la rama de fast-seek del CLI colapsa en `requestedTimeTolerance`.** El split por 200 MB existe porque
  `ffmpeg -ss` antes de `-i` busca barato al sync sample y después de `-i` decodifica hacia adelante; esa
  propiedad **es** la tolerancia. Y la tolerancia laxa es además la respuesta *mejor*: dos copias del mismo
  archivo caen en el mismo keyframe, y un re-encode con otro GOP cae distinto — justo la variación que el 0.70
  existe para absorber.
- **`video_similarity` es asimétrica y su `break` codicioso infla.** Ocho cuadros de una escena quieta contra un
  clip de un cuadro de la misma escena dan **1.0 en un sentido y 0.125 en el otro**, y un solo cuadro de B
  puede ser la pareja de todos los de A. Se preserva —el umbral se calibró contra eso— pero **cuál lado se
  recorre se fija por bytes**, o el resultado dependería del orden de `os.walk` y el mismo par podría caer de
  los dos lados del umbral entre corridas.
- **El video depende de que un cuadro plano hashee determinista.** Es la razón de fondo de la cuantización tras
  el resample: sin ella, dos cuadros negros de videos distintos darían ruido distinto y el ratio de cuadros
  compararía números ajenos.
- **Los fixtures de video son H.264 baseline y fallan ruidosamente.** Un runner `macos-15` es una VM y puede no
  tener encoder HEVC. Si ni H.264 hay, `SyntheticMovie.write` lanza: una prueba de video que pasa porque no
  hasheó nada es peor que una que falla.
- **Un escaneo perceptual de esta app no trae pares de video**, y eso cambia lo que encuentra. Se reporta en
  `scannedKinds` y el resumen separa los conteos de imagen y de video para que un total no lo esconda.
- **El índice LSH necesita `T + 1` bandas, no `T`.** Es la cota de palomar: con `T` bandas, `T` bits que
  difieren pueden tocar todas, y no queda ninguna idéntica que garantice el encuentro. Medido: bajarlo a `T`
  hace que **6 de 12 semillas pierdan pares** en el test de superconjunto. Y colapsar los hashes idénticos en
  clases antes de indexar no es una optimización de caso raro: **2,779 fotos reales dan 1,630 clases**.
- **Un pHash solo mira las ocho frecuencias más bajas**, así que un tablero de 8 px en una imagen de 128 hashea
  igual que un gris plano — `imagehash` también. No es bug; hay un test que lo fija con su razón, porque la
  alternativa es redescubrirlo como reporte de bug.
- **El tamaño de decode se barrió y 256 está en la meseta.** De 128 a 4096 los pares encontrados no se mueven
  (0.1% de rango); lo que cambia es la coincidencia con Python. Pedirle 32 px a ImageIO es un desastre (10.9%
  idéntico) porque a ese tamaño devuelve su reducción más barata. El Jaccard ≥0.98 que pedía el plan **solo se
  alcanza con decode completo**, a 2.65× el tiempo, y no compra mejores respuestas.
- **Las dos métricas obvias del diferencial contra `imagehash` son ciegas al error que importa.** Quitar el
  `+ 0x8000` de la conversión a grises —la fórmula truncada que el plan especificó mal— deja **88.0% de hashes
  idénticos y un peor caso de 4 bits**, o sea que una tasa de coincidencia y una distancia máxima las dos pasan.
  Lo que sí lo atrapa son **6 pares que una implementación llama casi idénticos (≤2 bits) y la otra ajenos
  (>5 bits)**: esa es la discrepancia que movería un archivo. Por eso el modo `phash-differential` afirma sobre
  los flips de clase y no solo sobre promedios.
- **El diferencial contra `imagehash` lee un archivo de referencia, no lanza Python.** Un subproceso desde el
  bundle firmado no es reproducible y no se puede diffear; la referencia sí, y su rancidez se maneja grabando
  cada ruta —un corpus con un archivo más falla en vez de comparar de menos.
- **Las únicas divergencias sistemáticas contra `imagehash` son las 16 imágenes con rotación EXIF**, de 2,779.
  Nosotros aplicamos la orientación y Pillow no: una copia que solo difiere en el flag debería coincidir con su
  original. Sin ellas el peor caso es de 4 bits.
