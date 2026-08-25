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
| exactos | **5 grupos** sobre 15 archivos |
| parecidos | **1 par de imagen y 1 par de video**, 4 archivos hasheados |
| carpetas | **1 par** sobre 7 directorios |

Los 5 grupos exactos sorprenden si esperabas 2: los dos pares que el árbol declara, **más los tres archivos que
`copia-a` y `copia-b` comparten**. Es correcto, y es un buen primer recordatorio de que el detector exacto no
sabe nada de carpetas.

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
2. Nuevo escaneo (⌘N) → elige `~/Desktop/demo-duplicate` **por el panel** → escanea. Debe dar **5 grupos** sin
   preguntar nada.
3. **⌘Q para cerrar la app del todo**, `make run` otra vez, ⌘N, y ahora toma la misma carpeta de la lista de
   **recientes** en vez de abrir el panel. Escanea.

**Lo que decide el paso 3:**

| Qué ves | Qué significa |
|---|---|
| Pregunta el permiso | Correcto, y ahí sí debe aparecer en la lista de Ajustes |
| 5 grupos sin preguntar | El consentimiento del panel persistió para esa ruta |
| **0 archivos y ningún aviso** | **El fallo de mayor consecuencia de la app**: un permiso negado que se lee igual que "no hay duplicados" |
| 0 archivos **con el banner** de directorios inaccesibles | Funciona: no pudo entrar y lo dice |

**Qué anotar**: cuál de las cuatro, y si preguntó, si el diálogo salió en tu idioma.

## 2. Que la biblioteca liste los cuatro tipos (1 min)

Repite el escaneo con los otros tres detectores (el panel de escaneo los ofrece).

Deben aparecer cuatro filas nuevas, con el badge de origen **app** y no CLI, y el pie contando lo que la lista
muestra.

**Está mal si**: una fila no aparece hasta reabrir la ventana. El watcher de ese directorio no está enganchado
—pasó con `folder-scans/` y `similar-scans/`— y se lee como "no encontró nada".

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
4. **⌘Z.** Marca una casilla de conservar, confirma con Return, y deshace con ⌘Z. El ítem **Edición > Deshacer**
   tiene que estar **habilitado**, no gris. *Está mal si* está gris: la ventana no está entregando su
   `UndoManager`, y el deshacer existe siendo invisible.
5. **Mostrar en Finder** (⌘R) sobre un archivo seleccionado.

## 4. El visor de parecidos: el panel angosto (5 min)

Abre el escaneo perceptual. Verás el par de imagen y el de video.

1. **Los dos lados deben mostrar fotos distintas.** *Está mal si* se ven idénticas: sería la clave de miniatura
   compartida, y haría que todos los pares parecieran iguales.
2. **La línea de metadata a ancho angosto.** Encoge la ventana hasta ~500 pt. La línea es
   `tamaño · fecha · resolución · codec · duración`; debe truncarse por el **medio**, no empujar la ventana.
   Esto es lo que no se pudo verificar desde código.
3. **El encabezado del par de video** dice qué fracción de cuadros coincide, **no** "difieren N de 64 bits" —
   ese número no existe para un video. Y si el clip fuera corto diría "juzgado con 4 de 8 cuadros".
4. **⌘Y con un par seleccionado** debe abrir Quick Look con **los dos** lados, y las flechas del panel deben
   caminar entre ellos. Esa es la comparación a tamaño real, y la razón por la que esta app existe en vez del CLI.
5. **⌘R** debe revelar **los dos** archivos en Finder a la vez.

## 5. El visor de carpetas (3 min)

1. El detalle debe listar **`solo-aqui.txt`** como el archivo que solo está en `copia-b`.
2. Al elegir conservar `copia-a`, la ventana debe **avisar antes de aplicar** que mover la otra perdería ese
   archivo. *Está mal si* solo te enteras después, en la lista de rehúsas.
3. La línea de metadata da nombre, conteo y **fecha** de cada lado. No da tamaño, a propósito.

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

## 7. Los dos idiomas (5 min)

Ajustes del sistema → General → Idioma y región → pon el otro idioma primero → **relanza la app**.

Recorre otra vez los pasos 3 y 4 buscando **una sola cosa**: texto que salga como su propia clave
(`similar.header.image`, `apply.failure.missing`). El modo `l10n` compara las dos tablas y escanea los sitios de
llamada, pero **las claves interpoladas se enumeran a mano**, así que un renombre a medias solo se ve aquí.

**Y los tamaños de bytes deben verse igual en los dos idiomas**: `512 B`, `1.0 KB`, `3.5 MB`, con **punto**. Eso
es interop con el CLI, no una preferencia regional.

## 8. Los dos caminos de lanzamiento (2 min)

Repite el paso 1 **desde la terminal**:

```bash
./build/Duplicate.app/Contents/MacOS/Duplicate
```

Si escanea algo que por Launch Services te pidió permiso, esa diferencia **es** el efecto de TCC: la app lanzada
desde la terminal hereda los permisos de la terminal. Los dos resultados no significan lo mismo, y hay que
reportarlos por separado.

---

## Al terminar

```bash
rm -rf ~/demo-duplicate
```

Y si algún paso falló, lo útil no es "no funciona" sino **qué esperabas y qué viste** — es lo que convierte una
observación en un test.
