# Manual de uso

Duplicados (Duplicate en inglés) encuentra archivos repetidos en una carpeta y te deja decidir qué conservar. Busca
de tres maneras:

- **Archivos idénticos**: byte por byte, aunque tengan otro nombre.
- **Carpetas parecidas**: dos carpetas que tienen casi los mismos archivos, como una copia de respaldo vieja.
- **Imágenes y videos parecidos**: la misma foto en otro tamaño o formato, o el mismo video recodificado.

**Nada se borra.** Lo que decides quitar va al basurero, y cada vez que aplicas queda registrado para poder
deshacerlo, desde la app o con "Sacar del basurero" en Finder.

Las capturas son de la app en español sobre un árbol de prueba en `/tmp/duplicate-ui`. Las genera `make ui`, así que
se pueden volver a sacar cuando la interfaz cambia.

1. [Instalar y abrir](#1-instalar-y-abrir)
2. [La biblioteca](#2-la-biblioteca)
3. [Escanear una carpeta](#3-escanear-una-carpeta)
4. [Revisar archivos idénticos](#4-revisar-archivos-idénticos)
5. [Simular y aplicar](#5-simular-y-aplicar)
6. [Deshacer](#6-deshacer)
7. [Carpetas parecidas](#7-carpetas-parecidas)
8. [Imágenes y videos parecidos](#8-imágenes-y-videos-parecidos)
9. [Atajos](#9-atajos)
10. [Dónde quedan tus datos](#10-dónde-quedan-tus-datos)
11. [Si algo sale mal](#11-si-algo-sale-mal)

## 1. Instalar y abrir

Se compila en tu Mac (macOS 15 o superior); los pasos están en el [README](../README.md#instalación). La app no está
notarizada por Apple, así que la primera vez macOS puede decir que no puede verificar al desarrollador: clic derecho
sobre la app → **Abrir**, o en Ajustes del Sistema → Privacidad y Seguridad → **Abrir de todos modos**.

## 2. La biblioteca

Es la ventana con la que abre la app. La primera vez está vacía y te dice cómo empezar:

![Biblioteca vacía](https://raw.githubusercontent.com/rogalvil/duplicate/04d73cf7d119be929c5f4d5d1114c928355e25c4/manual/library-empty-laptop.png)

La ruta de abajo es dónde guarda los escaneos ([sección 10](#10-dónde-quedan-tus-datos)). Cada escaneo que hagas
aparece aquí como una fila:

![Biblioteca con un escaneo](https://raw.githubusercontent.com/rogalvil/duplicate/04d73cf7d119be929c5f4d5d1114c928355e25c4/manual/library-files-laptop.png)

- **Archivos / Carpetas / Imágenes** arriba cambia entre los escaneos de cada tipo.
- **Recuperable** es el espacio que liberarías conservando un archivo de cada grupo. Si aparece con `≤` delante es
  una cota: en un disco que no es APFS la app no puede saber si dos archivos comparten almacenamiento.
- **Doble clic** en una fila abre su revisión. El **clic derecho** abre la carpeta escaneada, muestra el archivo del
  escaneo en Finder, copia su id o borra el escaneo (el escaneo, no tus archivos).
- En la pestaña Archivos puedes ordenar y filtrar por carpeta.

La lista se actualiza sola: un escaneo nuevo aparece sin apretar nada.

## 3. Escanear una carpeta

**⌘N** (o el botón **+**) abre el panel de escaneo. Primero eliges qué buscar:

| Archivos idénticos | Carpetas parecidas | Imágenes parecidas |
|---|---|---|
| ![Panel, archivos idénticos](https://raw.githubusercontent.com/rogalvil/duplicate/a29d029c93a6e68ef5f532e916130bef26afadcd/manual/scan-exact-open-v2.png) | ![Panel, carpetas](https://raw.githubusercontent.com/rogalvil/duplicate/a29d029c93a6e68ef5f532e916130bef26afadcd/manual/scan-folders-open-v2.png) | ![Panel, imágenes](https://raw.githubusercontent.com/rogalvil/duplicate/a29d029c93a6e68ef5f532e916130bef26afadcd/manual/scan-similar-open-v2.png) |

1. **Buscar**: el tipo. Carpetas pide además qué tan parecidas (90 % por default). Imágenes pide cuántos bits de
   64 pueden diferir (5 por default) y qué revisar: **Imágenes y videos**, **Solo imágenes** o **Solo videos**.
   Los videos son la parte lenta, así que separarlos sirve para una pasada rápida por las fotos o por las películas.
   Con **Solo videos** el menú de bits se apaga: es una distancia entre imágenes.
2. **Elegir carpeta…**: la carpeta a revisar. **Recientes…** guarda las últimas diez.
3. Las opciones, todas apagadas salvo la caché:
   - **Incluir archivos ocultos**: apagado, porque cientos de `.DS_Store` idénticos tapan lo que importa.
   - **Entrar a los paquetes**: apagado, porque sacar un archivo de un `.app` o de una fototeca la rompe.
   - **Usar la caché de hashes**: un segundo escaneo de la misma carpeta es mucho más rápido.
   - **Ignorar archivos menores a**: 1 B, o sea que los archivos vacíos no cuentan.
4. **Empezar**.

Mientras escanea, el panel dice en qué va —listando archivos, comparando candidatos, leyendo contenidos, agrupando,
guardando— con los contadores y el archivo actual. **Cancelar** lo detiene sin dejar nada a medias. Al terminar, el
escaneo aparece en la biblioteca.

**Permisos.** Elegir la carpeta en el panel es el permiso: macOS deja leerla sin preguntar. Si escaneas una carpeta
que *contiene* otras protegidas (por ejemplo tu carpeta personal), macOS puede preguntar por algunas, y si no da
acceso, la app te avisa cuántas carpetas no pudo leer: el resultado está incompleto, no vacío. La app nunca pide
Acceso Total al Disco, y `~/Library` no se escanea salvo que la elijas tú: ahí casi todo son cachés de otras apps.

## 4. Revisar archivos idénticos

Doble clic en un escaneo de archivos abre su revisión:

![Revisión de archivos idénticos](https://raw.githubusercontent.com/rogalvil/duplicate/69139c9ab0a8fb1d91353156be915ef383e1201f/manual/review-laptop-v2.png)

- **A la izquierda**, los grupos: archivos con exactamente el mismo contenido. ✓ es un grupo decidido, ✗ uno saltado.
- **Al centro**, los archivos del grupo. La casilla **Conservar** dice cuál se queda; la app marca una sugerencia
  (el archivo más profundo que no parece una copia), pero **una sugerencia no es una decisión** hasta que confirmas.
  La columna **Nota** avisa "parece una copia", "ya no está", "cambió desde el escaneo", "no se puede leer" o
  "mismo almacenamiento que el que se conserva" (un hardlink o un clon: quitarlo no libera nada, así que no se
  ofrece).
- **A la derecha**, la vista previa del archivo seleccionado, con su tamaño y fecha. **⌘Y** lo abre a tamaño completo.
  El icono es el que tu Mac usa para ese tipo de archivo.
- **Confirmar y siguiente** (o ⏎) guarda la decisión del grupo y pasa al siguiente. **⇧⌘K** lo salta.
- **Arriba a la izquierda**, filtros: tamaño mínimo, **Sin decidir**, y **Que todavía existen** después de
  **Revisar el disco**, que comprueba en segundo plano qué archivos siguen ahí.
- **Abajo**, cuántos decidiste, saltaste y te faltan, y cuánto se liberaría.

**Solo se guarda lo que decidiste.** Un grupo que no abriste o que saltaste no queda registrado ni a favor ni en
contra, y aplicar no lo toca. ⌘Z deshace decisiones; ⌘S guarda (también se guarda al simular y al cerrar).

Para muchos grupos a la vez, **Aceptar los N sin decidir** acepta la sugerencia de todos los grupos que la lista
muestra y nadie ha decidido ni saltado. Sin filtros son todos los del escaneo; con un filtro, solo los que deja
ver. Antes de hacerlo dice cuántos grupos y cuánto espacio, y **⌘Z** lo deshace de una vez. Para escoger grupos
sueltos, selecciona varios en la lista y usa **Grupo → Aceptar la sugerencia en los grupos seleccionados…**.

## 5. Simular y aplicar

**Simular y aplicar…** abre una hoja que dice qué pasaría, sin mover nada todavía:

![Simulación](https://raw.githubusercontent.com/rogalvil/duplicate/04d73cf7d119be929c5f4d5d1114c928355e25c4/manual/apply-exact.png)

**Mover al basurero** lo hace. Antes de mover cada archivo, la app lo vuelve a comprobar: un archivo idéntico se
vuelve a leer, un par de imágenes se vuelve a comparar, y una carpeta solo se mueve si todo lo que tiene está
idéntico en la que se conserva. Lo que cambió desde el escaneo se deja en paz. Mientras trabaja dice si está
verificando o moviendo, y **Detener** para a la mitad sin perder el registro de lo que ya movió.

Al terminar dice qué se movió y cuánto liberó, con **Deshacer esta sesión** a la mano:

![Aplicación terminada](https://raw.githubusercontent.com/rogalvil/duplicate/04d73cf7d119be929c5f4d5d1114c928355e25c4/manual/apply-similar-done.png)

Y si algo no pasó la comprobación, lo dice con la razón. Aquí una carpeta no se movió porque tenía un archivo que la
otra no:

![Una carpeta rechazada](https://raw.githubusercontent.com/rogalvil/duplicate/04d73cf7d119be929c5f4d5d1114c928355e25c4/manual/apply-folders-done.png)

Si cambias una decisión después de simular, hay que simular otra vez: lo que apruebas es exactamente lo que se mueve.

## 6. Deshacer

Cada vez que aplicas es una **sesión**. **Sesiones → Historial de sesiones…** las lista:

![Historial de sesiones](https://raw.githubusercontent.com/rogalvil/duplicate/04d73cf7d119be929c5f4d5d1114c928355e25c4/manual/history-laptop.png)

- **Deshacer esta sesión…** devuelve a su lugar todo lo que esa sesión movió, aunque no sea la última.
- **Sesiones → Deshacer la última sesión…** hace lo mismo con la más reciente que tenga algo por devolver.
- Deshacer **nunca sobrescribe**: si en el lugar original ya hay otro archivo, lo deja y te dice por qué.
- **Limpiar…** borra el registro de las sesiones que ya devolviste por completo.

También puedes sacar archivos uno por uno con "Sacar del basurero" en Finder. ⌘Z no deshace una sesión: deshace
decisiones de la revisión, que es otra cosa.

## 7. Carpetas parecidas

Un escaneo de carpetas muestra pares de carpetas con casi el mismo contenido:

![Carpetas parecidas](https://raw.githubusercontent.com/rogalvil/duplicate/c3942a09903aecb2e3bd2d9a56601fb0f6698c68/manual/folder-pair-laptop-v2.png)

- Arriba, cada par con qué tan parecidas son y cuántos archivos tienen iguales y distintos.
- Abajo, el detalle: qué hay **solo** en una, solo en la otra, y qué tiene el mismo nombre con otro contenido.
- **Mientras decides**, un aviso en naranja dice qué perderías: "Mover copia-b perdería 1 archivo que tiene y la
  otra no".
- **Conservar la primera / la segunda / las dos**, o **Saltar**. Cada decisión se guarda sola.
- **Simular y aplicar…** funciona como en la [sección 5](#5-simular-y-aplicar).

## 8. Imágenes y videos parecidos

Un escaneo de imágenes muestra **grupos**: todos los archivos que se parecen entre sí, juntos. Tres copias del mismo
video son un grupo, y se deciden de una vez:

![Imágenes parecidas](https://raw.githubusercontent.com/rogalvil/duplicate/b53f2523b8a4dc4b28f4df6e63071e56545c0be6/manual/similar-image-laptop-v2.png)

- **Arriba**, filtros: qué tan parecidas, imágenes o videos o los dos, y **Sin decidir**. Con «idénticas», solo
  aparecen los grupos donde todos los archivos son iguales entre sí.
- **La lista de grupos** dice qué tan parecidos son, cuántos archivos tiene cada uno y qué se decidió («conserva 1 de
  3»).
- **A la izquierda del grupo**, sus archivos con la casilla **Conservar**, como en la revisión de idénticos. La app
  marca una sugerencia, pero **una sugerencia no es una decisión** hasta que confirmas. La barra espaciadora marca o
  desmarca el archivo seleccionado.
- **Los dos lados** comparan el mejor archivo que se conserva (izquierda) con el que seleccionas en la lista
  (derecha). Debajo de cada uno, su tamaño, fecha, resolución y, en videos, codec y duración. La línea de abajo dice
  cuánto se parecen esos dos: en imágenes, cuántos bits de 64 difieren; en videos, qué parte de los cuadros
  muestreados coinciden.
- **Sugerido** dice cuál conviene conservar y por qué. **La calidad pesa primero**: un codec más eficiente, que uno
  sea un tráiler del otro, más resolución o, a igual resolución, más bytes. Solo si empatan en calidad decide el
  nombre: el que parece copia pierde.
- **Confirmar y siguiente** (o ⏎) guarda el grupo y pasa al siguiente; **Conservar todos** deja el grupo como está;
  **Saltar** (⇧⌘K) lo pasa sin decidir.
- **Aceptar los N sin decidir** acepta la sugerencia de los grupos que la lista muestra y nadie ha decidido, y antes
  te dice cuántos archivos y bytes son.

**Un archivo solo se descarta si se parece a uno que se conserva.** A veces A se parece a B y B a C, pero A y C no
se parecen: el grupo lo avisa, y si desmarcas de modo que un archivo quede sin ningún parecido entre los que se
conservan, la app no confirma y te dice cuál es.

Los videos se comparan por cuadros:

![Videos parecidos](https://raw.githubusercontent.com/rogalvil/duplicate/a29d029c93a6e68ef5f532e916130bef26afadcd/manual/similar-video-laptop-v3.png)

Las decisiones se guardan por par, el formato que también lee el CLI. Si un escaneo trae decisiones por par que no
cuadran entre sí (de una versión anterior de la app, o del CLI), el grupo dice «sin cuadrar» y confirmarlo las
reemplaza. Al cerrar la ventana, la app avisa si quedó alguna contradicción; esos archivos quedan fuera al aplicar
hasta que decidas su grupo.

## 9. Atajos

| Atajo | Qué hace | Dónde |
|---|---|---|
| ⌘N | Nuevo escaneo | en todas partes |
| espacio | Conservar o descartar el archivo seleccionado | revisión de archivos |
| ⏎ | Confirmar y pasar al siguiente grupo | revisión de archivos |
| ⌘⏎ | Confirmar y siguiente, desde el menú Grupo | revisión de archivos |
| ⇧⌘K | Saltar el grupo | revisión de archivos |
| ⌘[ / ⌘] | Grupo anterior / siguiente | revisión de archivos |
| ⇧⌘D | Simular la aplicación | revisión de archivos |
| ⌘S | Guardar decisiones | revisión de archivos |
| ⌘Z / ⇧⌘Z | Deshacer / rehacer una decisión | los tres visores |
| ⌘Y | Vista rápida a tamaño completo | los tres visores |
| ⌘R | Mostrar en Finder | los tres visores |
| ⌥⌘I | Mostrar u ocultar la metadata | los tres visores |
| ⌘W | Cerrar la ventana | en todas partes |

Deshacer una sesión no tiene atajo a propósito: devolver cuatro mil archivos no debería pasar por un ⌘Z.

## 10. Dónde quedan tus datos

- **Escaneos, decisiones y el registro de sesiones**: `~/.local/state/rav/duplicate/`, en JSON legible. El formato
  está en [`FORMATO.md`](FORMATO.md).
- **Cachés de hashes**: `~/Library/Caches/com.rogalvil.duplicate/`. macOS las puede borrar si falta espacio; lo
  único que se pierde es tiempo en el siguiente escaneo.
- **Carpetas recientes**: `~/Library/Application Support/com.rogalvil.duplicate/`.

Desinstalar la app (`make uninstall`) no toca tus escaneos ni tus decisiones.

## 11. Si algo sale mal

| Qué pasa | Qué hacer |
|---|---|
| macOS dice que no puede verificar al desarrollador | Clic derecho → Abrir, o Ajustes → Privacidad y Seguridad → Abrir de todos modos |
| macOS pide permiso de carpetas después de cada actualización | La app se compiló sin el certificado local: `./scripts/make-signing-cert.sh` una vez y vuelve a instalar |
| Un escaneo terminó con el aviso de carpetas que no se pudieron leer | macOS negó el acceso a esas carpetas. Dalo en Ajustes → Privacidad y Seguridad → Archivos y carpetas, **cierra la app** y vuelve a escanear: un permiso nuevo no aplica a la app que ya está abierta |
| Un escaneo sale marcado "Rutas relativas" en la biblioteca | Lo escribió una herramienta de terminal con una raíz relativa; la app no puede saber a qué carpeta se refiere y no actúa sobre él |
| ⌘Q no cierra la app | Hay una hoja de aplicar abierta: ciérrala primero |
| El escaneo en un disco externo va lento | A propósito: lee de a dos archivos para que un disco que gira no salte de un lado a otro |
