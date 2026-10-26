#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Build the hyp8 isolated source closure consumed by the remote runners
(run_hyp8_integration.py / run_hyp8_memory.py via `testharness_proxy.py py
--data <closure>`).

The closure is a repo-relative copy of every file the hyp8 simulation flist
names (sources, every file under each +incdir, the flist itself), the
harness/tb/firmware inputs the build harness and the integration script
read, the directed tests and the leaf benches, pinned by manifest.json
{"files": {rel: sha256}}. Paths are resolved against the repository root,
never the current directory (the r20b fixpoint defect).

  python3 verif/regress/remote/hyp8/build_closure.py <out-dir> [--mc]
"""
import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
FLISTS = ['verif/regress/remote/hyp8/Flist.hyp8_sim',
          'build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/Flist.g6lc_hyp8']
FLIST_MC = 'verif/regress/remote/hyp8/Flist.hyp8_mc_sim'
# files the harness / integration / leaf scripts read by name
EXTRA_FILES = [
    'verilator_config.vlt',
    'verif/regress/remote/hyp8/hyp8-build-harness.sh',
    'verif/regress/remote/hyp8/hyp8_tb.cpp',
    'verif/regress/remote/hyp8/build_boot_firmware.py',
    'verif/regress/remote/hyp8/capture_cfg.py',
    'verif/regress/remote/hyp8/check_boot_dts.py',
    'verif/tests/custom/common/link_verilator.ld',
    'verif/tb/apu/g6lc_dram_peek64_stub.cpp',
    'corev_apu/tb/g6lc_tb_trace.h',
    'corev_apu/tb/g6lc_tb_dram_latency.sv',
    # `include "../apu/g6lc_apu_fault_sup.sv" from g6lc_testharness.sv: a
    # relative include, not an incdir file (the r20b 766-file closure lint
    # failure)
    'build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/apu/g6lc_apu_fault_sup.sv',
]
EXTRA_GLOBS = [
    'verif/regress/remote/hyp8/*.dts', 'verif/regress/remote/hyp8/*.dtsi',
    'verif/tests/custom/hyp8_*.S',
    'verif/tb/core/tb_g6lc_hyp8_*.sv',
    'corev_apu/tb/dpi/*',
    'build-platform/workspace/build/sv-timing/hyp8-src/tb/tests/*.S',
    'build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/neg/*.sv',
]
VARS = {
    '${CVA6_REPO_DIR}': '',
    '${HYP_CORE_DIR}': 'build-platform/workspace/hyp/hyp_redesign_core_8fo4',
}


def expand(line: str) -> str:
    for k, v in VARS.items():
        line = line.replace(k, v)
    return line.lstrip('/')


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--mc', action='store_true', help='also close over the mc flist')
    args = ap.parse_args()
    out = Path(args.out).resolve()
    flists = list(FLISTS) + ([FLIST_MC] if args.mc else [])
    rels: set[str] = set(flists)
    for fl in flists:
        for raw in (ROOT / fl).read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('+incdir+'):
                d = ROOT / expand(line[len('+incdir+'):])
                if not d.is_dir():
                    sys.exit(f'incdir missing: {d}')
                for f in d.rglob('*'):
                    if f.is_file():
                        rels.add(f.relative_to(ROOT).as_posix())
            elif line.startswith('+'):
                continue
            else:
                rel = expand(line)
                if not (ROOT / rel).is_file():
                    sys.exit(f'flist source missing: {rel}')
                rels.add(rel)
    for rel in EXTRA_FILES:
        if (ROOT / rel).is_file():
            rels.add(rel)
        else:
            print(f'warning: extra file missing: {rel}', file=sys.stderr)
    for pat in EXTRA_GLOBS:
        for f in ROOT.glob(pat):
            if f.is_file():
                rels.add(f.relative_to(ROOT).as_posix())
    if out.exists():
        shutil.rmtree(out)
    files = {}
    for rel in sorted(rels):
        src = ROOT / rel
        dst = out / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        files[rel] = digest(dst)
    (out / 'manifest.json').write_text(json.dumps(
        {'root': str(ROOT), 'flists': flists, 'files': files}, indent=2))
    print(f'closure: {len(files)} files -> {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
