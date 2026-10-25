---
paths:
  - "Sources/DuplicateCore/Walk/**"
  - "Sources/DuplicateCore/Support/**"
  - "Sources/Duplicate/ScanPanelController.swift"
  - "Sources/Duplicate/DescriptorLimit.swift"
  - "Sources/Duplicate/main.swift"
---

# Recorrido, TCC y directorio de estado

Se carga sola al tocar los archivos de arriba. Viene de `CLAUDE.md`, tal cual.

- **`URL.appending(path:directoryHint: .isDirectory)` agrega slash final, y
  `FileManager.fileExists(atPath:)` nunca matchea una ruta con slash final contra un archivo
  regular.** Un archivo sentado donde va un directorio se lee como "aquí no hay nada", y el error
  real aparece después, en otro lugar, sin mencionar la colisión. Por eso `StateDirectory` guarda
  rutas como `String` y arma los `URL` con `.notDirectory`. Los tests de esta suite encontraron
  exactamente ese bug.
- **`URL(filePath:)` resuelve una ruta relativa contra el directorio de trabajo.** Un
  `XDG_STATE_HOME` relativo se volvería absoluto en silencio y no habría forma de detectarlo. Launch
  Services arranca la app con `/` como directorio de trabajo.
- **`os.environ.get` de Python devuelve `""` para una variable puesta pero vacía, y `""` es falsy.**
  Un `XDG_STATE_HOME` vacío hace que el CLI caiga a `~/.local/state`. En Swift `""` es truthy, así
  que una traducción literal resuelve la raíz a `/rav` y deja de ver todos los scans existentes —
  reportando éxito.
- **El `errorHandler` de `FileManager.enumerator` no hace lo que dice la documentación.** Foundation
  documenta que devolver `false` detiene la enumeración. **Medido en este SDK, no la detiene**: un
  EACCES sobre un subdirectorio da la misma lista de archivos con `true`, con `false`, y sin handler.
  Se devuelve `true` porque es el contrato documentado y no cuesta nada, no porque se haya observado
  que cambie algo.

  Lo que sí compra el handler es lo único que la app puede reportar: con `errorHandler: nil` el
  recorrido devuelve los mismos archivos y quien llama no se entera de nada — ni conteo, ni ruta, ni
  señal. Ahí "no se encontraron duplicados" es indistinguible de "no pude entrar a 47 directorios
  protegidos". Esto se descubrió porque el arnés **no falló** al invertir el retorno; la regla de
  probar los dientes es lo que lo destapó.
- **Elegir la carpeta en `NSOpenPanel` *es* el consentimiento, así que Escritorio y Documentos no disparan
  diálogo.** Medido con la app lanzada por Launch Services: no pregunta, lee los 15 archivos de un árbol en el
  Escritorio, y **no aparece en Ajustes → Privacidad → Archivos y carpetas** — las tres cosas consistentes entre
  sí. El comentario de `chooseRoot` ya lo decía y la primera versión de la pasada a mano afirmaba lo contrario.
  Y no es porque el usuario sea administrador: TCC es una capa aparte de los permisos POSIX, y ni `sudo` la evita.
- **Y las raíces recientes tampoco muerden**: medido, escanear la misma carpeta del Escritorio desde recientes,
  tras cerrar la app por completo, da los mismos 5 grupos sin preguntar. El consentimiento del panel persiste
  para esa ruta. `open` además entrega la app a Launch Services de verdad —el padre del proceso es `launchd`,
  no la terminal—, así que no está heredando permisos de nadie.
- **En uso normal la superficie de TCC de esta app es casi inalcanzable, y es de diseño.** La raíz siempre sale
  del panel o de recientes, así que nunca hay una carpeta protegida a la que se llegue sin que alguien la haya
  señalado. Lo único que queda expuesto es elegir una carpeta **que contenga** una protegida.
- **Y eso se corrió por fin, sobre `~` completo: 1,332,341 archivos, 91.3 GB, 1,050 s de hasheo.** El resultado
  es el bueno — **142 carpetas saltadas y el banner diciéndolo**, con su conteo y con la advertencia de que un
  permiso otorgado ahora no aplica al proceso corriendo. El fallo de mayor consecuencia, "0 archivos y ningún
  aviso", **no ocurrió**: el `errorHandler` cuenta, el conteo llega, y el texto dice que el resultado está
  incompleto.
- **Pero "casi inalcanzable" no aguantó la medición.** Escanear la carpeta de inicio disparó **ocho** diálogos
  de TCC, y sólo tres —Escritorio, Documentos, Descargas— son los que `Info.plist` declara y salen con su
  explicación. Los otros cinco salen **sin una palabra**: iCloud Drive, Google Drive, datos de otras apps,
  fototeca y biblioteca multimedia. Los tres primeros viven bajo `~/Library`.
- **Y la causa de fondo era que `~/Library` no se excluía, aunque este archivo y el README lo afirmaran los
  dos.** No había una línea de código que lo hiciera: `ExclusionSet.forScan` resolvía la Papelera, la cuarentena
  y cuatro nombres de raíz de volumen, y nada más. Por eso el escaneo leyó 91 GB de cachés de navegador y por eso
  aparecieron cinco de esos diálogos. Una capacidad afirmada en dos documentos y ausente del código, encontrada
  por la única corrida que podía encontrarla.
- **Ya se excluye, y con una excepción: cuando la raíz está dentro de `~/Library`.** Ahí alguien la señaló a
  propósito, y excluirla sería un escaneo que no escanea nada. La igualdad cuenta —elegir `~/Library` misma es
  tan deliberado como elegir algo adentro—. Va como ruta y no como poda posterior, para que pase por la misma
  resolución a identidad que la Papelera: una `~/Library` alcanzada por firmlink o symlink es el mismo
  directorio y se poda bajo cualquier nombre que llegue a ella.
- **TCC atribuye el permiso al proceso responsable, no al binario.** Lanzada desde la terminal, la
  app hereda los permisos de la terminal; lanzada por Launch Services es su propio responsable.
  Consecuencia: **un selftest verde no dice nada sobre el estado de TCC de la app.** Reportar los dos
  caminos por separado.
- **Y corridos los dos, dieron lo mismo — lo cual no prueba lo que parece.** El árbol de demo vive en `~`, que
  no es un directorio protegido, así que ninguno de los dos caminos tiene permiso que pedir: 7 grupos y ningún
  diálogo por Launch Services y desde la terminal. La diferencia que la comparación existe para exponer sólo
  aparece sobre una carpeta protegida. Un experimento cuyos dos brazos no pueden diferir no falsa nada.
- **Un diálogo de permisos que no dice el nombre de la app puede no ser de esta app.** Salió uno atribuido a
  "2.1.263" a media corrida y parecía que el bundle se identificaba con un número de versión; el `Info.plist`
  armado declara `CFBundleName` y `CFBundleDisplayName` como `Duplicate`, y el diálogo del Escritorio que sí era
  nuestro salió con su nombre y su explicación. Era otra app. Antes de escribir el issue, leer el plist del
  bundle.
- **No había un solo `autoreleasepool` en el proyecto, y el walk lo necesitaba.** `nextObject()` y
  `resourceValues` devuelven objetos autoreleased, y un loop síncrono que nunca vuelve a un run loop no libera
  ninguno. Medido sobre 200,000 archivos sintéticos: **298 MB de RSS pico, ~1.4 KB por archivo**, contra los ~146
  bytes que estimaba el plan. Drenando por lotes de 512: **172 MB**, 42% menos. El corpus real son 71,580
  archivos, y por eso nunca se vio — se quedaba debajo del objetivo por ser chico.
- **Y con eso el objetivo del plan sigue sin cumplirse.** 172 MB a 200,000 archivos extrapolaban a ~570 MB a
  800,000, contra el objetivo de < 400 MB. Lo que queda es la `FileTable` y el documento del escaneo, no basura
  autoreleased.
- **El 172 no se reproduce, y no es regresión (#161).** Medido otra vez: 219 MB a 200,000, 352 MB a 400,000 y
  657–714 MB a 800,000. El mismo commit que midió 172 (`a050021`), compilado hoy y alternado con `main`, da 219.
  Un número de memoria se vuelve a medir con el commit que lo produjo antes de llamar regresión a la diferencia.
- **Launch Services arranca la app con `RLIMIT_NOFILE` blando en 256.** Quedarse sin descriptores no
  truena: sale como archivo ilegible, se cuenta como candidato saltado, y **el escaneo encuentra menos
  de lo que debía** — una falla que se ve como una respuesta más chica, no como un error. `main.swift`
  lo sube a 4096 antes de que nada abra un archivo.
- **Desde una terminal el límite blando ya viene en millones** (medido: 1048576), así que un arnés que
  solo mire el valor actual pasa exista o no el `setrlimit`. El modo `fdlimit` **baja el límite a 256 él
  mismo**, llama a la misma función que llama el arranque, y verifica que volvió a subir. Bajar siempre
  se puede; subir está acotado por el límite duro, que no se toca.
