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
| `scans` | Los **119 escaneos reales** pasan por el modelo tipado y vuelven idénticos; el nombre del archivo coincide con el `scan_id` | renombrar la clave `sha256` a `digest` en el codec |
| `decisions` | Los **55 archivos de decisiones reales** re-codifican byte a byte | quitar `created_at` del encoder → los 55 difieren en el byte 44 |
| `digest` | El hasher coincide con `shasum -a 256` en el chunk de producción (1 MiB) sobre 7 tamaños | quitar el último chunk del loop de lectura |
| `walk-permissions` | Un directorio `chmod 000` en medio no detiene el recorrido, y se reporta como inaccesible | pasar `errorHandler: nil` → `inaccessiblePaths` vuelve vacío |
| `trash-exclusion` | Nada bajo una raíz de Papelera se emite, incluso cuando se llega por symlink | comparar por ruta en vez de por identidad → falla solo la variante con symlink |
| `scan` | Un árbol sintético da el mismo JSON en cuatro anchos de concurrencia, con el orden exacto | ordenar con `String <` en vez de `PathOrder` |
| `cache` | Frío contra caliente: mismo resultado, y los registros se escriben | volver a reconstruir el `FileEntry` desde cero en vez de `withSize` |
| `storage` | `link`, `clonefile`, `copyItem` y una escritura fresca se distinguen | keyear `StoragePartition.of` por ruta en vez de por content identifier |
| `trash` | Un archivo temporal va a la Papelera real, vuelve idéntico, y una colisión se renombra | hacer que `TrashDisposer` ignore `resultingItemURL` |
| `undo` | Cuatro archivos van a la Papelera, se journalizan y se restauran idénticos; un segundo deshacer sobre trabajo ocupado se rehúsa | quitar el guardia `fileExists` de `UndoRunner.run` |
| `review` | Tras revisar 1 de 50 grupos: exactamente 1 decisión guardada, 49 ausentes | hacer que `decisionsForSaving` caiga a `effectiveKeep` para los sin decidir |
| `gate` | Aplicar se rehúsa sin simulación, tras editar, y para un plan distinto del mostrado | hacer que `ApplyGate.authorize` ignore su argumento |
| `library` | La ventana real lista, ordena, filtra, etiqueta la cota superior, y **una escritura de otro proceso llega a la tabla** | quitar la asignación `rows =`; vigilar solo `scans/` |
| `review-window` | La ventana real: el preview no es decisión, conservar nada se rehúsa, el almacenamiento del keeper no se ofrece, se guarda 1 de 3 | cinco roturas distintas, listadas junto a cada aserción |
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

`.github/workflows/ci.yml` corre los 21 modos en cada pull request, después de compilar y **antes** del
paso de cobertura.

El orden y la configuración son las dos razones por las que esto cuesta poco:

- **`CONFIG=debug`.** `make selftest` depende de `make all`, que compila en release: un segundo build
  completo. Con `CONFIG=debug` arma y firma lo que el paso de build ya dejó.
- **Antes de la cobertura.** `swift test --enable-code-coverage` recompila el debug con
  instrumentación, o sea que correr los selftests después pagaría un tercer build.

Medido: 14.5 s el build y **10.6 s los 21 modos** en local; en el runner el paso agregó **26 segundos**
al total (1m06s → 1m32s). La razón por la que esto no estaba en CI era una suposición de que hacía
falta compilar en release. No hacía falta.

### Qué pasa en el runner

**Los 21 pasan**, incluidos los que parecían dudosos y por eso se probaron antes de excluirlos:

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
