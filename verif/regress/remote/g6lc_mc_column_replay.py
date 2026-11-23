#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Replay a hot-TU manifest against the already-packed two-lane Hyp8 model."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from functools import partial
import json
from pathlib import Path
import shlex
import shutil
import subprocess

from g6lc_mc_pack_replay import digest, rebuild
from g6lc_pack_columns import lower_columns


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("original", "packed", "build_log", "tu_list", "output"):
        parser.add_argument(name, type=Path)
    parser.add_argument("-j", type=int, default=2)
    args = parser.parse_args()
    original, packed, out = (p.resolve() for p in (args.original, args.packed, args.output))
    binary = "Variane_testharness"
    expected = "72ae9370aedb8c08f5fb1cdad6220f8435baaa1c067f153144410a7f82dc44f6"
    if digest(original / binary) != "5eaf04f7a70e4fe9e1dd51912112386835bf51858cc0aab0261f003e84718c0b":
        parser.error("expected the original devthr2-ab model")
    if digest(packed / binary) != expected:
        parser.error("expected the measured packed control")
    names = sorted(set(args.tu_list.read_text().splitlines()))
    if not names or any(Path(n).name != n or not n.startswith("Vg6lc_testharness_g6lc_core__pi37__")
                        or not n.endswith(".cpp") for n in names):
        parser.error("expected one generated core TU basename per line")
    lines = args.build_log.read_text().splitlines()
    argv = {s.split()[-1]: s for s in lines if s.startswith("ccache g++") and " -c -o " in s}
    link, = [shlex.split(s) for s in lines if s.startswith("g++ ") and s.endswith(" -o " + binary)]
    archive, = [s for s in link if s.endswith("__ALL.a")]
    out.mkdir()
    compiler = link[0] = "/usr/bin/g++-13"
    link[link.index(archive)] = str(packed / archive)
    link[-1] = str(out / "control")
    subprocess.run(link, cwd=original, check=True)
    if digest(out / "control") != expected:
        raise RuntimeError("archive/companion objects do not reproduce the control")
    shutil.copyfile(Path(__file__).with_name("g6lc_column_tile.h"), out / "g6lc_column_tile.h")
    header = (original / "Vg6lc_testharness_g6lc_core__pi37.h").read_text()
    build = partial(rebuild, header=header, argv={n: argv[n] for n in names}, output=out,
                    compiler=compiler, transform=lower_columns, frozen=packed)
    with ProcessPoolExecutor(max_workers=args.j) as pool:
        changed = dict(hit for hit in pool.map(build, (original / n for n in names)) if hit)
    if not changed:
        raise RuntimeError("no column tiles found")
    shutil.copyfile(packed / archive, out / archive)
    subprocess.run(["ar", "rs", str(out / archive), *(str(out / f) for f in changed)], check=True)
    link[link.index(str(packed / archive))] = str(out / archive)
    link[-1] = str(out / binary)
    subprocess.run(link, cwd=original, check=True)
    (out / "manifest.json").write_text(json.dumps(
        {"control": expected, "candidate": digest(out / binary), "words_by_object": changed},
        indent=2) + "\n")


if __name__ == "__main__":
    main()
