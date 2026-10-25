---
paths:
  - "Sources/Duplicate/SelfTest.swift"
  - "Tests/**"
  - "Makefile"
  - "Package.swift"
  - ".github/**"
  - "scripts/**"
  - "Resources/Info.plist"
---

# Selftest, tests, build y CI

Se carga sola al tocar los archivos de arriba. Viene de `CLAUDE.md`, tal cual.

- **`git diff --quiet` ignora los archivos sin trackear**, así que un árbol lleno de fuentes nuevas
  reporta limpio y el build diría ser exactamente el commit nombrado. El Makefile usa
  `git status --porcelain`.
- **Un fixture "parecido" puede salir byte-idéntico y cambiar el conteo exacto.** El par con `||` en el nombre
  guardaba la misma imagen a la misma calidad, así que el detector exacto pasó de 7 a 9 grupos y rompió los
  pasos que dependen de un escaneo chico. Un fixture nuevo se mide contra los tres detectores, no solo contra el
  que se quería ejercitar.
- **Un `sed`/`replace` con conteo 1 sobre `SelfTest.swift` toca la ocurrencia equivocada.** Probando el diente
  anterior parcheé `mechanism: outcome.mechanism` y el modo siguió verde: había tres ocurrencias y la primera
  estaba en otro modo, 4,000 líneas antes. Un diente que no muerde puede ser un diente mal puesto.
- **Afirmar sobre el texto de una hoja no prueba la compuerta.** La primera versión del arnés revisaba el titular
  y la lista, y **pasaba con `flow.advance(.dryRun,…)` quitado**: la negativa solo ocurre al presionar el botón, y
  el arnés no lo presionaba. Presionarlo ahí movería archivos de verdad, que es lo que el modo `similar-apply` ya
  hace con limpieza, así que la hoja expone si la compuerta la autorizaría **sin aplicar**.
- **Un test que usa un ayudante para afirmar una propiedad esconde la propiedad.** Los dos tests de la asimetría
  de video llamaban a `directionsDisagree`; ahora comparan los dos números contra el ratio, que dice lo mismo y
  se lee sin ir a buscar otra función.
- **Dos fixtures míos no probaban nada, y las dos fallas son instructivas.** En c1-prefix escribí las 40
  izquierdas idénticas entre sí, así que la sonda partía en dos clases y cada archivo seguía necesitando hash
  completo: 5 GB con sonda y sin ella. Cada archivo necesita **cola única**. Y en c1-scale usé
  `bytes([index & 0xFF]) * size`, que repite contenido cada 256 archivos: salieron 31,705 grupos en vez del 12%
  pedido, lo que además infló la medición de memoria.
- **Y un selftest que escribe el dominio real de `UserDefaults` hace lo mismo, peor.** Pasó al probar los dientes
  del toggle de metadata: el modo falló a propósito con la preferencia en `false`, quedó persistida, y desde ahí
  **otro** modo empezó a fallar con "the detail line is hidden by default" —una falla apuntando a código inocente—.
  `MetadataPreference.defaults` se inyecta y el arnés apunta a una suite desechable que borra al terminar. Dos
  corridas seguidas de `--mode all` dan 39 OK y no dejan la clave en el dominio real.
- **Un selftest que usa un default de `~/Library/Caches` contamina la siguiente corrida.** Pasó: la foto
  de una corrida anterior hizo que un chequeo de dientes fallara en la aserción equivocada. El directorio
  se inyecta y el modo apunta a `/tmp`.
- **Un selftest que lee texto de celdas no ve un problema de layout.** Los modos pasaban con el bug
  enviado. Que una ventana muestre lo correcto y sea inusable son cosas distintas.
- **Probar cancelación necesita trabajo que no pueda terminar solo.** Cancelar antes de que empiece no prueba
  nada: el `Task` lanza en su primer punto de suspensión, así que el modo pasaba con **todos** los
  `checkCancellation` quitados. Y esperar a que el hasheo avance tampoco alcanza: con 400 archivos chicos el
  escaneo **termina entre el sondeo y el cancel** — pasó local y **falló en CI**, que es una carrera disfrazada de
  prueba. La cura es un hasher que envuelve al real y duerme 3 ms por archivo: con dos segundos de trabajo por
  delante, "se detuvo" y "se detuvo en menos de 300 ms" las dos significan algo.
- **Un arnés que llama él mismo a la función arreglada no tiene dientes.** La primera versión de esa
  aserción invocaba `reloadFromDisk()` y luego afirmaba: pasaba con el arreglo quitado, porque probaba que
  la función sirve y no que algo la llame. Hay que manejar el camino de producción — el botón de la hoja —
  y no tocar nada más.
- **Un test de cancelación con `sleep` es una carrera disfrazada.** La primera versión dormía 120 ms sobre 600 ms de
  hasheo: pasó sola y **falló dentro de la suite completa**, donde la carga de la máquina mueve las dos cosas. La
  versión determinista es un hasher que cancela su propia tarea en su décima llamada —siempre dentro del primer
  manifiesto de una carpeta de cien archivos, y corre en 43 ms.
- **Afirmar sobre la etiqueta después de un apply de dos archivos es una carrera.** La escribe un `Timer` a 10 Hz y
  dos archivos se mueven en menos de un tick. Lo que sí se afirma es determinista: que la línea arranca oculta, y
  que el renderizador da **tres frases distintas** para las tres etapas y **nada** para `done`.
- **Un modo de selftest no abre el panel de Quick Look.** `QLPreviewPanel` es una ventana **compartida del
  sistema**: abrirla la dejaría en pantalla para el siguiente modo, que además afirmaría sobre una ventana que no
  es suya. Se afirma la lista de rutas que el panel recibiría.
- **Cuántos pasos de ⌘Z se pueden dar es propiedad del run loop, no del código.** Un arnés que llama dos hooks
  seguidos no son dos eventos, así que afirmar "dos undos" ahí prueba el agrupamiento del arnés. Lo que sí se puede
  afirmar: que algo quedó registrado, que deshacer cambia el estado, y que **el archivo deja de tener la decisión que
  la ventana ya no muestra** — porque estas revisiones guardan al decidir, así que un undo que solo toque memoria
  dejaría al CLI leyendo lo contrario.
- **`CFBundleVersion` es el número de build, no la versión de marketing.** El Makefile lo pone en
  `git rev-list --count HEAD`: monotónico, nunca se reinicia, y distingue dos builds de 0.1.0 — que
  es lo que le importa a Launch Services, a los crash reports y a quien lea un reporte de bug. El
  app hermano usa la misma cadena para los dos campos; aquí no.
- **El icono se dibuja con `scripts/make-app-icon.swift` y el `.icns` se commitea**, para que un
  build normal no pague el render. Verificarlo es visual y no hay manera de evitarlo:
  `iconutil -c iconset Resources/AppIcon.icns` y mirar el PNG de 16×16. Ningún número dice si dos
  cuadrados encimados siguen leyéndose como dos a ese tamaño.
- **Los selftests van antes del paso de cobertura en CI.** `swift test --enable-code-coverage`
  recompila el debug con instrumentación, así que correrlos después paga un tercer build completo. Y
  van con `CONFIG=debug`: `make selftest` depende de `make all`, que compilaría en release.
- **CI corre solo en pull requests**, nunca en push. La razón original fue el costo —los runners de macOS
  facturan 10×— cuando el repo era privado; **ya es público**, así que el minuto es gratis y lo que queda es
  que un push no aporta señal que el PR no dé. Cubre bases `main`, `feat/**` y `fix/**`, y el tipo de evento
  `edited`, porque sin eso un PR apilado no reporta checks y puede llegar a `main` sin haberse probado nunca.
- **Público no significa que alguien más pueda aterrizar un cambio.** Nadie externo tiene permiso de escritura,
  así que un PR de fuera se puede abrir pero no mergear: el botón es del dueño. Lo que sí hacía falta cerrar era
  el CI — la política de aprobación estaba en `first_time_contributors`, o sea que el **segundo** PR de alguien
  corría workflows solo. Ahora es `all_external_contributors`.
- **La aprobación obligatoria vive en un ruleset aparte, con el admin exento.** Contra alguien de fuera no agrega
  nada —no puede mergear—, pero un colaborador futuro con escritura sí podría mergear sin revisión. En el ruleset
  `protect main` habría bloqueado al dueño, que no puede aprobar su propio PR, y eximirlo ahí lo habría eximido
  también del CI. Separado, el dueño solo se salta la aprobación.
