#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Rebuild the profiled MC leaf TUs into a private copy of the devthr2-ab archive."""
import argparse
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor
from functools import partial
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess

from g6lc_pack_generated_rows import lower


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def rebuild(src, *, header, argv, output, compiler, transform=lower, frozen=None):
    before = frozen / src.name if frozen and (frozen / src.name).exists() else src
    text, changes = transform(before.read_text(), header)
    if not changes:
        return None
    cpp = output / src.name
    cpp.write_text(text)
    obj = cpp.with_suffix(".o")
    args = shlex.split(argv[src.name])
    if args[:2] != ["ccache", "g++"] or args[-1] != src.name:
        raise ValueError(f"unrecognized compile command for {src}")
    args = [compiler, f"-fmacro-prefix-map={output}/=", *args[2:]]
    args[args.index("-o") + 1] = str(obj)
    args[-1] = str(cpp)
    subprocess.run(args, cwd=src.parent, check=True)
    return obj.name, changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", type=Path)
    parser.add_argument("build_log", type=Path)
    parser.add_argument("output", type=Path, help="new, non-existing scratch directory")
    parser.add_argument("--compiler", default="/usr/bin/g++-13")
    parser.add_argument("-j", type=int, default=2)
    args = parser.parse_args()
    model, out = args.model.resolve(), args.output.resolve()
    binary = "Variane_testharness"
    original = digest(model / binary)
    if original != "5eaf04f7a70e4fe9e1dd51912112386835bf51858cc0aab0261f003e84718c0b":
        parser.error("this task ID and source selection apply only to the profiled devthr2-ab ELF")
    lines = args.build_log.read_text().splitlines()
    argv = {s.split()[-1]: s for s in lines if s.startswith("ccache g++") and " -c -o " in s}
    link, = [shlex.split(s) for s in lines if s.startswith("g++ ") and s.endswith(" -o " + binary)]
    archive, = [s for s in link if s.endswith("__ALL.a")]
    with (model / archive).open("rb") as stream:
        if stream.read(8) != b"!<arch>\n":
            parser.error("expected an ordinary archive, not a thin archive")

    # This selection is profile-specific; the expression transformer is not.
    by_symbol = defaultdict(set)
    for f in model.glob("*024root*.cpp"):
        text = f.read_text()
        if "Verilated::mtaskId(19);" not in text:
            continue
        body = text.split("Verilated::mtaskId(19);", 1)[1].split("Verilated::endOfThreadMTask", 1)[0]
        for name, core in re.findall(r"(Vg6lc_testharness\w+)\(\(&vlSymsp->TOP\w*?"
                                     r"__gen_core__BRA__(\d+)__KET__", body):
            by_symbol[name].add(core)
    selected = {name for name, cores in by_symbol.items() if len(cores) == 4}
    sources = []
    for f in sorted(model.glob("*pi37__DepSet*.cpp")):
        with f.open() as stream:
            m = re.search(r"^VL_INLINE_OPT void (\w+)\(", stream.read(4000), re.M)
        if m and m[1] in selected:
            sources.append(f)
    if len(sources) != 267:
        parser.error(f"found {len(sources)} profiled TUs, expected 267")

    out.mkdir()
    header = (model / "Vg6lc_testharness_g6lc_core__pi37.h").read_text()
    # Pass only the command for each selected TU, not the entire build log.
    build = partial(rebuild, header=header, argv={f.name: argv[f.name] for f in sources},
                    output=out, compiler=args.compiler)
    with ProcessPoolExecutor(max_workers=args.j) as pool:
        changed = dict(hit for hit in pool.map(build, sources, chunksize=8) if hit)
    if not changed:
        raise RuntimeError("no assignments matched")
    shutil.copyfile(model / archive, out / archive)
    subprocess.run(["ar", "rs", str(out / archive), *(str(out / f) for f in changed)], check=True)
    link[0] = args.compiler
    link[link.index(archive)] = str(out / archive)
    link[-1] = str(out / binary)
    subprocess.run(link, cwd=model, check=True)
    (out / "manifest.json").write_text(json.dumps(
        {"control": original, "candidate": digest(out / binary), "words_by_object": changed},
        indent=2) + "\n")


if __name__ == "__main__":
    main()
