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
        ("AI_TENSOR_MMIO_QUEUE0", py.MMIO_QUEUE0),
        ("AI_TENSOR_MMIO_QUEUE_TAIL", py.MMIO_QUEUE_TAIL),
        ("AI_TENSOR_DOORBELL_TICKET_MAX", py.DOORBELL_TICKET_MAX),
        ("AI_TENSOR_CTL_ENABLE", py.CTL_ENABLE),
        ("AI_TENSOR_CTL_WR_CPL_EN", py.CTL_WR_CPL_EN),
    ]
    for name in ('ST_BAD_FMT', 'FLAG_NUMFMT_SHIFT', 'FLAG_NUMFMT_WIDTH', 'FLAG_NUMFMT_MASK'):
        checks.append(('AI_TENSOR_' + name, getattr(py, name)))
    variants = {
        'Int': 'INT', 'Int4': 'INT4', 'Sp24': 'SP24', 'Fp8E4m3': 'FP8_E4M3',
        'Fp8E5m2': 'FP8_E5M2', 'Fp16': 'FP16', 'Bf16': 'BF16', 'Fp32': 'FP32',
    }
    for name in variants.values():
        checks.append(('AI_TENSOR_FMT_' + name, getattr(py, 'AI_FMT_' + name)))
    command_names = ("CAP_COMMAND_QUEUE", "COMMAND_QUEUE_VERSION", "COMMAND_QUEUE_FLAGS",
                     "CMD_MODE", "CMD_PTR_LO", "CMD_PTR_HI", "CMD_TICKET", "CMD_QID",
                     "CMD_SUBMIT", "CMD_CREDITS", "CMD_RECEIPT_TICKET", "CMD_RECEIPT_CODE",
                     "CMD_ACCEPTED_COUNT", "CMD_REJECTED_COUNT", "CMD_ACCEPTED", "CMD_FULL", "CMD_DISABLED",
                     "CAP_ACCMODE", "CAP_ACCMODE_ACCUMULATE", "FLAG_ACCMODE_SHIFT", "ACCMODE_ACCUMULATE",
                     "CAP_BANK_A_BYTES", "CAP_BANK_B_BYTES")
    checks.extend(("AI_TENSOR_" + name, getattr(py, name)) for name in command_names)
    bad = []
    rust = (ROOT / 'crates/ai-tensor-abi/src/lib.rs').read_text(encoding='utf-8')
    for name in command_names:
        match = re.search(r'pub const ' + name + r': \w+ = (0x[0-9a-fA-F_]+|[0-9]+);', rust)
        if not match or int(match[1].replace('_', ''), 0) != getattr(py, name):
            bad.append(f'Rust/Python {name} mismatch')
    for name in ('CONTRACT_VERSION', 'FLAG_NUMFMT_SHIFT', 'FLAG_NUMFMT_WIDTH', 'ST_BAD_FMT'):
        match = re.search(r'pub const ' + name + r': \w+ = (\d+);', rust)
        if not match or int(match[1]) != getattr(py, name):
            bad.append(f'Rust/Python {name} mismatch')
    for rust_name, py_name in (
        ('REG0', 'MMIO_QUEUE0'), ('REG_QUEUE_TAIL', 'MMIO_QUEUE_TAIL'),
        ('DOORBELL_TICKET_MAX', 'DOORBELL_TICKET_MAX'),
    ):
        match = re.search(r'pub const ' + rust_name + r': \w+ = (0x[0-9a-fA-F_]+);', rust)
        if not match or int(match[1].replace('_', ''), 16) != getattr(py, py_name):
            bad.append(f'Rust/Python {rust_name} mismatch')
    for variant, name in variants.items():
        match = re.search(r'^\s*' + variant + r' = (\d+),', rust, re.MULTILINE)
        if not match or int(match[1]) != getattr(py, 'AI_FMT_' + name):
            bad.append(f'Rust/Python NumFmt::{variant} mismatch')
    from ai_tensor.device import CONTRACT_VERSION as device_version, pack_gemm_desc
    if device_version != py.CONTRACT_VERSION:
        bad.append('Device/C ABI descriptor version mismatch')
    import struct
    for pack in (py.pack_desc64, pack_gemm_desc):
        blob = pack(2, 3, 5)
        if struct.unpack_from('<H', blob)[0] != 2 or struct.unpack_from('<I', blob, 20)[0] != 5 | (5 << 16):
            bad.append('Desc64 v2 default element strides must both be K')
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
