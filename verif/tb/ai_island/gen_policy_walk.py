#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Generate a synthetic framework-operator shape walk for the island DMA policy replay.

Emits a Verilator $readmemh()-compatible AXI memory image plus a JSON sidecar
with per-job metadata. The image is self-contained: descriptor i lives at
MEM_BASE + i*JOB_STRIDE, and the A/B/C operand buffers live immediately after.
All data is zeroed so the GEMM is fast and deterministic. Only INT8/INT4 are
submitted as live jobs; other formats are intentionally absent because the live
island advertises mask 3 and must fail closed on an ungranted format.

The walk is a compressed policy calibration, not a measured speedup.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
from pathlib import Path
from typing import List, Tuple

MEM_BASE = 0x8001_0000
REGION_LIMIT = 0x8002_0000
JOB_STRIDE = 0x800  # 2 KiB per job, keeps m/n/k <= 16 with k up to 128
MEM_SIZE = REGION_LIMIT - MEM_BASE  # 64 KiB
MEM_WORDS = MEM_SIZE // 8

# Shape buckets mirror g6lc_ai_policy_pkg::policy_shape_bucket.
BUCKET_EDGES = [2, 9, 65]


def shape_bucket(x: int) -> int:
    if x <= 1:
        return 0
    if x <= 8:
        return 1
    if x <= 64:
        return 2
    return 3


def element_bytes(m: int, n: int, k: int, numfmt: int) -> Tuple[int, int, int]:
    bits = {0: 8, 1: 4}.get(numfmt, 8)
    a_bits = m * k * bits
    b_bits = n * k * bits
    a_bytes = (a_bits + 7) // 8
    b_bytes = (b_bits + 7) // 8
    c_bytes = m * n * 4  # i32 output
    return a_bytes, b_bytes, c_bytes


def pack_desc(
    m: int,
    n: int,
    k: int,
    ld_ab: int,
    ptr_a: int,
    ptr_b: int,
    ptr_c: int,
    ptr_done: int,
    numfmt: int,
    op: int = 1,
    version: int = 2,
) -> List[int]:
    # Descriptor flags layout from g6lc_ai_desc_pkg (v2, B k-major).
    # bits [22:20] = numfmt; dtype/accmode/ew/sp24 default to 0/0/0/0.
    flags = (numfmt & 0x7) << 20
    # Split 64-bit pointers into 32-bit little-endian words.
    def split64(x: int) -> Tuple[int, int]:
        return (x & 0xFFFFFFFF, (x >> 32) & 0xFFFFFFFF)

    a_lo, a_hi = split64(ptr_a)
    b_lo, b_hi = split64(ptr_b)
    c_lo, c_hi = split64(ptr_c)
    d_lo, d_hi = split64(ptr_done)
    s_lo, s_hi = split64(0)  # ptr_scale = 0

    words = [
        version | (op << 16),
        flags,
        m,
        n,
        k,
        ld_ab,
        a_lo,
        a_hi,
        b_lo,
        b_hi,
        c_lo,
        c_hi,
        s_lo,
        s_hi,
        d_lo,
        d_hi,
    ]
    # 16 32-bit words (64 bytes), packed as 8 little-endian 64-bit words.
    mem_words: List[int] = []
    for i in range(0, 16, 2):
        lo = words[i] & 0xFFFFFFFF
        hi = words[i + 1] & 0xFFFFFFFF
        mem_words.append(lo | (hi << 32))
    return mem_words


def fits_in_stride(m: int, n: int, k: int, numfmt: int) -> bool:
    a_bytes, b_bytes, c_bytes = element_bytes(m, n, k, numfmt)
    base = 0x80  # descriptor size
    end = base + a_bytes + b_bytes + c_bytes + 8
    return end <= JOB_STRIDE and a_bytes + b_bytes + c_bytes <= JOB_STRIDE - 0x80


def make_jobs() -> List[Tuple[int, int, int, int, str]]:
    """Return list of (m, n, k, numfmt, tag)."""
    jobs: List[Tuple[int, int, int, int, str]] = []
    # Phase-like walks. Keep dimensions <= 16 except for one ragged large-k decode.
    shapes = [
        # (m, n, k, numfmt, tag)
        # Rules of thumb for a 2 KiB stride:
        #   A = m*k  (INT8)
        #   B = n*k
        #   C = m*n*4
        #   descriptor+padding+operands <= 0x800
        (8, 8, 8, 0, "bulk"),
        (16, 16, 16, 0, "bulk"),
        (1, 128, 8, 0, "decode"),
        (1, 64, 16, 0, "decode"),
        (128, 1, 8, 0, "tall"),
        (64, 1, 16, 0, "tall"),
        (1, 128, 16, 0, "wide"),
        (8, 32, 16, 0, "routed"),
        (32, 8, 16, 0, "attention"),
        (8, 64, 4, 0, "wide"),
        (64, 8, 4, 0, "tall"),
        (8, 8, 4, 0, "bulk"),
        (1, 1, 128, 0, "movement"),
        (1, 16, 128, 0, "movement"),
        (4, 32, 8, 0, "routed"),
        (16, 4, 32, 0, "attention"),
        (8, 8, 8, 1, "bulk-int4"),
        (16, 16, 16, 1, "bulk-int4"),
        (1, 64, 16, 1, "decode-int4"),
        (64, 1, 16, 1, "tall-int4"),
    ]
    for m, n, k, numfmt, tag in shapes:
        if fits_in_stride(m, n, k, numfmt):
            jobs.append((m, n, k, numfmt, tag))
    return jobs


def generate(out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    mem = [0] * MEM_WORDS
    jobs = make_jobs()
    meta = []
    for i, (m, n, k, numfmt, tag) in enumerate(jobs):
        desc_addr = MEM_BASE + i * JOB_STRIDE
        a_bytes, b_bytes, c_bytes = element_bytes(m, n, k, numfmt)
        ptr_a = desc_addr + 0x80
        ptr_b = ptr_a + a_bytes
        ptr_c = ptr_b + b_bytes
        ptr_done = 0  # no completion write
        ld_ab = k | (k << 16)  # v2 k-major: both lda and ldb are k
        desc_words = pack_desc(m, n, k, ld_ab, ptr_a, ptr_b, ptr_c, ptr_done, numfmt)
        desc_off = (desc_addr - MEM_BASE) // 8
        for j, w in enumerate(desc_words):
            mem[desc_off + j] = w & ((1 << 64) - 1)
        meta.append(
            {
                "index": i,
                "m": m,
                "n": n,
                "k": k,
                "numfmt": numfmt,
                "tag": tag,
                "desc_addr": f"0x{desc_addr:08x}",
                "ptr_a": f"0x{ptr_a:08x}",
                "ptr_b": f"0x{ptr_b:08x}",
                "ptr_c": f"0x{ptr_c:08x}",
            }
        )
    hex_path = out_dir / "walk.hex"
    with hex_path.open("w") as f:
        for w in mem:
            f.write(f"{w:016x}\n")
    json_path = out_dir / "walk.json"
    with json_path.open("w") as f:
        json.dump(
            {
                "mem_base": f"0x{MEM_BASE:08x}",
                "region_limit": f"0x{REGION_LIMIT:08x}",
                "mem_words": MEM_WORDS,
                "job_stride": f"0x{JOB_STRIDE:x}",
                "num_jobs": len(jobs),
                "jobs": meta,
            },
            f,
            indent=2,
        )
    print(f"[gen_policy_walk] wrote {hex_path} ({len(mem)} words) and {json_path}")
    print(f"[gen_policy_walk] num_jobs={len(jobs)} job_stride=0x{JOB_STRIDE:x}")
    return hex_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("."), help="output directory")
    args = parser.parse_args()
    generate(args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
