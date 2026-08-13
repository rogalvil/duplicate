# El contrato de interoperabilidad

Este documento es para quien quiera escribir una tercera herramienta contra los mismos archivos, o
para entender por qué el escritor de JSON está hecho a mano en vez de usar `JSONEncoder`.

La app y `rav duplicate` comparten estado en disco. No hay base de datos, no hay proceso servidor, no
hay negociación: los dos programas leen y escriben los mismos documentos, y el formato es el contrato.

**Todo lo que sigue está verificado contra los archivos reales de este usuario** —119 escaneos, 55
archivos de decisiones, 226 documentos en total— con modos de selftest que decodifican, vuelven a
codificar y **comparan bytes**. No es una descripción de intenciones.

## Dónde

```
$XDG_STATE_HOME/rav/duplicate/      (o ~/.local/state/rav/duplicate/ si no está puesta)
├── scans/<scan_id>.json                 duplicados exactos
├── decisions/<scan_id>.json             qué conservar, por grupo
├── folder-scans/<scan_id>.json          carpetas parecidas
├── folder-decisions/<scan_id>.json      qué conservar, por par de carpetas
├── similar-scans/<scan_id>.json         media perceptualmente parecida
├── similar-decisions/<scan_id>.json     qué conservar, por par de archivos
└── journal/<session_id>.jsonl           solo de esta app: qué se movió y a dónde
```

**Un subdirectorio ausente es normal**, no un error. En esta máquina `folder-decisions/` no existe
porque nunca se ha decidido nada sobre carpetas. Una herramienta que asuma que los seis existen falla
en una instalación limpia.

### `XDG_STATE_HOME` vacía cae al default

`os.environ.get("XDG_STATE_HOME")` en Python devuelve `""` para una variable puesta pero vacía, y `""`
es falsy, así que el CLI cae a `~/.local/state`. **En Swift `""` es truthy**, así que una traducción
literal resuelve la raíz a `/rav` y deja de ver todos los escaneos que ya existen — reportando éxito.
Cualquier implementación tiene que tratar la cadena vacía como ausente.

## `scan_id`

`%Y%m%d-%H%M%S-%f` en UTC: `20260511-064716-685054`. Exactamente 22 caracteres, dígitos con guiones
en las posiciones 8 y 15.

- **Seis dígitos fraccionarios.** Ningún `DateFormatter` de Foundation emite seis:
  `ISO8601DateFormatter` maneja segundos enteros o exactamente tres con `.withFractionalSeconds`. Hay
  que construirlo con `DateComponents` y un `Calendar` en UTC.
- **El orden lexicográfico es el orden cronológico**, que es lo que permite listar "más reciente
  primero" sin parsear nada.
- **Se valida antes de usarlo.** Un `scan_id` leído de disco se interpola en una ruta, así que
  `../../etc/passwd` tiene que rechazarse antes de convertirse en un `open`.
- El nombre del archivo y el `scan_id` de adentro tienen que coincidir. Si no, volver a guardar ese
  escaneo sobrescribe otro o lo renombra en silencio. Hay un modo de selftest que lo verifica en los
  119 documentos reales.

## `scans/<scan_id>.json`

```json
{
  "scan_id": "20260511-064716-685054",
  "root": "/Volumes/WD12TB/Tmp",
  "created_at": "2026-05-11T06:47:16.685054Z",
  "groups": [
    {
      "size": 15,
      "sha256": "a1b2c3...",
      "files": [
        "/Volumes/WD12TB/Tmp/a.txt",
        "/Volumes/WD12TB/Tmp/sub/a.txt"
      ]
    }
  ]
}
```

- `created_at` es una **cadena opaca**. No se parsea ni se reconstruye: el dataclass del CLI también
  la guarda como `str`, así que espejarlo disuelve el problema de los seis dígitos.
- `size` en bytes, compartido por todos los miembros del grupo por construcción.
- `sha256` en hexadecimal minúscula.
- **El orden es parte del formato**, no un detalle de presentación. Ver abajo.
- **Las claves desconocidas se ignoran** al leer. `load_scan` del CLI lee solo `size`, `sha256` y
  `files` de cada grupo, así que la app agrega claves (`shared_storage`, `partial`) que el CLI no ve.
  Compatible hacia adelante en las dos direcciones.
- `root` puede ser **relativo** si el escaneo se hizo con `rav duplicate scan .`. Esas rutas no se
  pueden accionar desde una app: Launch Services arranca con `/` como directorio de trabajo, así que
  resolverlas apuntaría a otro lado. La app las marca y rehúsa.

### El orden es load-bearing

**Dentro de un grupo**: Python ordena objetos `Path`, y `PurePath.__lt__` compara la cadena por
**code point**. Como el orden de bytes UTF-8 *es* el orden de code point, comparar los bytes crudos
reproduce Python exactamente.

**Esto no es teórico.** `String <` de Swift usa orden consciente de equivalencia canónica, que no es
orden de code point, así que `sorted()` divergiría en cualquier ruta con acentos compuestos o emoji. Y
peor: `String ==` de Swift considera **iguales** la "á" precompuesta (U+00E1) y la descompuesta
(U+0061 U+0301), mientras Python las considera distintas. Usar `String` como clave de diccionario
colapsaría dos rutas que el CLI trata como distintas y **perdería una de sus dos decisiones** — o sea,
un archivo mandado a la Papelera sin haberse revisado nunca.

En el corpus real conviven las dos formas: **38 rutas solo-NFD y 10 solo-NFC** de 71,580.

**Entre grupos**: `size` descendente, luego el digest ascendente. Comparar los 32 bytes crudos del
digest da el mismo resultado que comparar el hex, con comparaciones enteras.

**Regla, en una línea: la identidad canónica de una ruta es la secuencia cruda de bytes UTF-8 que
produjo el walker.** Nunca normalizar, nunca `standardizedFileURL`, nunca `resolvingSymlinksInPath`.

## `decisions/<scan_id>.json`

```json
{
  "scan_id": "20260511-064716-685054",
  "created_at": "2026-05-11T06:50:00.000001Z",
  "decisions": {
    "15:a1b2c3...": ["/Volumes/WD12TB/Tmp/a.txt"]
  }
}
```

La clave de cada grupo es `"<size>:<sha256 hex>"`. Keyear por contenido y no por rutas es lo que hace
que una revisión sobreviva a un re-escaneo: los mismos archivos encontrados otra vez producen la misma
clave.

**La ausencia es el contrato.** Un grupo que el usuario no decidió simplemente no es una clave aquí, y
eso es lo que hace segura una revisión parcial en las dos herramientas: `_apply_decisions` del CLI solo
sobrescribe claves presentes, y `decision_candidates` salta las ausentes. Un archivo escrito por esta
app, con solo los grupos revisados, hace que **incluso el CLI** actúe exactamente sobre esos.

Una lista de conservados **vacía** es como el CLI registra "no conservar ninguno", y el CLI mismo
después ignora ese grupo al aplicar. La app la interpreta como descartar el grupo completo. Asimétrico,
pero sub-actuar es la dirección correcta para una acción destructiva.

`similar-decisions/` es un **mapa desnudo sin envoltorio** — verificado contra un archivo real: nada de
`scan_id` ni `created_at`, solo 24 entradas de `"<ruta a>||<ruta b>"` a una de cuatro cadenas,
`keep_a`, `keep_b`, `keep_both` o `keep_none`. Un solo tipo no puede representar las dos formas
honestamente, así que son dos codecs distintos.

## Los otros dos formatos de escaneo

`folder-scans` ya lo escribe esta app; `similar-scans` todavía solo se lee. Los dos hay que respetarlos:

```
folder-scans:   {scan_id, root, created_at, threshold, pairs[]}
  pair:         {folder_a, folder_b, similarity, matching, only_in_a, only_in_b, changed, total_a, total_b}
similar-scans:  {scan_id, root, created_at, img_threshold, vid_threshold, pairs[]}
```

**`threshold` es un float (`0.9`) e `img_threshold` es un entero (`5`).** No es un detalle de estilo:
son la distancia de Hamming máxima y el coeficiente de Dice mínimo, dos cosas distintas con dos tipos
distintos, y emitir `5.0` donde el CLI escribe `5` rompe la comparación byte a byte igual que emitir
`1` donde escribe `1.0`. Los dos errores existen y son opuestos.

### En un par de carpetas, `folder_b` es la que se borra

`rav duplicate folders-move` **conserva `folder_a` y manda `folder_b` a cuarentena** — lo dice su propia
ayuda. O sea que en un documento de `folder-scans`, cuál ruta va en cuál campo decide cuál carpeta
destruye ese comando, y el documento es formato compartido: un escaneo que escriba la app se puede
aplicar con el CLI.

Ninguna de las dos orientaciones es "la correcta" — la del CLI sale del orden de `os.walk`. Pero la app
**normaliza por bytes**: `folder_a` es siempre la ruta menor. Arbitraria y reproducible le gana a
arbitraria y dependiente del enumerador cuando un comando borra uno de los dos lados.

Medido sobre un árbol real de 3,421 archivos: los dos programas encuentran **el mismo conjunto de 42
pares**, y la app los escribía **los 42 al revés** que el CLI porque tomaba la orientación del orden de
índices del árbol. El caso que lo destapa es una carpeta cuyo nombre es **prefijo del de su hermana**
(`wen` y `wen 2`): el recorrido visita `wen` primero porque el nombre corto ordena antes, y el orden de
bytes pone `wen 2/s` primero porque el espacio (0x20) le gana al slash (0x2F). Sesenta árboles aleatorios
del test diferencial nunca produjeron un hermano-prefijo, así que la propiedad se sostenía por suerte.

**Ningún pHash aparece en el formato compartido.** `similar-scans` guarda `file_a`, `file_b`,
`similarity` y `media_type`, no los hashes. Por eso la app no necesita ser bit-idéntica a
`imagehash.phash`: nada de lo que produce se vuelve ilegible para el CLI. Lo que sí es compartido es
`similarity`, que se deriva del hash (`1.0 - hamming/64.0`), así que un escaneo escrito por Python y uno
escrito por Swift mostrarán números un poco distintos para el mismo par. Solo se renderiza y se compara
contra un umbral, así que la divergencia es cosmética — pero se escribe aquí, no se descubre.

## Las cinco cosas que Foundation hace mal

Por esto el escritor de JSON está hecho a mano. `JSONEncoder` y `JSONSerialization` con
`.prettyPrinted` fallan cada uno en algo:

| # | Qué exige `json.dumps(obj, indent=2)` | Qué hace Foundation |
|---|---|---|
| 1 | No-ASCII escapado como `\uXXXX` (`ensure_ascii=True`), con pares surrogados para el plano astral. `/` **no** se escapa | `JSONEncoder` emite UTF-8 crudo |
| 2 | Un `float` entero se escribe `1.0` | `JSONEncoder` escribe `1` |
| 3 | Indent de 2, separador `": "`, `,\n` entre ítems, contenedores vacíos en línea, `\n` final | `.prettyPrinted` usa otro espaciado |
| 4 | Orden de claves = orden de inserción | `.sortedKeys` reordena; sin él, un `Dictionary` no tiene orden |
| 5 | Seis dígitos fraccionarios en las fechas | ningún formatter los emite |

El punto 2 aparece de verdad y no en un caso raro: **`"similarity": 1.0` sale 1,107 veces** en los
documentos reales de esta máquina —7 en `folder-scans` y 1,100 en `similar-scans`— o sea que un par
idéntico es el caso común, no el borde. `JSONEncoder` escribiría `1` para todos.

`Double.description` de Swift ya emite `1.0`, así que es la primitiva correcta. El hueco que queda:
Python renderiza `0.00001` como `1e-05` y Swift no, algo que no aparece porque todas las similitudes
están en `[0,1]` y la más chica que existe en el corpus es `0.75`.

## El journal es solo de la app

`journal/<session_id>.jsonl`, una línea compacta de JSON por archivo movido:

```
{"format_version": 1, "original_path": "/Users/t/Downloads/a-2.pdf", "resulting_path": "/Users/t/.Trash/a-2.pdf", "mechanism": "trash", "size": 20480, "sha256": "a1b2...", "group_key": "20480:a1b2...", "scan_id": "20260511-064716-685054", "timestamp": "2026-08-12T04:20:00.000001Z"}
```

`mechanism` es `trash` o `quarantine`: la app manda a la Papelera y solo cae a mover a una carpeta
cuando `trashItem` falla, que es lo que pasa en un montaje de red o un volumen de solo lectura.

- **`.jsonl` y no `.json`**: no se puede hacer append a un `[…]` pretty-printed sin reescribirlo, y un
  crash a media escritura tiene que dejar legible todo lo anterior. Una línea truncada cuesta esa línea
  y nada más. La extensión es la señal honesta de que no es el formato del CLI.
- **Un registro `undone_at` se agrega, no reescribe la línea original**, para que el journal siga siendo
  un log veraz de lo que pasó en orden en vez de un resumen mutable del estado actual. Al leerlo, una
  entrada con un `undone_at` posterior cuenta como ya restaurada.
- El CLI solo lee los seis subdirectorios que conoce, así que un `journal/` hermano le es invisible.
- Lleva `formatVersion: 1` para que un futuro `rav duplicate undo` lo pueda adoptar sin renegociar.

## Escrituras

La app escribe con `Data.write(options: .atomic)`: temporal más rename, así que un lector ve el
documento viejo o el nuevo. El CLI usa `Path.write_text`, que no lo es — un crash o un disco lleno a
media escritura deja un JSON truncado donde había un escaneo. El formato no cambia en un byte: mejora
estricta sin costo de interoperabilidad.

**No hay lock.** Si las dos herramientas guardan el *mismo* `scan_id` al mismo tiempo, el rename
atómico garantiza que se lea uno de los dos completo, pero no cuál. Para dos herramientas manejadas por
una persona parece aceptable; se dice en vez de suponerlo.

## Cómo se verifica

```bash
make selftest MODE=json-roundtrip   # los 226 documentos, por el árbol genérico
make selftest MODE=scans            # los 119 escaneos, por el modelo tipado
make selftest MODE=decisions        # los 55 archivos de decisiones
```

Los tres son de **solo lectura** y comparan bytes. Una falla es un diff con offset, no una discusión.

`scans` y `decisions` son los más fuertes porque pasan por el camino que toma producción
(`decode` → modelo → `encode`), no por un árbol genérico que podría conservar por accidente lo que el
modelo tira.

Los tests unitarios cubren lo mismo con fixtures sintéticos, porque el corpus real tiene rutas privadas
y un fixture commiteado es un archivo publicado. Los fixtures se regeneran con
`python3 scripts/make-json-fixtures.py`.
