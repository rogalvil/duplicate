#!/usr/bin/env python3
"""Construye los corpora sintéticos del plan, con semilla fija.

**El plan pedía tres y solo se había usado el real**, así que todo lo medido hasta ahora vale para *este*
usuario y no se puede reproducir en otra máquina. Estos dos cierran ese hueco.

**Y están escalados a propósito, con el número a la vista.** El plan pedía C1 con 200,000 archivos / 40 GB
más **500 pares de ≥1 GB** del mismo tamaño para ejercitar la etapa de prefijo. Eso último son ~1 TB, y el
volumen de arranque de esta máquina tiene 22 GB libres. Las dos mitades de C1 miden cosas distintas y se
separan:

  c1-scale   200,000 archivos, tamaños power-law, 12% duplicados. Mide conteo: archivos/s, RSS, grupos.
  c1-prefix  pares del mismo tamaño arriba del umbral de 8 MiB que difieren **solo en la cola**. Mide bytes.
  c3         profundidad 8, 5,000 directorios, 100,000 archivos, tres subárboles duplicados enteros.

Los bytes de c1-prefix son lineales en (pares x tamaño), así que 40 pares de 64 MiB prueban el mecanismo y
la extrapolación a 500 pares de 1 GB es aritmética, no otra medición.

Uso:
    python3 scripts/make-corpus.py c1-scale  <destino>
    python3 scripts/make-corpus.py c1-prefix <destino> [pares] [MiB por archivo]
    python3 scripts/make-corpus.py c3        <destino>
"""
import os
import random
import shutil
import sys
import time

SEED = 20260823


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024


def fresh(path):
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(path, exist_ok=True)


def c1_scale(root, count=200_000):
    """Power-law sizes, 12% duplicates, spread over a shallow-but-wide tree.

    Sizes are capped at 64 KiB: the point of this corpus is the *count* -- the memory claim and the bucketing
    -- and 40 GB of bytes would measure the disk instead. The bytes live in c1-prefix, where they are what is
    being measured.
    """
    rng = random.Random(SEED)
    fresh(root)
    dirs = [f"{root}/d{i:03d}" for i in range(200)]
    for d in dirs:
        os.makedirs(d, exist_ok=True)

    # 12% duplicates: a pool of contents that get written more than once.
    duplicate_pool = [bytes([rng.randrange(256)]) * rng.randrange(512, 4096) for _ in range(600)]
    started = time.monotonic()
    total = 0
    for index in range(count):
        # Power-law: most files tiny, a few much larger. Pareto, clamped to 64 KiB.
        size = min(int(64 * 1024), int(512 * (rng.paretovariate(1.4))))
        target = f"{dirs[index % len(dirs)]}/f{index:06d}.bin"
        if rng.random() < 0.12:
            payload = duplicate_pool[rng.randrange(len(duplicate_pool))]
        else:
            # **Unique per file, and the first version was not.** `bytes([index & 0xFF]) * size` repeats every
            # 256 files, so files that were meant to be distinct collided by content and the corpus came out
            # with 31,705 groups instead of the intended 12% -- which also inflated the memory measurement,
            # because groups are what hold paths.
            head = f"{index:08d}".encode()
            payload = head + bytes([index & 0xFF]) * max(0, size - len(head))
        with open(target, "wb") as handle:
            handle.write(payload)
        total += len(payload)
    elapsed = time.monotonic() - started
    print(f"c1-scale: {count} archivos, {human(total)}, en {elapsed:.1f}s")


def c1_prefix(root, pairs=40, mib=64):
    """Pairs of identical size whose contents differ only in the last 4 KiB.

    **The case the prefix stage exists for, and the one the real corpus does not contain.** Size bucketing
    puts both files of a pair in the same bucket; without a probe each pair costs 2 x size of reads, and with
    one it costs 16 KiB. Differing in the *tail* is what makes it the honest test: a head-only probe would
    read everything anyway, which is why the probe reads both ends.
    """
    fresh(root)
    chunk = b"a" * (1 << 20)
    started = time.monotonic()
    total = 0
    for index in range(pairs):
        for side in ("l", "r"):
            path = f"{root}/pair{index:03d}{side}.bin"
            with open(path, "wb") as handle:
                for _ in range(mib):
                    handle.write(chunk)
                # **A tail unique to this file, and that is the whole fixture.** The first version wrote the
                # same tail for every left file and the same for every right, which made 40 identical files
                # twice over: the probe split them into two classes and then every file still needed a full
                # hash because it had a partner with the same prefix. 5 GB read either way, and the corpus
                # proved nothing. With a unique tail each file is alone after the probe, so nothing needs a
                # full read at all.
                handle.seek(-4096, os.SEEK_END)
                handle.write(f"{side}{index:06d}".encode().ljust(4096, b"."))
            total += mib << 20
    elapsed = time.monotonic() - started
    print(f"c1-prefix: {pairs} pares de {mib} MiB, {human(total)}, en {elapsed:.1f}s")


def c3(root, depth=8, directories=5_000, files=100_000):
    """A deep tree with three whole subtrees duplicated.

    Measures the folder detector's worst case: the size of the largest `(digest, basename)` class, which is
    the one place the redesign is quadratic.
    """
    rng = random.Random(SEED + 1)
    fresh(root)
    made = [root]
    while len(made) < directories:
        parent = made[rng.randrange(len(made))]
        if parent.count("/") - root.count("/") >= depth - 1:
            continue
        child = f"{parent}/s{len(made):04d}"
        os.makedirs(child, exist_ok=True)
        made.append(child)

    started = time.monotonic()
    total = 0
    for index in range(files):
        target = f"{made[index % len(made)]}/f{index:06d}.txt"
        # Deliberately repetitive: many files share a name *and* content across subtrees, which is what
        # makes the `(digest, basename)` classes grow.
        payload = f"line {index % 500}\n".encode()
        with open(target, "wb") as handle:
            handle.write(payload)
        total += len(payload)

    # **The pathological class the redesign fears, which the first version of this corpus did not contain.**
    # Grouping candidate folder pairs by `(digest, basename)` is quadratic in the size of a class, and the plan's
    # example is 10,000 identical `__init__.py`. With unique file names the largest class here was *two* files,
    # so the corpus proved nothing about the one case the design has a bad bound for. One identical file per
    # directory makes the class as large as the tree is wide.
    # **Non-empty, not hidden, and not on the noise list, or the app's own defaults defuse the case.** A first
    # attempt used an empty `__init__.py` and a `.DS_Store`: the first fell under the 1-byte minimum and the
    # second is in `defaultNoiseFiles`, so the class the corpus existed to create never reached the detector at
    # all. That is a real property worth knowing -- the shipped filters remove exactly the file kinds that grow
    # these classes -- and it is not a reason to leave the quadratic path unmeasured.
    for directory in made:
        with open(f"{directory}/conftest.py", "wb") as handle:
            handle.write(b"import pytest\n")

    # Three whole subtrees duplicated, which is what the folder detector is supposed to find.
    sources = [d for d in made if d.count("/") - root.count("/") == 2][:3]
    copies = 0
    for number, source in enumerate(sources):
        destination = f"{root}/copy{number}"
        shutil.copytree(source, destination)
        copies += 1
    elapsed = time.monotonic() - started
    print(
        f"c3: {directories} directorios hasta profundidad {depth}, {files} archivos, "
        f"{copies} subárboles duplicados, {human(total)}, en {elapsed:.1f}s"
    )


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    kind, root = sys.argv[1], os.path.expanduser(sys.argv[2])
    if kind == "c1-scale":
        c1_scale(root)
    elif kind == "c1-prefix":
        pairs = int(sys.argv[3]) if len(sys.argv) > 3 else 40
        mib = int(sys.argv[4]) if len(sys.argv) > 4 else 64
        c1_prefix(root, pairs, mib)
    elif kind == "c3":
        c3(root)
    else:
        print(f"corpus desconocido: {kind}")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
