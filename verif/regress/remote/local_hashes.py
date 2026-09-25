#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Print the local-tree sha256 sidecar for the build-only review.

run_mc_int2_review.py's REVIEW_MC_BUILD_ONLY mode reads this JSON (pushed as
data/local-hashes.json) and compares each entry against the effective build
inputs in the remote seed copy, so the C++/bootrom side of the tree -- not
just the SV set -- is proven identical to what was built. Keys are repo-root
relative paths. Usage: python3 local_hashes.py > local-hashes.json
"""
import hashlib
import json
import sys
from pathlib import Path


def main():
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[3]
    files = [root / 'corev_apu/tb/g6lc_tb.cpp']
    files += sorted((root / 'corev_apu/tb').glob('*.h'))
    files += sorted(p for p in (root / 'corev_apu/bootrom').glob('*') if p.is_file())
    hashes = {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in files if p.is_file()}
    print(json.dumps(hashes, indent=2))


if __name__ == '__main__':
    raise SystemExit(main())
