# Los selftests

`swift test` no tiene bundle, así que no puede ver si el Makefile sustituyó los placeholders del
`Info.plist`, si los `.lproj` aterrizaron donde `Bundle.main` los busca, si el menú tiene atajos
colisionados, ni si una ventana muestra lo que su modelo dice. Eso es `make selftest`.

```bash
make selftest MODE=scan          # un modo
make selftest MODE=digest ARGS="--dir /ruta"
make selftest-all                # todos, parando en el primero que falla
```

## Las dos reglas

1. **Tiene que afirmar.** Un modo que imprime números que nadie revisa es decoración.
2. **Tiene que probarse fallando contra la versión rota.** Cada modo lleva en su comentario el cambio
   exacto que lo hace fallar, y ese cambio se aplicó de verdad antes de confiar en su verde. **Ya pasó
   que un arnés pasara contra código roto**: la regla es lo que destapó que el `errorHandler` de
   `FileManager.enumerator` no hace lo que documenta Foundation.

La segunda columna de la tabla no es aspiracional. Cada línea se ejecutó.

## Catálogo

| Modo | Qué afirma | Cómo se probó que falla |
|---|---|---|
| `bundle` | El bundle armado tiene identificador, versión y build reales, sin placeholders | quitar un `-e 's|__VERSION__|…|g'` del Makefile |
| `state-dir` | Las siete rutas del estado resuelven bien, y un archivo regular donde va un directorio se reporta | cambiar el guardia `base.isEmpty` a `base == nil` |
| `l10n` | Las dos tablas cubren las mismas claves; toda clave usada en código existe; toda clave declarada se usa | borrar una línea de `es.lproj`, o escribir mal una clave en `Strings.string` |
| `menu` | Ningún par de ítems comparte atajo y modificadores; ningún submenú vacío; alguien manda `undo:` y las acciones de revisión | dar el mismo atajo a dos ítems |
| `json-roundtrip` | Los **226 documentos reales** del usuario re-codifican byte a byte, por el árbol genérico | cambiar el indent de 2 a 4 → falla en el byte 2 |
| `scans` | Los **120 escaneos exactos**, los **4 de carpetas** y los **31 perceptuales** reales pasan por su modelo tipado y vuelven byte-idénticos; el nombre del archivo coincide con el `scan_id` de adentro | cuatro roturas: renombrar la clave `sha256` a `digest`, escribir `similarity` de carpetas como entero (4 fallan), `img_threshold` como float (31 fallan), `similarity` perceptual como entero (22 fallan, los otros 9 documentos no tienen pares) |
| `decisions` | Los **56 archivos de decisiones** y los **17 de decisiones perceptuales** reales re-codifican byte a byte; reporta el conteo de cada valor y cuántas claves no se pueden partir | dos roturas: quitar `created_at` del encoder (los 56 difieren en el byte 44), ordenar los miembros del mapa perceptual (**16 de 17** difieren) |
| `digest` | El hasher coincide con `shasum -a 256` en el chunk de producción (1 MiB) sobre 7 tamaños | quitar el último chunk del loop de lectura |
| `walk-permissions` | Un directorio `chmod 000` en medio no detiene el recorrido, y se reporta como inaccesible | pasar `errorHandler: nil` → `inaccessiblePaths` vuelve vacío |
| `trash-exclusion` | Nada bajo una raíz de Papelera se emite, incluso cuando se llega por symlink | comparar por ruta en vez de por identidad → falla solo la variante con symlink |
| `scan` | Un árbol sintético da el mismo JSON en cuatro anchos de concurrencia, con el orden exacto | ordenar con `String <` en vez de `PathOrder` |
| `cache` | Frío contra caliente: mismo resultado, y los registros se escriben | volver a reconstruir el `FileEntry` desde cero en vez de `withSize` |
| `storage` | `link`, `clonefile`, `copyItem` y una escritura fresca se distinguen | keyear `StoragePartition.of` por ruta en vez de por content identifier |
| `trash` | Un archivo temporal va a la Papelera real, vuelve idéntico, y una colisión se renombra | hacer que `TrashDisposer` ignore `resultingItemURL` |
| `undo` | Cuatro archivos van a la Papelera, se journalizan y se restauran idénticos; un segundo deshacer sobre trabajo ocupado se rehúsa | quitar el guardia `fileExists` de `UndoRunner.run` |
| `review` | Tras revisar 1 de 50 **grupos** y 1 de 50 **pares parecidos**: exactamente 1 decisión guardada de cada tipo, 49 ausentes — el par pasa además por el store — y una contradicción entre pares traslapados se reporta | tres roturas: `decisionsForSaving` cayendo a `effectiveKeep` para los sin decidir (exacto), lo mismo en el perceptual (**50 decisiones antes de que nadie decidiera nada**), y `contradictions` devolviendo vacío |
| `gate` | Aplicar se rehúsa sin simulación, tras editar, y para un plan distinto del mostrado | hacer que `ApplyGate.authorize` ignore su argumento |
| `library` | La ventana real lista, ordena, filtra, etiqueta la cota superior, y **una escritura de otro proceso llega a la tabla** | quitar la asignación `rows =`; vigilar solo `scans/` |
| `review-window` | La ventana real: el preview no es decisión, conservar nada se rehúsa, el almacenamiento del keeper no se ofrece, se guarda 1 de 3 | cinco roturas distintas, listadas junto a cada aserción |
| `preview` | Un PNG real se dibuja por `quicklookd`; un grupo cuyos archivos ya no están lo dice; un largo distinto no se reporta como sano; el segundo archivo del grupo no vuelve a pedir thumbnail | cuatro roturas: thumbnail nulo, clave por ruta, presencia siempre presente, comparación de tamaño quitada |
| `fdlimit` | El límite blando de descriptores sube de verdad, y un escaneo de 300 archivos no filtra ninguno | hacer que `raiseIfNeeded` no llame a `setrlimit` → falla con 256 |
| `scan-window` | La ventana escanea 60 archivos en 20 grupos y el documento se lee de vuelta; una raíz mala se rehúsa antes de trabajar; **un escaneo cancelado no escribe nada** | tres roturas: `check` siempre ok, no guardar, guardar antes del último chequeo de cancelación |
| `apply-window` | El ciclo destructivo completo por las ventanas reales: nada se mueve sin dry-run vigente, la hoja lista exactamente lo que se mueve, **un archivo que cambió desde el escaneo se deja en paz**, aplicar consume la autorización, y deshacer devuelve byte-idéntico | cuatro roturas: sin comparar digests, simular sin avanzar el flujo, aplicar sin consumir la autorización, `removalPlan` incluyendo grupos sin decidir |
| `lifecycle` | Una app sin ventanas recupera su biblioteca con un reopen, y cerrar la última ventana cierra la app | dos roturas: reopen que no muestra nada, y seguir vivo sin ventanas |
| `similar-window` | El detector perceptual de punta a punta: la ventana lo ofrece con umbral **en bits** y casilla de video, un escaneo real encuentra los pares (imagen y video) y vuelve del store, un **segundo escaneo lo sirve la caché**, la biblioteca lo lista con su pie y su estado vacío correctos, el watcher nota un tercer documento, el visor pone **dos archivos distintos** lado a lado con el consejo, y **un clic decide un par y escribe una clave mientras un saltar no escribe ninguna** | siete roturas, entre ellas: `file_a` en los dos paneles, la sesión que no guarda, el estado vacío leyendo el arreglo exacto, el encabezado de imagen en un par de video, la caché apagada, decidir todos los pares en vez del seleccionado, y saltar que confirma |
| `similar-apply` | Aplica una decisión perceptual a la **Papelera real** y la deshace: la compuerta rehúsa sin simulación vigente **y** con una huella que no es la mostrada, el par se re-puntúa antes de mover, el journal guarda el digest **calculado al mover**, el undo restaura byte-idéntico, y un par que dejó de parecerse se rehúsa. No deja nada en la Papelera | tres roturas: quitar la verificación del runner (`a changed file was moved to the Trash`), hacer que `ApplyGate` ignore su huella (`an apply was authorised for a plan that was never shown`), y no calcular el digest |
| `folder-apply` | Mueve una carpeta a la **Papelera real** y la devuelve entera, y **rehúsa** otra que contiene un archivo que la conservada no tiene, nombrándolo; un escaneo sin revisar no planea nada | dos roturas: quitar el chequeo de contención (`2 folders moved, wanted 1`), y que un par sin decidir caiga al default del CLI (`an untouched folder review planned 2 moves`) |
| `video` | El camino de video en el build de release, con una película real: `AVAssetWriter` codifica H.264, `AVAssetImageGenerator` saca los cuadros, y un clip plano da **un solo hash** (`8000000000000000`) mientras uno con movimiento da varios; más la comparación contra el umbral de 0.70 | dos roturas: quitar la cuantización tras el resample (`d555d515d515d505` en vez del bit del DC), muestrear siempre el mismo instante (1 hash distinto en vez de 5) |
| `phash` | El hash perceptual en el build de release: un uniforme da **solo el bit del DC** y sus otros 63 coeficientes son **exactamente cero**, un JPEG q=0.9 no mueve el hash más allá del umbral del CLI, el archivo y sus muestras en memoria coinciden, y una inversión sí se aleja | dos roturas: quitar la cuantización a `UInt8` tras el resample (`ab2adcaad8aad8a8` en vez del bit del DC), transformar con la matriz de la base en vez de con Accelerate (`bc41a9b8a9a90046`) |
| `folder-window` | El detector de carpetas de punta a punta: la ventana lo ofrece, un escaneo real encuentra el par con sus números exactos, la biblioteca lo lista, el visor nombra el traslape y la diferencia, y **todo par guardado queda orientado por bytes** —`folder_b` es la que `rav duplicate folders-move` borra | cuatro roturas: la sesión no guarda, la biblioteca siempre lee los resúmenes exactos, `similarity` escrita como entero, y orientar por los índices del árbol (`folder_a` sale `…/wen/s`) |
| `about` | El panel muestra fecha de compilación y número de build de verdad | quitar la sustitución de `__BUILD_NUMBER__` |
| `icon` | El `.icns` está en el bundle y trae las siete resoluciones | quitar el `cp Resources/AppIcon.icns` del Makefile |

## Qué toca cada modo

Importa porque el corpus del usuario tiene 119 escaneos que no se pueden perder.

- **Solo lectura sobre el corpus real**: `json-roundtrip`, `scans`, `decisions`, y la medición de tiempo
  al final de `library`. Nunca escriben ahí.
- **Escriben solo en `/tmp`**: `scan`, `cache`, `storage`, `review`, `gate`, `library`,
  `review-window`, `walk-permissions`, `digest`, `state-dir`, `trash-exclusion`.
- **Tocan la Papelera real**: `trash` y `undo`. Mandan archivos temporales suyos y los limpian por
  ruta al terminar. `~/.Trash` no se puede *listar* desde la shell por TCC, pero `fileExists` sí
  funciona ahí, y eso es lo que permite verificar que no quedó basura.
- **Necesitan el repo como directorio de trabajo**: `l10n`, para escanear las fuentes. Si no lo tiene,
  **salta en voz alta** en vez de pasar sin haber hecho nada.
- **Saltan explícitamente cuando no aplican**: `storage` en un `/tmp` que no sea APFS,
  `walk-permissions` corriendo como root, y los tres de interop cuando no hay corpus. Cada salto
  imprime su razón: un modo que pasa en silencio sin haber hecho nada es peor que no tenerlo.

## CI los corre, y cómo se pagó

`.github/workflows/ci.yml` corre los 32 modos en cada pull request, después de compilar y **antes** del
paso de cobertura.

El orden y la configuración son las dos razones por las que esto cuesta poco:

- **`CONFIG=debug`.** `make selftest` depende de `make all`, que compila en release: un segundo build
  completo. Con `CONFIG=debug` arma y firma lo que el paso de build ya dejó.
- **Antes de la cobertura.** `swift test --enable-code-coverage` recompila el debug con
  instrumentación, o sea que correr los selftests después pagaría un tercer build.

Medido: 14.5 s el build y **8.5 s los 30 modos** en local; en el runner el paso agregó **26 segundos**
al total (1m06s → 1m32s). La razón por la que esto no estaba en CI era una suposición de que hacía
falta compilar en release. No hacía falta.

### Qué pasa en el runner

**Los 27 pasan**, incluidos los que parecían dudosos y por eso se probaron antes de excluirlos:

| Modo | Duda | Qué pasó de verdad |
|---|---|---|
| `trash`, `undo` | ¿`trashItem` funciona sin sesión de Finder? | sí, aterriza en `/Users/runner/.Trash` |
| `menu`, `library`, `review-window` | ¿hay window server? | sí, `NSApplication` conecta y las ventanas se construyen |
| `storage` | ¿el disco del runner es APFS con `clonefile`? | sí, distingue las cinco variantes |
| `icon`, `about`, `bundle` | ¿el bundle se arma bien fuera de esta máquina? | sí |

Cuatro saltan, todos por lo mismo — no hay directorio de estado compartido en un runner limpio:

```
SKIPPED: no JSON found (6 directories absent)
SKIPPED: /Users/runner/.local/state/rav/duplicate/scans is not readable
SKIPPED: /Users/runner/.local/state/rav/duplicate/decisions is not readable
SKIPPED: no real corpus to time
```

Para no perder del todo la garantía de interoperabilidad, hay un paso extra que corre
`json-roundtrip` contra los **fixtures commiteados**: seis formas de documento, byte a byte, por el
camino que toma producción y no por la copia que tienen los tests unitarios.

Lo que sigue sin cubrirse en CI: el round-trip **tipado** contra documentos reales (`scans` y
`decisions`), porque los fixtures no tienen nombres que coincidan con su `scan_id` y esos modos
—correctamente— fallan ante un documento que no es un escaneo. Los tests unitarios cubren el modelo
tipado sobre esos mismos fixtures, así que el hueco real es solo "nadie verificó los 119 documentos de
esta máquina en CI", que por definición solo se puede hacer aquí.
