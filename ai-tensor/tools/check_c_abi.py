#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Lockstep: include/ai_tensor.h macros vs python/ai_tensor/c_abi.py constants."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HDR = ROOT / "include" / "ai_tensor.h"


def parse_header_defines(text: str) -> dict[str, int]:
    out: dict[str, int] = {}
    # Prefer shift forms: (1u << N) / 1u << N before bare digits.
    for m in re.finditer(
        r"#define\s+(AI_TENSOR_\w+)\s+(.+?)(?:\s*/\*|\s*$)",
        text,
        re.MULTILINE,
    ):
        name, raw = m.group(1), m.group(2).strip().rstrip("\\")
        raw = raw.strip()
        sh = re.search(r"1u?\s*<<\s*(\d+)", raw)
        if sh:
            out[name] = 1 << int(sh.group(1))
            continue
        hx = re.search(r"0x([0-9A-Fa-f]+)", raw)
        if hx:
            out[name] = int(hx.group(1), 16)
            continue
        dec = re.search(r"\b(\d+)u?\b", raw)
        if dec:
            out[name] = int(dec.group(1))
    return out


def main() -> int:
    if not HDR.is_file():
        print(f"FAIL: missing {HDR}")
        return 1
    text = HDR.read_text(encoding="utf-8", errors="replace")
    d = parse_header_defines(text)
    # Expected mapping (Python c_abi names)
    sys.path.insert(0, str(ROOT / "python"))
    from ai_tensor import c_abi as py  # noqa: E402

    checks = [
        ("AI_TENSOR_DESC_BYTES", py.DESC_BYTES),
        ("AI_TENSOR_CONTRACT_VERSION", py.CONTRACT_VERSION),
        ("AI_TENSOR_OP_GEMM", py.OP_GEMM),
        ("AI_TENSOR_ST_OK", py.ST_OK),
        ("AI_TENSOR_ST_BAD_PTR", py.ST_BAD_PTR),
        ("AI_TENSOR_ST_BAD_QID", py.ST_BAD_QID),
        ("AI_TENSOR_ST_DISABLED", py.ST_DISABLED),
        ("AI_TENSOR_FLAG_IRQ", py.FLAG_IRQ),
        ("AI_TENSOR_MMIO_CTL", py.MMIO_CTL),
        ("AI_TENSOR_MMIO_DOORBELL", py.MMIO_DOORBELL),
        ("AI_TENSOR_MMIO_DONE", py.MMIO_DONE),
        ("AI_TENSOR_MMIO_DESC", py.MMIO_DESC),
        ("AI_TENSOR_MMIO_PMU_R", py.MMIO_PMU_R),
        ("AI_TENSOR_CTL_ENABLE", py.CTL_ENABLE),
        ("AI_TENSOR_CTL_WR_CPL_EN", py.CTL_WR_CPL_EN),
    ]
    bad = []
    for hname, pval in checks:
        if hname not in d:
            bad.append(f"header missing {hname}")
            continue
        if d[hname] != pval:
            bad.append(f"{hname}: header={d[hname]} python={pval}")
    # Pack length
    if len(py.pack_desc64(8, 8, 8)) != 64:
        bad.append("pack_desc64 length != 64")
    if bad:
        print("C_ABI FAIL:")
        for b in bad:
            print(" ", b)
        return 1
    print(f"c_abi lockstep: ok ({len(checks)} macros, header={HDR.name})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
