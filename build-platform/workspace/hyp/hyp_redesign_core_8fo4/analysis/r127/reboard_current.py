# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Replay the r115 whole-core board argv against the current tree.

The argv of record is the first line of analysis/r115/boards/core-all-r115.log
(module list, r95 param map, --assume-xlen 64, --package-mode packages,
--stages, 5000 MHz / 20 ps / margin 0.2). Only the output paths, an optional
analyzer binary and an optional --modules subset are substituted, so a board
made here is same-argv with core-all-r115.

  python reboard_current.py <tag> [--exe PATH] [--modules a,b,c] [--param-map FILE] [--files-from FLIST] [--width-map FILE]

Writes boards/<tag>.{json,ir.json,log,manifest.json}; refuses to overwrite.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ANALYSIS = HERE.parent
ROOT = HERE.parents[5]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tag")
    ap.add_argument("--exe", default=None)
    ap.add_argument("--modules", default=None)
    ap.add_argument("--param-map", default=None)
    ap.add_argument("--files-from", default=None)
    ap.add_argument("--width-map", default=None)
    ap.add_argument("--add-modules", default="g6lc_fe_frontier",
                    help="live modules absent from the r115 argv (appended to the full list only)")
    ap.add_argument("--argv-from", default=None,
                    help="replay the argv recorded on the first line of another board log")
    a = ap.parse_args()
    src = Path(a.argv_from) if a.argv_from else ANALYSIS / "r115/boards/core-all-r115.log"
    record = src.read_text(encoding="utf-8")
    argv = json.loads(record.splitlines()[0])
    out = HERE / "boards"
    out.mkdir(exist_ok=True)
    stem = out / a.tag
    if stem.with_suffix(".json").exists():
        raise SystemExit("refusing to overwrite evidence: " + str(stem))
    if a.exe:
        argv[0] = a.exe
    if a.modules:
        argv[argv.index("--modules") + 1] = a.modules
    elif a.add_modules and not a.argv_from and "--modules" in argv:
        i = argv.index("--modules") + 1
        have = argv[i].split(",")
        argv[i] = ",".join(have + [m for m in a.add_modules.split(",") if m and m not in have])
    if a.param_map:
        argv[argv.index("--param-map") + 1] = str(Path(a.param_map).resolve())
    if a.files_from:
        argv[argv.index("--files-from") + 1] = str(Path(a.files_from).resolve())
    for flag, suffix in (("--json-out", ".json"), ("--ir-out", ".ir.json")):
        argv[argv.index(flag) + 1] = str(stem.with_suffix(suffix))
    inputs = [argv[0], argv[argv.index("--files-from") + 1],
              argv[argv.index("--param-map") + 1]]
    if a.width_map:
        wm = str(Path(a.width_map).resolve())
        argv += ["--width-map", wm]
        inputs.append(wm)
    with stem.with_suffix(".log").open("x", encoding="utf-8") as log:
        log.write(json.dumps(argv) + "\n")
        log.flush()
        rc = subprocess.run(argv, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                            env=dict(os.environ, RUST_MIN_STACK="16777216")).returncode
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True,
                          text=True).stdout.strip()
    stem.with_suffix(".manifest.json").write_text(json.dumps(dict(
        tag=a.tag, argv=argv, returncode=rc, gitHead=head,
        sha256={p: sha(p) for p in inputs}), indent=2), encoding="utf-8")
    print(a.tag, "rc", rc)
    raise SystemExit(rc)


if __name__ == "__main__":
    main()
