# La pasada a mano

Lo que ningún arnés alcanza, en el orden en que conviene mirarlo.

**Por qué existe este documento.** 44 modos de selftest y 776 tests cubren lo que se puede afirmar desde código:
que una ventana calcula bien lo que muestra, que un archivo se movió, que un digest coincide. Lo que no pueden
ver es si **aparece** un panel del sistema, si un ítem de menú se **habilita**, si un texto **cabe**, y —lo más
importante— **qué permisos tiene la app de verdad**.

Ese último punto no es un detalle. **TCC atribuye el permiso al proceso responsable, no al binario.** Lanzada
desde la terminal, la app hereda los permisos de la terminal; lanzada por Launch Services es su propio
responsable. Así que un selftest verde **no dice nada** sobre el estado de TCC de la app, y esta pasada solo
vale hecha con la app abierta como la abre un usuario.

```bash
make            # compila, arma y firma build/Duplicate.app
make run        # la abre por Launch Services (open), no desde la terminal
```

## El árbol de prueba

No ensayes sobre tu corpus real: la pasada incluye aplicar y deshacer.

```bash
python3 scripts/make-demo-tree.py ~/demo-duplicate
```

**Lo que contiene, medido** con `--selftest --mode corpus --dir ~/demo-duplicate` en sus tres variantes:

| detector | resultado |
|---|---|
| exactos | **7 grupos** sobre 23 archivos |
| parecidos | **2 pares de imagen y 2 de video**, 8 archivos hasheados |
| carpetas | **2 pares** sobre 7 directorios: `copia-a ↔ copia-b` al 90.9% y `notas ↔ notas` al 100% |

**Cuatro de esos archivos existen para forzar casos que no salen solos**, y ninguno cambia el 7: son parecidos
entre sí y ninguno es byte-idéntico a otro.

| fixture | para qué |
|---|---|
| `clip-corto.mp4` y su recodificado, de 0.5 s | el encabezado de pocos cuadros: a medio segundo sólo **4 de 8** marcas caen dentro |
| `foto\|\|rara.jpg` y su reescalada | el aviso de clave ambigua: `SimilarPairKey` guarda `a\|\|b` sin escapes |

La primera versión del fixture de `||` guardaba la **misma** imagen del paisaje a la misma calidad, salía
byte-idéntica, y agregaba dos grupos exactos: el detector pasó de 7 a 9 y lo destapó. Por eso es un dibujo
distinto.

Los 7 grupos exactos sorprenden si esperabas 2: los dos pares que el árbol declara, **más los cinco archivos que
`copia-a` y `copia-b` comparten**. Es correcto, y es un buen primer recordatorio de que el detector exacto no
sabe nada de carpetas.

**Los dos pares de carpetas también son correctos.** El anidado se colapsa dentro del padre al *aplicar* —mover
`copia-a` se lleva `copia-a/notas`— pero el documento del escaneo los reporta a los dos, porque los dos son
ciertos. El par que el paso 5 necesita es el de las carpetas padre.

**Y los cinco archivos compartidos salen de una desigualdad, no de un gusto.** Con `s` iguales y uno solo en
`copia-b`, el Dice es `2s / (2s + 1)`; llegar al 90% por default pide `s >= 4.5`. Con tres daba 85.7% y el par
de las padre no existía — el detector sólo veía `notas ↔ notas`, un par de un archivo sin nada de sobra de
ningún lado, que es justo lo contrario de lo que el paso 5 va a mirar.

---

## 1. Que la app tenga permisos de verdad (2 min)

**Elegir la carpeta en el panel del sistema no dispara ningún diálogo, y eso es correcto.** Lo dice el
comentario de `chooseRoot`: *"`NSOpenPanel` is what grants access to it: the user picking a folder is what macOS
treats as consent"*. macOS da acceso a lo que el usuario señaló, sin preguntar y **sin dejar entrada en Ajustes →
Privacidad → Archivos y carpetas**. La primera versión de este documento decía que Escritorio y Documentos
**debían** preguntar; medido, no preguntan, no aparece la app en esa lista, y el escaneo lee todo. Las tres
observaciones son consistentes y el código tenía razón.

Así que la prueba útil no es el panel, es **la lista de raíces recientes**: esa ruta no pasa por el panel del
sistema, así que no trae el consentimiento con ella.

1. `make run`. Debe abrir la **biblioteca de escaneos**.
2. Nuevo escaneo (⌘N) → elige `~/Desktop/demo-duplicate` **por el panel** → escanea. Debe dar **7 grupos** sin
   preguntar nada.
3. **⌘Q para cerrar la app del todo**, `make run` otra vez, ⌘N, y ahora toma la misma carpeta de la lista de
   **recientes** en vez de abrir el panel. Escanea.

**Lo que decide el paso 3:**

| Qué ves | Qué significa |
|---|---|
| Pregunta el permiso | Correcto, y ahí sí debe aparecer en la lista de Ajustes |
| Los grupos, sin preguntar | El consentimiento del panel persistió para esa ruta |
| **0 archivos y ningún aviso** | **El fallo de mayor consecuencia de la app**: un permiso negado que se lee igual que "no hay duplicados" |
| 0 archivos **con el banner** de directorios inaccesibles | Funciona: no pudo entrar y lo dice |

**Qué anotar**: cuál de las cuatro, y si preguntó, si el diálogo salió en tu idioma.

### Lo que salió, medido

**5 grupos sin preguntar**, también desde recientes y tras cerrar la app por completo. (Cinco y no siete: el
árbol de prueba tenía entonces tres archivos compartidos entre las copias y hoy tiene cinco, por #99. El número
se deja como se midió, porque es lo que se midió.) Con eso, y con que la app
no aparezca en Ajustes → Privacidad → Archivos y carpetas, el cuadro cierra: el consentimiento del panel
persiste para esa ruta.

**Y `open` sí entrega la app a Launch Services**: el padre del proceso es `launchd`, no la terminal. Así que la
app es su propio responsable y no está heredando permisos de nadie.

**Conclusión, y es de diseño**: en uso normal **la superficie de TCC de esta app es casi inalcanzable**. La raíz
de un escaneo siempre sale del panel del sistema o de recientes, así que nunca hay una carpeta protegida a la
que la app llegue sin que alguien la haya señalado — que es exactamente por lo que nunca necesita pedir Acceso
Total al Disco.

### Lo único que queda expuesto, y sigue sin probarse

Elegir una carpeta **que contenga** una protegida: escanear `~` hace que la app descienda a `~/Desktop`,
`~/Documents` y `~/Downloads` **sin** que nadie las haya señalado. Ahí TCC sí puede negar, y ahí es donde el
`errorHandler` del walker importa — si se comporta mal, el escaneo devuelve menos archivos y reporta "no
encontré duplicados", indistinguible del éxito.

**Lo que hay que ver**: que al terminar aparezca el banner contando los directorios que no pudo leer. Es un
escaneo largo (cientos de GB), así que va suelto cuando la máquina esté libre.

## 2. Que la biblioteca liste los tres tipos (1 min)

Repite el escaneo con los otros dos detectores (el panel de escaneo los ofrece).

Deben aparecer dos filas nuevas, con el badge de origen **app** y no CLI, y el pie contando lo que la lista
muestra.

**Son tres y no cuatro.** El control de segmentos ofrece Archivos, Carpetas e Imágenes, y el panel de escaneo
ofrece tres detectores. Los **cuatro** que menciona `CLAUDE.md` son los directorios vigilados —`scans/`,
`decisions/`, `folder-scans/`, `similar-scans/`—, que no son lo mismo: `decisions/` cambia el badge de una fila
sin agregar ninguna. La versión anterior de este paso pedía cuatro filas y cuatro detectores; no existen.

**Está mal si**: una fila no aparece hasta reabrir la ventana. El watcher de ese directorio no está enganchado
—pasó con `folder-scans/` y `similar-scans/`— y se lee como "no encontró nada".

### Lo que salió, medido

Las tres filas aparecieron **solas**, sin cerrar ni reabrir la ventana. Sobre `~/demo-duplicate`:

| segmento | contenido de la fila |
|---|---|
| Archivos | 5 grupos, 10 archivos, 23.6 KB recuperables |
| Carpetas | 1 par, 2 carpetas, umbral 90% |
| Imágenes | 1 par de imagen, 1 de video, 4 archivos hasheados, umbral 5 bits |

**Medido sobre el árbol anterior**, el de tres archivos compartidos entre las copias. Con el de hoy los mismos
segmentos dan 7 grupos y 2 pares de carpetas; los números de arriba se dejan como se tomaron. Lo que la corrida
probaba —que las filas aparecen solas— no depende de ellos.

Los 15 archivos de ese árbol contra los 10 de la columna no eran una discrepancia: los otros cinco
—`solo-aqui.txt`, los dos JPEG y los dos MP4— no tienen gemelo **exacto**.

Y elegir la raíz desde **Recientes** tampoco disparó diálogo de permisos, que es la misma observación del paso 1
por el otro camino.

**Lo que sí salió mal es el panel de escaneo, y es #98.** Con una ruta larga, la fila de la carpeta se encima
sobre la de abajo y esconde el cuadrito de **Incluir archivos ocultos**. Sale con los detectores de archivos y
de carpetas, y **no** sale con el perceptual —cuyo checkbox de video ensancha la fila de arriba y con ella la
ventana—, que es justo lo que señala la causa: `rootLabel` pide el ancho de su texto y no cede.

## 3. La revisión exacta: lo que se ve y lo que se puede achicar (5 min)

Doble clic en el escaneo exacto.

1. **La ventana debe poder achicarse.** Arrástrala de la esquina hasta el mínimo. La tabla y el panel de detalle
   deben seguir ahí. *Está mal si* la mitad derecha se vacía: un constraint requerido está ganándole al layout,
   que es el bug que hubo con `height == width` en el panel de imagen.
2. **El nombre truncado va por el medio.** Un grupo con `informe.pdf` y `informe copia.pdf` debe dejar ver los
   dos extremos.
3. **La metadata bajo la vista previa**: tamaño y fecha. Con ⌘⌥I se esconde y vuelve; con ⌘Y abre **Vista
   rápida** a tamaño completo. *Está mal si* el panel de Quick Look abre **vacío**: eso es cableado faltante que
   se ve igual que una vista previa rota.
4. **⌘Z.** Marca una casilla de conservar, confirma con Return —o ⌘Return, que es el equivalente del menú; el
   Return pelado solo cuenta con la lista de archivos enfocada— y deshace con ⌘Z. El ítem **Edición > Deshacer**
   tiene que estar **habilitado**, no gris. *Está mal si* está gris: la ventana no está entregando su
   `UndoManager`, y el deshacer existe siendo invisible.
5. **Mostrar en Finder** (⌘R) sobre un archivo seleccionado.

### Lo que salió, medido

Los cinco puntos pasaron, con la ventana arrastrada hasta ~790 pt de ancho:

| # | qué | qué se vio |
|---|---|---|
| 1 | achicar sin vaciar | la tabla y el panel de detalle siguieron completos |
| 2 | truncado por el medio | `/Users/roger/dem…actos/foto 2.raw` |
| 3 | ⌘⌥I y ⌘Y | la línea de tamaño y fecha se escondió y volvió; Quick Look abrió con nombre, tamaño y fecha |
| 4 | ⌘Z | **Edición > Deshacer** habilitado; ⌘Z y ⌘⇧Z hicieron ida y vuelta |
| 5 | ⌘R | Finder abrió en `exactos` con el archivo resaltado |

**Y el paso destapó #100.** Con las dos casillas de un grupo marcadas —o sea conservar los dos archivos— la
ventana anuncia que liberaría 14.9 KB. No se movería nada: `removalPlan` filtra lo conservado y devuelve cero
candidatos, mientras `plannedReclaimBytes` suma `distinctCopies - 1` sin mirar el conjunto conservado. Es el
número pegado al botón que borra, y es la tercera función sobre el mismo tri-estado que no concuerda con las
otras dos.

**Una sorpresa que no es un bug**: en el grupo de `informe.pdf` el keeper es el archivo **menos** profundo, al
revés de la regla que `CLAUDE.md` describe. Es correcto. `CopyNamePattern` tiene una alternativa en español,
`\s+copia`, así que `subcarpeta/informe copia.pdf` puntúa 1 — y en el orden lexicográfico de `KeeperHeuristic`
el score de copia pesa **antes** que la profundidad.

**Y un falso hallazgo mío, anotado porque volvería a pasar**: dos capturas seguidas parecían mostrar un deshacer
que cambiaba el conjunto conservado sin quitar la decisión. No lo era — habían sido dos pulsaciones, una del menú
y una del teclado. Un estado intermedio fotografiado no distingue "un paso de undo" de "dos", y el repro que sí
lo distingue es leer el pie después de **cada** acción.

## 4. El visor de parecidos: el panel angosto (5 min)

Abre el escaneo perceptual. Verás **cuatro** pares: dos de imagen y dos de video.

1. **Los dos lados deben mostrar fotos distintas.** *Está mal si* se ven idénticas: sería la clave de miniatura
   compartida, y haría que todos los pares parecieran iguales.
2. **La línea de metadata a ancho angosto.** Encoge la ventana hasta ~500 pt. La línea es
   `tamaño · fecha · resolución · codec · duración`; debe truncarse por el **medio**, no empujar la ventana.
   Esto es lo que no se pudo verificar desde código.
3. **El encabezado del par de video** dice qué fracción de cuadros coincide, **no** "difieren N de 64 bits" —
   ese número no existe para un video.
4. **Y el par de `clip-corto.mp4` lo dice completo.** Sus dos clips duran medio segundo, así que con
   `interval = max(dur/9, 0.1)` las marcas van de 0.1 a 0.8 y sólo cuatro caen dentro: el encabezado tiene que
   terminar en **"juzgado con 4 de 8 cuadros"**. El par largo no lo dice porque sus ocho marcas sí caben.
5. **El aviso de clave ambigua.** Decide el par de `foto||rara.jpg` —cualquier decisión sirve— y **cierra la
   ventana**. Debe salir una hoja diciendo que una decisión se guardó con una clave que no se puede volver a
   leer, porque `SimilarPairKey` guarda `a||b` sin escapes. *Está mal si* no aparece: la clave se escribiría de
   todos modos y el CLI la leería como otro par. Un par **sin decidir** no escribe clave, así que no avisa —
   eso es correcto.
6. **⌘Y con un par seleccionado** debe abrir Quick Look con **los dos** lados, y las flechas del panel deben
   caminar entre ellos. Esa es la comparación a tamaño real, y la razón por la que esta app existe en vez del CLI.
7. **⌘R** debe revelar **los dos** archivos en Finder a la vez.

### Lo que salió, medido — cuatro de cinco

| # | qué | qué se vio |
|---|---|---|
| 1 | miniaturas distintas por lado | las dos del par de video muestran **cuadros distintos**: una tiene un `8` en el contador y la otra un `4` |
| 3 | encabezado por fracción de cuadros | "100.00% de los cuadros muestreados coinciden", no una distancia de bits |
| 6 | ⌘Y con los dos lados | Vista rápida abrió con flechas activas y caminó de `clip-original.mp4` a `clip-recodificado.mp4` |
| 7 | ⌘R con los dos archivos | Finder abrió con "2 de 4 seleccionados" |

Los puntos **4 y 5** —el encabezado de pocos cuadros y el aviso de clave ambigua— son nuevos: sus fixtures no
existían cuando se corrió esta pasada, y por eso están sin medir.

Los cuadros distintos del punto 1 son evidencia más fuerte que la que pedía el guion: si la clave de miniatura
estuviera compartida, los dos lados dibujarían el mismo bitmap.

**El punto 2 no se pudo correr, y ese fue el hallazgo #106.** La ventana no bajaba de 1000 pt mientras su
`minSize` declaraba 720, así que no existía el ancho donde esa prueba significa algo. El piso eran los siete
botones del pie en una sola fila —664 pt de decisiones más 314 de acciones—, no la tabla ni las etiquetas, que
ya cedían. Partida en dos filas el piso bajó a **678**, y el mínimo declarado pasó a ser el límite real. Sigue
sin correrse **a ese ancho**.

**Y aquí vivió #97.** El consejo del par de video decía *"Conservar el segundo — mayor bitrate (232 kbps contra
49 kbps), **mayor resolución (320 x 240 contra 640 x 480)**"*. 320×240 no es mayor que 640×480: la guarda que
emite esa razón es `!=` —*difieren*— mientras el caso se llamaba `higherResolution`. Arreglado; verificado en
pantalla después: ahora dice **"menor resolución (320 x 240 contra 640 x 480)"**.

## 5. El visor de carpetas (3 min)

La lista trae **dos** pares. Abre el de **`copia-a ↔ copia-b`, al 90.9%** — el otro es `notas ↔ notas` al 100%,
que no tiene nada de sobra de ningún lado y no sirve para lo que este paso mira. Los dos son ciertos: el anidado
se colapsa dentro del padre al aplicar, no al escanear.

1. El detalle debe listar **`solo-aqui.txt`** como el archivo que solo está en `copia-b`.
2. Al elegir conservar `copia-a`, la ventana debe **avisar antes de aplicar** que mover la otra perdería ese
   archivo. *Está mal si* solo te enteras después, en la lista de rehúsas.
3. La línea de metadata da nombre, conteo y **fecha** de cada lado. No da tamaño, a propósito.

### Lo que salió, medido

Los tres puntos pasaron. El detalle nombró **`solo-aqui.txt`** bajo "Solo en …/copia-b", y al elegir conservar
`copia-a` la ventana avisó en naranja, **antes de aplicar**:

> Mover copia-b perdería 1 archivos que tiene y la otra no.

Con eso queda verificada por primera vez la capacidad que `CLAUDE.md` nombra como la diferencia entre esta app
y el CLI: *lo que el escaneo ya sabe se dice al decidir, no al aplicar*. Y no se habría podido correr sin #99,
que es lo que hizo existir ese par.

**El aviso destapó dos cosas.** El *"1 archivos"* es #108 —en español el verbo también concuerda, así que
`apply.headline` decía "Se moverían 1 archivo"— y ya está arreglado. Y presionar el botón dejó la ventana en
blanco: sin selección, sin detalle, sin aviso y sin conteo, o sea sin una sola señal de que la decisión se
registró. Ese es #107: `mutate` recarga la tabla, `reloadData()` borra la selección, y sólo se restauraba
cuando había fila siguiente — en el último par no la hay, y en un escaneo de un solo par el único par siempre
es el último.

## 6. Aplicar y deshacer, que es lo que borra archivos (8 min)

Sobre el escaneo **exacto**, decide dos grupos y presiona **Simular y aplicar**.

1. La hoja debe listar **exactamente** los archivos que se moverían, y ninguno de los que conservas.
2. **El botón de detener se queda vivo** durante el apply, y cerrar la hoja mientras corre **detiene sin
   cerrar**.
3. La línea de progreso debe decir **verificando** y luego **moviendo**, con el archivo nombrado.
4. Al terminar: abre la Papelera en Finder. Los archivos deben estar ahí, y **"Devolver" de Finder** debe
   regresarlos a su sitio. Devuelve uno así, a mano.
5. **Sesiones > Historial de sesiones…** debe listar la sesión con su fecha, cuántos archivos movió y cuántos
   volvieron. Deshaz la sesión desde ahí y confirma que el resto de los archivos regresan.
6. **Sesiones > Limpiar sesiones ya deshechas…** debe ofrecer exactamente esa sesión, con sus conteos, y no
   ofrecer ninguna que aún tenga archivos sin devolver.

**Está mal si**: un fallo aparece como `contentChanged(path: "…")`. Eso es un enum crudo; debe leerse como una
frase.

### Lo que salió, medido

La cadena completa corrió: dos archivos decididos, simulados, movidos, uno devuelto desde Finder, la sesión
deshecha desde el historial y el registro podado.

| # | qué se vio |
|---|---|
| 1 | la hoja listó **exactamente** `foto 2.raw` y `subcarpeta/informe copia.pdf`, ninguno de los conservados |
| 2 | **no se pudo observar**: dos archivos se mueven en menos de un tick del timer de 10 Hz |
| 3 | tampoco, por lo mismo |
| 4 | los dos estaban en el basurero; el "Sacar del basurero" de Finder devolvió uno |
| 5 | el deshacer dijo *"1 ya estaban de vuelta, byte por byte"* y restauró el otro |
| 6 | la hoja de poda apareció con sus conteos |

Los puntos 2 y 3 **no son alcanzables con este árbol** y eso no es una omisión: la etiqueta la escribe un
`Timer` a 10 Hz y dos archivos terminan antes del primer tick. Verlos pide un apply de carpeta con cientos de
archivos, que este árbol no tiene.

**Tres hallazgos salieron de aquí.**

**#100** — con las dos casillas de un grupo marcadas, la ventana anunciaba que liberaría 14.9 KB. No se movía
nada: `removalPlan` filtraba lo conservado y devolvía cero candidatos, mientras `plannedReclaimBytes` sumaba
`distinctCopies - 1` sin mirar el conjunto conservado. Tres lugares llevaban una copia de la misma regla y una
de esas respuestas mueve archivos. Verificado en pantalla después del arreglo: `se liberarían 0 B`.

**#113** — el archivo devuelto con Finder quedaba contado como no devuelto **para siempre**, aunque el propio
deshacer hubiera verificado que estaba en su lugar byte por byte. Sólo lo que el runner *movía* recibía su
`undone_at`, y la poda exige `restoredCount >= movedCount`, así que **Limpiar** se quedaba en gris. Lo irónico
es que la hoja de aplicar es la que invita a usar Finder.

**#111** — confirmar un grupo no tenía botón. Es la acción más usada de la app —una por grupo, 880 veces en un
escaneo real— y sólo existía como ítem de menú y atajo. Y sin confirmar no se mueve nada, así que se pueden
recorrer los 880 grupos aprobando sugerencias y llegar a un aplicar vacío. Lo reportó el uso real, con la frase
*"si no sirven los cmd return no se debería poner mejor un botón"*.

**Y una falsa alarma que vale anotar**: se reportó que ⌘↩ no funcionaba. No era cierto — se estaba presionando
⌘ con **retroceso** en vez de con **entrar**, porque la instrucción decía "⌘Return" en un teclado rotulado en
español. Llegué a abrir el issue afirmando que el atajo estaba roto, y a aportar como evidencia un
`performKeyEquivalent` sintetizado del arnés que "aceptaba la tecla sin correr la acción" — un artefacto de que
el arnés no es un entorno de eventos fiel. Corregido en el issue.

## 7. Los dos idiomas (5 min)

Ajustes del sistema → General → Idioma y región → pon el otro idioma primero → **relanza la app**.

Recorre otra vez los pasos 3 y 4 buscando **una sola cosa**: texto que salga como su propia clave
(`similar.header.image`, `apply.failure.missing`). El modo `l10n` compara las dos tablas y escanea los sitios de
llamada, pero **las claves interpoladas se enumeran a mano**, así que un renombre a medias solo se ve aquí.

**Y los tamaños de bytes deben verse igual en los dos idiomas**: `512 B`, `1.0 KB`, `3.5 MB`, con **punto**. Eso
es interop con el CLI, no una preferencia regional.

### Lo que salió, medido

**Ninguna clave cruda en ninguno de los dos idiomas**, y los tamaños con punto en los dos: `14.9 KB`, `8.6 KB`,
`8 B`.

La hoja de aplicar, con un solo grupo decidido, en los dos idiomas:

```
Se movería 1 archivo al basurero, liberando 14.9 KB
… El "Sacar del basurero" de Finder funciona con todo lo que se mueve así …
[Cancelar]  [Mover al basurero]

1 file would move to the Trash, freeing 14.9 KB
… Finder's Put Back works on everything moved this way …
[Cancel]  [Move to Trash]
```

Ese par de frases es lo que cierra dos arreglos a la vez, y el caso singular salió porque se decidió **un solo**
grupo.

**#108** — el plural. Y era peor que el sustantivo: en español el verbo también concuerda, así que el titular
decía *"Se **moverían** 1 archivo"* y el de carpetas *"1 carpeta **irían** al basurero"*. Seis claves pasaron a
`Localizable.stringsdict` con la cláusula entera dentro de cada variante.

**#114** — la app decía **Papelera** y **Devolver**, que es español peninsular, mientras este macOS corre en
`es_MX` y su Finder dice **"Sacar del basurero"**. Trece cadenas más cinco descripciones de TCC —las que macOS
imprime dentro de sus propios diálogos de permisos— nombraban un lugar y un comando que no existen para quien
usa la app. Se descubrió porque la instrucción decía *"clic derecho → Devolver"* y la respuesta fue *"no veo la
opción devolver"*.

**#119** — la hoja de poda decía *"1 sesiones todavía tienen"*, y con todas las sesiones podables imprimía *"0
sesiones todavía tienen"*, una cláusula sobre un conjunto vacío. Se partió en dos oraciones, cada una con su
conteo, y la segunda ahora desaparece cuando no tiene nada que decir.

## 8. Los dos caminos de lanzamiento (2 min)

Repite el paso 1 **desde la terminal**:

```bash
./build/Duplicate.app/Contents/MacOS/Duplicate
```

Si escanea algo que por Launch Services te pidió permiso, esa diferencia **es** el efecto de TCC: la app lanzada
desde la terminal hereda los permisos de la terminal. Los dos resultados no significan lo mismo, y hay que
reportarlos por separado.

### Lo que salió, medido

**Sin diálogo y 7 grupos**, o sea idéntico al camino por Launch Services.

Que coincidan **no prueba que los permisos sean iguales**: prueba que esta carpeta no necesita ninguno. El
árbol de demo vive en `~`, que no es un directorio protegido, así que ninguno de los dos caminos tiene nada que
pedir. La diferencia que este paso existe para exponer sólo aparecería sobre una carpeta protegida, y eso
sigue sin correrse por la misma razón que el paso 1: es el escaneo de `~` completo, cientos de GB.

Los dos resultados quedan escritos por separado de todos modos, que es la regla.

---

## 9. Un fallo a propósito (3 min)

Los pasos anteriores nunca fallan: todos los archivos del árbol existen y están intactos. Esta es la única
forma de leer las frases de rehúsa, que son lo que alguien tiene que entender **después** de borrar algo.

1. Escanea `~/demo-duplicate` con **Archivos idénticos**.
2. Decide el **Grupo 1** y presiona **Confirmar y siguiente**.
3. **Sin cerrar la ventana**, en la terminal:

```bash
echo "cambiado" >> ~/demo-duplicate/exactos/foto\ 2.raw
```

4. Presiona **Simular y aplicar...** y luego **Mover al basurero**.

El archivo se re-hashea justo antes de moverse, así que la app debe **rehusarlo** y dejarlo donde está.

**Qué mirar**: que la rehúsa se lea como una frase — algo como *"lo que está ahí ya no es lo que el escaneo
vio"*.

❌ **Está mal si** sale `contentChanged(path: "…")`. Eso es un caso de enum crudo, y ya pasó una vez.

## 10. La barra con etapa (3 min)

Necesita su propio árbol: con dos archivos el apply termina antes del primer tick del timer de 10 Hz.

```bash
python3 scripts/make-demo-tree.py ~/demo-grande --carpeta-grande
```

1. Escanea `~/demo-grande` con **Carpetas parecidas**.
2. Abre el escaneo, selecciona el par `original ↔ respaldo` y presiona **Conservar la primera**.
3. **Simular y aplicar...** y luego el botón azul.

**Qué mirar**, mientras corre:

- la línea dice **verificando** y después **moviendo**, con el archivo nombrado
- el **botón de detener sigue vivo**
- cerrar la hoja a media corrida **detiene sin cerrar**

Son 4,000 archivos por lado, así que verificar toma alrededor de un segundo — diez ticks de la barra.

4. Deshaz la sesión desde **Sesiones › Historial de sesiones…**

## Al terminar

```bash
rm -rf ~/demo-duplicate ~/demo-grande
```

Y si algún paso falló, lo útil no es "no funciona" sino **qué esperabas y qué viste** — es lo que convierte una
observación en un test.
