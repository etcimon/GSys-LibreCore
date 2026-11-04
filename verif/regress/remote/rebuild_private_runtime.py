#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Recreate the patched Verilator 5.008 runtime at its pinned path.

Same recipe as run_runtime_repair.py (CONSTHI zero-fill fix in
verilated_funcs.h), standalone: copies the stock runtime, applies the fix,
requires the fixed header to hash to the pinned value, and requires the
wide-constant canary to fail on the original runtime and pass on the fixed
one. Refuses to overwrite an existing runtime directory.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

# Next to this script in the repo; in data/ when pushed by the remote py runner.
sys.path[:0] = [str(Path(__file__).resolve().parent), str(Path("data").resolve())]
from run_runtime_repair import CANARY  # noqa: E402

ORIGINAL = Path("/opt/testharness/toolchains/verilator-v5.008/share/verilator")
TARGET = Path("/opt/testharness/runs/review-private-runtime-20260915/runtime")
ORIGINAL_SHA = "8c408609b477f5d29c0897bf5412c8417676f9ea66c6622809c1796b4ac3099e"
FIXED_SHA = "dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    out = Path("output").resolve()
    out.mkdir(exist_ok=True)
    if TARGET.exists():
        raise SystemExit(f"refusing to overwrite {TARGET}")
    if sha(ORIGINAL / "include/verilated_funcs.h") != ORIGINAL_SHA:
        raise SystemExit("stock runtime header does not match the pinned original")
    TARGET.parent.mkdir(parents=True)
    shutil.copytree(ORIGINAL, TARGET)
    header = TARGET / "include/verilated_funcs.h"
    text = header.read_text()
    for n in range(1, 9):
        old = f"    VL_C_END_(obits, VL_WORDS_I(lsb) + {n});"
        new = (f"    for (int i = VL_WORDS_I(lsb) + {n}; i < VL_WORDS_I(obits); ++i) "
               f"obase[i] = 0;\n    return o;")
        assert text.count(old) == 1, n
        text = text.replace(old, new)
    header.write_text(text)
    if sha(header) != FIXED_SHA:
        raise SystemExit("fixed header hash differs from the pinned value")
    canary = out / "constant_canary.cpp"
    canary.write_text(CANARY)
    canaries = []
    for tag, prefix, expected in (("original", ORIGINAL, 1), ("fixed", TARGET, 0)):
        exe = out / f"canary-{tag}"
        cmd = ["g++", "-std=c++17", "-O2", f"-I{prefix / 'include'}", str(canary), "-o", str(exe)]
        subprocess.run(cmd, check=True, capture_output=True)
        run = subprocess.run([str(exe)], capture_output=True, text=True)
        canaries.append({"tag": tag, "rc": run.returncode, "output": run.stdout, "command": cmd})
        if run.returncode != expected:
            raise SystemExit(f"canary {tag} rc={run.returncode}, expected {expected}")
    record = {"originalRoot": str(ORIGINAL), "privateRoot": str(TARGET),
              "originalHeaderSha256": ORIGINAL_SHA, "fixedHeaderSha256": FIXED_SHA,
              "change": "CONSTHI zero-fill uses unshifted obase with absolute word "
                        "indices; return pointer unchanged"}
    (out / "runtime.json").write_text(json.dumps(record, indent=2))
    (out / "canaries.json").write_text(json.dumps(canaries, indent=2))
    print(json.dumps(canaries, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
