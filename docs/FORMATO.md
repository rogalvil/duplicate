# El formato en disco

Dónde guarda la app lo que encuentra y lo que decides, y cómo está escrito. Sirve para respaldar o mover esos
archivos, para leerlos con otra herramienta, y para entender por qué el escritor de JSON está hecho a mano en vez
de usar `JSONEncoder`.

**De dónde viene el formato.** La app nació como versión con ventana de `rav duplicate`, una herramienta de línea
de comandos en Python del mismo autor, que no es pública. Las dos comparten estos archivos, así que el formato
sigue las reglas de cómo Python los escribe: el orden de las rutas, el escape de caracteres, `1.0` y no `1`. Esas
reglas son las que explican casi todo lo que sigue. No hace falta tener esa herramienta para usar la app.

Todo lo que sigue está verificado contra archivos reales —119 escaneos, 55 archivos de decisiones, 226 documentos—
con modos de selftest que decodifican, vuelven a codificar y **comparan bytes**.

## Dónde

```
$XDG_STATE_HOME/rav/duplicate/      (o ~/.local/state/rav/duplicate/ si no está puesta)
├── scans/<scan_id>.json                 duplicados exactos
├── decisions/<scan_id>.json             qué conservar, por grupo
├── folder-scans/<scan_id>.json          carpetas parecidas
├── folder-decisions/<scan_id>.json      qué conservar, por par de carpetas
├── similar-scans/<scan_id>.json         imágenes y videos parecidos
├── similar-decisions/<scan_id>.json     qué conservar, por par de archivos
├── similar-renames/<scan_id>.json       con qué nombre se conserva un archivo (solo esta app)
└── journal/<session_id>.jsonl           qué se movió y a dónde, para poder deshacerlo
```

Fuera de ahí, en `~/Library/Caches/com.rogalvil.duplicate/`, están las cachés de hashes (`hashes.v1` y
`phashes.v1`). Son datos derivados: macOS las puede borrar cuando falta espacio, y lo único que se pierde es
tiempo en el siguiente escaneo.

**Un subdirectorio ausente es normal**, no un error: `folder-decisions/` no existe hasta que alguien decide algo
sobre carpetas. Quien lea estos archivos no puede asumir que los seis existen.

**`XDG_STATE_HOME` puesta pero vacía cuenta como ausente** y cae a `~/.local/state`. Es lo que hace Python (`""` es
falso ahí); en Swift `""` es verdadero, y una traducción literal resolvería la raíz a `/rav` y dejaría de ver todos
los escaneos que ya existen, reportando éxito.

## `scan_id`

`%Y%m%d-%H%M%S-%f` en UTC: `20260511-064716-685054`. Exactamente 22 caracteres, dígitos con guiones en las
posiciones 8 y 15.

- **Seis dígitos fraccionarios.** Ningún `DateFormatter` de Foundation los emite: `ISO8601DateFormatter` maneja
  segundos enteros o exactamente tres. Se construye con `DateComponents` y un `Calendar` en UTC.
- **El orden lexicográfico es el orden cronológico**, que es lo que permite listar "más reciente primero" sin
  parsear nada.
- **Se valida antes de usarlo.** Un `scan_id` leído de disco se interpola en una ruta, así que `../../etc/passwd`
  tiene que rechazarse antes de convertirse en un `open`.
- **El nombre del archivo y el `scan_id` de adentro coinciden.** Si no, volver a guardar ese escaneo sobrescribiría
  otro o lo renombraría en silencio. El modo de selftest `scans` lo verifica en cada documento.

## `scans/<scan_id>.json`

```json
{
  "scan_id": "20260511-064716-685054",
  "root": "/Volumes/Externo/Tmp",
  "created_at": "2026-05-11T06:47:16.685054Z",
  "groups": [
    {
      "size": 15,
      "sha256": "a1b2c3...",
      "files": [
        "/Volumes/Externo/Tmp/a.txt",
        "/Volumes/Externo/Tmp/sub/a.txt"
      ]
    }
  ]
}
```

- `created_at` es una **cadena opaca**: se guarda como llegó y no se reconstruye, lo que de paso evita el problema
  de los seis dígitos.
- `size` en bytes, el mismo para todos los miembros del grupo por construcción. `sha256` en hexadecimal minúscula.
- **Las claves desconocidas se ignoran al leer.** La app agrega `shared_storage` y `partial` a cada grupo, y un
  lector que solo conozca `size`, `sha256` y `files` los salta sin problema.
- `root` puede ser **relativo** en un escaneo hecho desde una terminal con `.` como raíz. Esas rutas no se pueden
  accionar desde una app —Launch Services la arranca con `/` como directorio de trabajo, así que resolverlas
  apuntaría a otro lado—, y la app las marca y se niega a actuar sobre ellas.

### El orden es parte del formato

**Dentro de un grupo, las rutas van ordenadas por bytes UTF-8**, que es el orden en que Python compara rutas
(por code point, y el orden de bytes UTF-8 *es* el de code point).

**No es teórico.** `String <` de Swift compara con equivalencia canónica, que no es orden de code point, así que
`sorted()` divergiría en cualquier ruta con acentos compuestos o emoji. Y `String ==` considera **iguales** la "á"
precompuesta (U+00E1) y la descompuesta (U+0061 U+0301): usar `String` como clave de diccionario colapsaría dos
rutas distintas y **perdería una de sus dos decisiones**, o sea un archivo mandado al basurero sin haberse revisado.
En un corpus real conviven las dos formas: **38 rutas solo-NFD y 10 solo-NFC** de 71,580. Todo pasa por
`PathOrder`, que compara bytes.

**Entre grupos**: `size` descendente, luego el digest ascendente. Comparar los 32 bytes crudos del digest da el
mismo resultado que comparar el hex, con comparaciones enteras.

**La regla, en una línea: la identidad de una ruta es la secuencia de bytes UTF-8 que produjo el recorrido.** Nunca
normalizar, nunca `standardizedFileURL`, nunca `resolvingSymlinksInPath`.

## `decisions/<scan_id>.json`

```json
{
  "scan_id": "20260511-064716-685054",
  "created_at": "2026-05-11T06:50:00.000001Z",
  "decisions": {
    "15:a1b2c3...": ["/Volumes/Externo/Tmp/a.txt"]
  }
}
```

La clave de cada grupo es `"<size>:<sha256 hex>"`. Llavear por contenido y no por rutas hace que una revisión
sobreviva a un re-escaneo: los mismos archivos encontrados otra vez dan la misma clave.

**La ausencia es el contrato.** Un grupo que no decidiste no aparece aquí. Eso es lo que hace segura una revisión a
medias: quien aplique estas decisiones actúa solo sobre los grupos presentes, y salir de la ventana tras revisar
uno de cincuenta no registra nada sobre los otros cuarenta y nueve.

Una lista de conservados **vacía** significa "no conservar ninguno": la app la aplica como descartar el grupo
completo.

## Los otros dos formatos de escaneo

```
folder-scans:   {scan_id, root, created_at, threshold, pairs[]}
  pair:         {folder_a, folder_b, similarity, matching, only_in_a, only_in_b, changed, total_a, total_b}
similar-scans:  {scan_id, root, created_at, img_threshold, vid_threshold, pairs[]}
  pair:         {file_a, file_b, similarity, media_type}
```

**`threshold` es un float (`0.9`) e `img_threshold` es un entero (`5`).** Son el coeficiente de Dice mínimo y la
distancia de Hamming máxima, dos cosas distintas con dos tipos distintos. Emitir `5.0` donde va `5` rompe la
comparación byte a byte igual que emitir `1` donde va `1.0`.

**En un par de carpetas, `folder_a` es siempre la ruta menor por bytes.** Tomarla del orden del recorrido la haría
depender de cómo enumera el sistema de archivos, que nada promete reproducir. El caso que lo destapó fue una
carpeta cuyo nombre es prefijo del de su hermana (`wen` y `wen 2`): el recorrido visita `wen` primero, y el orden de
bytes pone `wen 2/s` primero porque el espacio (0x20) le gana al slash (0x2F).

**Ningún hash perceptual aparece en el formato.** `similar-scans` guarda `file_a`, `file_b`, `similarity` y
`media_type`. `similarity` se deriva del hash (`1.0 - hamming/64.0`) y se compara contra un umbral, así que un
escaneo hecho por otra implementación del pHash puede dar números un poco distintos para el mismo par sin que
nada se vuelva ilegible.

### `similar-decisions` es un mapa sin envoltorio

`decisions/` envuelve su mapa en `{scan_id, created_at, decisions}`; `similar-decisions/` **es** el mapa:

```
similar-decisions:  {"<file_a>||<file_b>": "keep_a" | "keep_b" | "keep_both" | "keep_none"}
```

Un solo tipo no puede representar las dos formas honestamente, así que son dos codecs.

- **Las entradas se guardan en orden, no en un `Dictionary`.** Un diccionario no tiene orden: re-codificarlo
  mezclaría las líneas, y la comparación byte a byte fallaría sobre un archivo cuyo contenido es idéntico.
- **Los cuatro valores aparecen de verdad.** Sobre 17 documentos reales, 943 claves: `keep_a` 597, `keep_b` 337,
  `keep_both` 8 y `keep_none` 1.
- **El separador son dos pipes sin escapes**, así que una ruta que contenga `||` da una clave ambigua. La app lo
  avisa al cerrar el visor en vez de esconderlo.
- **Una decisión desconocida se rechaza, no se salta.** Saltarla convertiría en silencio un par revisado en uno sin
  revisar.

### `similar-renames` es solo de esta app

Un grupo de parecidos que conserva un archivo puede conservarlo con el nombre de otro miembro (#228): la foto buena
se llama «foto copia.png» y el nombre que vale es el de «foto.png», que se va. `similar-decisions` es el mapa de
pares del CLI y no tiene dónde poner un nombre, así que la elección va en un documento aparte, que el CLI no lee:

```
{"format_version": 1, "name_from": ["<miembro que presta el nombre>", ...]}
```

- **Solo el miembro que presta el nombre, no el archivo que se queda.** Cada archivo está en un solo grupo, así que
  el miembro dice de qué grupo es; el archivo que se queda sale de las decisiones. Y con dos archivos conservados la
  elección se aparta sin perderse, cuando no hay un único archivo que escribir: una primera versión guardaba pares
  `keep`/`name_from` y, al confirmar dos conservados, borraba del disco el nombre elegido (lo encontró la revisión
  de #229).
- **Una lista, no un conjunto de `String`.** Un `Set<String>` compara por equivalencia canónica y juntaría una ruta
  NFC y otra NFD de dos archivos distintos.
- **No es una decisión.** Se guarda al elegir, también en un grupo sin decidir, para que la elección sobreviva a
  cerrar la ventana; solo se aplica en un grupo decidido que conserva exactamente un archivo. Una ruta que ya no está
  en el escaneo se ignora.
- **Sin elecciones no hay archivo**: guardar una lista vacía borra el documento. Y se borra junto con su escaneo.

## Por qué el escritor de JSON está hecho a mano

El formato es el de `json.dumps(obj, indent=2)` de Python, y `JSONEncoder` y `JSONSerialization` fallan cada uno en
algo:

| # | Qué exige el formato | Qué hace Foundation |
|---|---|---|
| 1 | No-ASCII escapado como `\uXXXX`, con pares surrogados para el plano astral; `/` **no** se escapa | `JSONEncoder` emite UTF-8 crudo |
| 2 | Un `float` entero se escribe `1.0` | `JSONEncoder` escribe `1` |
| 3 | Indent de 2, separador `": "`, `,\n` entre ítems, contenedores vacíos en línea, `\n` final | `.prettyPrinted` usa otro espaciado |
| 4 | Orden de claves = orden de inserción | `.sortedKeys` reordena; sin él, un `Dictionary` no tiene orden |
| 5 | Seis dígitos fraccionarios en las fechas | ningún formatter los emite |

El punto 2 no es un caso raro: **`"similarity": 1.0` sale 1,107 veces** en los documentos reales de esta máquina,
porque un par idéntico es el caso común. `Double.description` de Swift ya emite `1.0`; el hueco que queda es que
Python escribe `0.00001` como `1e-05` y Swift no, y no aparece porque las similitudes están en `[0,1]` y la menor
del corpus es `0.75`.

## El journal

`journal/<session_id>.jsonl`, una línea compacta de JSON por archivo movido:

```
{"format_version": 1, "original_path": "/Users/t/Downloads/a-2.pdf", "resulting_path": "/Users/t/.Trash/a-2.pdf", "mechanism": "trash", "size": 20480, "sha256": "a1b2...", "group_key": "20480:a1b2...", "scan_id": "20260511-064716-685054", "timestamp": "2026-08-12T04:20:00.000001Z"}
```

`mechanism` es `trash`, `quarantine` o `rename`: la app manda al basurero y solo cae a mover a una carpeta de
cuarentena cuando el basurero no está disponible, como en un montaje de red. Para una carpeta, `sha256` es el
digest de su manifiesto (cada archivo con su ruta relativa) y `size` la suma de sus archivos.

**`rename` es el archivo que se queda, con el nombre de otro** (#228): `original_path` es su nombre de antes,
`resulting_path` el nuevo, en la misma carpeta y con su propia extensión. `size` es **0**, porque no liberó nada;
`sha256` es el del archivo, leído antes de renombrar; `group_key` es `"<conservado>||<quien prestó el nombre>"`. Se
escribe después de los movimientos de su sesión, porque el nombre solo está libre cuando el otro archivo ya se fue.
Y al deshacer se procesa **antes**, del último al primero: el nombre nuevo suele ser la ruta original de un archivo
que la misma sesión mandó al basurero, y ese archivo no puede volver mientras el renombrado la ocupe. Una versión
anterior de la app no conoce `rename` y lee esa línea como ilegible: su deshacer deja el renombrado como está, y si
el nombre nuevo es la ruta del archivo que se fue, ese archivo queda bloqueado en vez de escribirse encima.

- **`.jsonl` y no `.json`**: no se puede agregar a un `[…]` con indentación sin reescribirlo, y un crash a media
  escritura tiene que dejar legible todo lo anterior. Una línea truncada cuesta esa línea y nada más.
- **Deshacer agrega un registro `undone_at`**, no reescribe la línea original, para que el journal siga siendo un
  log veraz de lo que pasó, en orden.
- Lleva `format_version: 1` para poder cambiarlo sin adivinar.

## Escrituras

La app escribe con `Data.write(options: .atomic)`: un archivo temporal y luego un rename, así que quien lea ve el
documento viejo o el nuevo, nunca uno a medias.

**No hay lock entre programas.** Si dos herramientas guardan el *mismo* `scan_id` al mismo tiempo, el rename
atómico garantiza que se lea uno de los dos completo, pero no cuál. Las cachés de hashes sí toman un lock: el
segundo proceso que las abre las lee pero no escribe.

## Cómo se verifica

```bash
make selftest MODE=json-roundtrip   # cada documento, por el árbol genérico
make selftest MODE=scans            # cada escaneo, por el modelo tipado
make selftest MODE=decisions        # cada archivo de decisiones
```

Los tres son de **solo lectura** y comparan bytes. Una falla es un diff con offset, no una discusión. `scans` y
`decisions` son los más fuertes porque pasan por el camino que toma producción (`decode` → modelo → `encode`), no
por un árbol genérico que podría conservar por accidente lo que el modelo tira.

Los tests unitarios cubren lo mismo con fixtures sintéticos, porque un corpus real tiene rutas privadas y un
fixture commiteado es un archivo publicado. Se regeneran con `python3 scripts/make-json-fixtures.py`.
