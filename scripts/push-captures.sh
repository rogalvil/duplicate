#!/bin/bash
# Sube capturas de `make ui` a la rama `ui-captures` e imprime la URL base para citarlas en un PR o un issue.
#
# **Existe porque `gh` no sube imágenes**, y un antes/después dice en un vistazo lo que un párrafo no. Las
# capturas no van a `main`: serían PNG en el historial para siempre. Van a una rama aparte que nunca se mergea,
# y **que no se borra**, porque los PR y los issues las citan por URL.
#
# La URL usa el sha del commit, no el nombre de la rama: una captura citada no cambia aunque después se suba otra
# con el mismo nombre.
#
# Solo capturas de `make ui`. Muestran el árbol de prueba en `/tmp/duplicate-ui` y nada de la máquina; una
# captura de la pantalla del usuario no se sube nunca, porque el repo es público.
#
# No toca el árbol de trabajo ni el índice: arma el commit con un índice temporal.
#
# Uso:
#   scripts/push-captures.sh "docs: captures for #135" 135/antes.png=build/ui/es/folder-pair-min.png [...]
#   -> https://raw.githubusercontent.com/<owner>/<repo>/<sha>
#   y en el markdown: ![antes](<url>/135/antes.png)
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "uso: $0 \"mensaje\" destino.png=origen.png [...]" >&2
  exit 1
fi
cd "$(git rev-parse --show-toplevel)"
message=$1
shift

# Antes de apuntar al índice temporal: un archivo vacío no es un índice válido y git se niega a hacer fetch.
if git fetch -q origin ui-captures 2>/dev/null; then
  parent=$(git rev-parse FETCH_HEAD)
else
  parent=""
fi
GIT_INDEX_FILE=$(mktemp -u)
export GIT_INDEX_FILE
trap 'rm -f "$GIT_INDEX_FILE"' EXIT
if [ -n "$parent" ]; then git read-tree "$parent"; else git read-tree --empty; fi

for pair in "$@"; do
  destination=${pair%%=*}
  source=${pair#*=}
  [ -f "$source" ] || { echo "no existe: $source" >&2; exit 1; }
  blob=$(git hash-object -w "$source")
  git update-index --add --cacheinfo "100644,$blob,$destination"
done

tree=$(git write-tree)
if [ -n "$parent" ]; then
  commit=$(echo "$message" | git commit-tree --no-gpg-sign "$tree" -p "$parent")
else
  commit=$(echo "$message" | git commit-tree --no-gpg-sign "$tree")
fi
git push -q origin "${commit}:refs/heads/ui-captures"

repository=$(gh repo view --json nameWithOwner -q .nameWithOwner)
echo "https://raw.githubusercontent.com/${repository}/${commit}"
