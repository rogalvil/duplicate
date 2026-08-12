# Cómo trabajar en este repo

## Requisitos

Xcode es gratis y suficiente. No hace falta cuenta de pago de Apple Developer para compilar y correr
esto localmente — el programa de 99 USD al año solo importa para distribuir a otras personas sin
advertencias de Gatekeeper.

```bash
swift --version              # 6.x
xcrun --show-sdk-version
xcrun swift-format --version # viene con la toolchain
xcrun --find llvm-cov        # viene con la toolchain
python3 --version            # solo para el gate de cobertura
```

El deployment target es macOS 15, declarado en `Package.swift`. Lo exigen `Atomic` y `Mutex` de
`Synchronization`, sobre los que están los contadores de progreso del escáner.

## Todo pasa por `make`

Nadie debería tener que recordar flags:

```bash
make            # compila, arma y firma build/Duplicate.app
make build      # solo compilar (CONFIG=debug)
make bundle     # arma el .app alrededor del binario
make sign       # firma, prefiriendo el certificado self-signed estable
make install    # copia a /Applications, con fallback a ~/Applications
make uninstall
make run        # por Launch Services
make run-debug  # en primer plano, con stdout visible
make test
make coverage   # tests + piso de 80% sobre Core
make fmt        # reescribe con swift-format
make lint       # falla ante cualquier desvío de formato
make selftest MODE=<modo>
make selftest-all
make clean
make help
```

La identidad del bundle vive en las variables del `Makefile` y se sustituye en
`Resources/Info.plist`, así que versión, identificador y OS mínimo están definidos en exactamente un
lugar.

## El certificado de firma no es opcional

Córrelo una vez por máquina:

```bash
./scripts/make-signing-cert.sh
```

Con firma ad-hoc el requisito designado de la app es:

```
designated => cdhash H"2ea8395e..."
```

Atado a los bytes exactos del binario. TCC guarda ese requisito, así que **cada cambio de código hace
que macOS trate a la app como otra distinta** y se pierden los permisos de carpeta. Con un
certificado self-signed estable se vuelve:

```
designated => identifier "com.rogalvil.duplicate" and certificate leaf = H"003086..."
```

Atado a la identidad, y los rebuilds conservan los permisos. Esta app lee árboles enteros de
directorios, así que acumula permisos de Escritorio, Documentos, Descargas y volúmenes externos.
Re-otorgar todos después de cada build es lo que hace que valgan los cinco minutos.

### Dos trampas si lo automatizas por tu cuenta

- **OpenSSL 3 escribe PKCS#12 con un MAC que el importador de Apple rechaza**, reportando
  `MAC verification failed during PKCS12 import (wrong password?)` — que no es un problema de
  contraseña. Hay que forzar `-macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES`.
- **`add-trusted-cert` necesita `-r trustRoot`**, no `trustAsRoot`; un certificado self-signed es su
  propia raíz. El equivocado falla con `One or more parameters passed to a function were not valid`.

Después de cambiar de ad-hoc, limpiar los registros viejos para que Ajustes del Sistema no muestre una
entrada que ya no coincide:

```bash
tccutil reset SystemPolicyDesktopFolder com.rogalvil.duplicate
tccutil reset SystemPolicyDocumentsFolder com.rogalvil.duplicate
tccutil reset SystemPolicyDownloadsFolder com.rogalvil.duplicate
tccutil reset SystemPolicyRemovableVolumes com.rogalvil.duplicate
```

## Permisos: qué verifica cada forma de correr la app

Mismo binario, misma firma, distinto lanzador:

| Cómo se lanza | Resultado |
|---|---|
| directo desde la shell (`make run-debug`, `make selftest`) | hereda los permisos de la terminal |
| por Launch Services (`make run`, doble click) | la app es su propio proceso responsable |

Desde la terminal, macOS atribuye la petición a la terminal, que ya tiene permisos, y la app los
hereda. Por Launch Services la app necesita su propia concesión.

Consecuencia práctica: **un `make selftest` verde no dice nada sobre el estado de TCC de la app.** Los
dos hechos son verdad y ninguno implica el otro. Al reportar en un PR, reportarlos por separado.

## Estructura

```
Sources/DuplicateCore/     lógica pura, testeable, con piso de cobertura del 80%
Sources/Duplicate/         glue de AppKit; no importable desde tests
Tests/DuplicateCoreTests/  un archivo por archivo de Core
Resources/                 Info.plist plantilla, en.lproj, es.lproj
scripts/                   gate de cobertura, certificado de firma
docs/ARCHITECTURE.md       decisiones, y las alternativas que se descartaron
```

Un `executableTarget` de SwiftPM **no se puede importar desde un target de test**. Cualquier cosa que
viva en el ejecutable es permanentemente no testeable. Antes de escribir lógica nueva, preguntarse si
puede vivir en Core.

## Tests

Swift Testing, no XCTest. Un archivo de test por archivo de Core.

El nombre de un test dice qué se rompe, y un comentario dice por qué le importa a alguien:

```swift
@Test("Falls back when XDG_STATE_HOME is set but empty")
func fallsBackWhenEmpty() {
    // Python's os.environ.get returns "" here, which is falsy, so the CLI falls through to
    // ~/.local/state. An empty Swift String is truthy, so a literal translation resolves the
    // root to /rav -- and an app that quietly sees zero existing scans looks exactly like an
    // app whose user has never run a scan.
```

Cubrir los casos que no se producen a mano: placeholders sin sustituir, estado guardado corrupto,
rutas con Unicode compuesto y descompuesto, directorios sin permiso de lectura, archivos de longitud
cero, listas vacías.

## Selftest: volver verificable lo que parece no serlo

El catálogo de los 26 modos está en [`docs/SELFTEST.md`](docs/SELFTEST.md), con qué afirma cada uno,
el cambio exacto con el que se probó que falla, y qué toca en disco. **Ojo con lo último**: el
directorio de estado tiene 119 escaneos reales del usuario, y ningún modo escribe ahí. Los tres de
interoperabilidad lo leen y nada más.

`swift test` no tiene bundle. No puede ver si el Makefile sustituyó los placeholders, si los `.lproj`
aterrizaron donde `Bundle.main` los busca, ni si el menú tiene atajos colisionados.

```bash
make selftest MODE=bundle          # ningún __PLACEHOLDER__ sobrevivió
make selftest MODE=state-dir       # la resolución coincide con la del CLI
make selftest MODE=l10n            # las dos tablas cubren las mismas claves
make selftest MODE=menu            # ningún atajo duplicado
make selftest MODE=json-roundtrip  # cada JSON del CLI se re-codifica byte a byte
make selftest MODE=scans           # lo mismo, pasando por el modelo tipado
make selftest MODE=digest          # el hasher contra shasum -a 256, chunk de producción
make selftest MODE=digest ARGS="--file /ruta/archivo"
make selftest MODE=json-roundtrip ARGS="--dir /otra/ruta"
make selftest-all
```

`json-roundtrip` corre contra el corpus real en
`$XDG_STATE_HOME/rav/duplicate/`. Es de solo lectura: no escribe, no mueve, no borra. Si la máquina
nunca corrió el CLI, imprime `SKIPPED` con el conteo de directorios ausentes en vez de un OK
silencioso.

Dos reglas que lo hacen valer:

1. **Tiene que afirmar, no solo imprimir.**
2. **Tiene que reproducir el bug antes de confiar en él.** Un arnés que pasa contra la versión rota no
   vale nada. Se verifica revirtiendo el arreglo a mano y viendo que falla.

Ejemplo de lo segundo, hecho para este scaffolding:

```bash
# borrar una línea de es.lproj/Localizable.strings
make selftest MODE=l10n
# FAILED: l10n: Localizable: missing from es.lproj: menu.app.quit
```

## Git

Todo pasa por PR; `main` está protegido del lado del servidor y no hay bypass. Se exige PR, CI verde
y rama al día con `main`. Actualizar con **merge**, nunca rebase.

Conventional Commits en inglés, subject de 50 caracteres o menos. Sin firma GPG, sin
`Co-Authored-By`, sin ningún trailer de atribución.

Los PR llenan las cinco secciones de la plantilla, y "Verificación hecha" con salida real de
comandos. Si algo no se probó, decirlo bajo "Lo que no se pudo verificar". Un PR que reclama más de lo
que se comprobó es peor que uno que admite el hueco: el hueco se envía en los dos casos, y solo una
versión avisa.

## Estilo de escritura

- **Los comentarios explican por qué, nunca qué.** El código dice qué.
- **Documentar la alternativa que se descartó**, en `docs/ARCHITECTURE.md` o en el sitio de la
  decisión. En seis meses la pregunta no es qué hace el código, sino por qué no hace lo obvio.
- **Nombrar el fallo que una regla previene.** "Rutas como String, porque URL(filePath:) resuelve las
  relativas contra el directorio de trabajo" sobrevive a un refactor; "rutas como String" se borra.
- **Decir qué no se verificó.** La confianza que le gana a la evidencia es la clase cara de estar
  equivocado.
- **Corregir el registro cuando una afirmación resulta falsa**, donde se hizo, no con una edición
  silenciosa.
