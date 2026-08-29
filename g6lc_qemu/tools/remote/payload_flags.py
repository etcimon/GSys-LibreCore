#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# payload_flags.py — model-driven preprocessor flags for ai_island_smoke.S.
#
# The smoke payload is intentionally model-driven: it reads descriptor geometry,
# op/status tables, and the island MMIO placement from the ingested TargetModel
# so that the same source can be compiled against any design package without
# hard-coding offsets, op values, or window bases.

from __future__ import annotations


def _peripheral_base(model: dict, ids: list) -> int | None:
    """Return the first peripheral base whose id is in `ids`."""
    for p in (model.get("soc") or {}).get("peripherals") or []:
        if p.get("id") in ids:
            return int(p.get("base"), 0) if p.get("base") else None
    return None


def _field_offset(fields: dict, name: str) -> int:
    field = fields.get(name) or {}
    return int(field.get("offset")) if field.get("offset") is not None else None


def compile_flags(
    model: dict,
    ai_m: int = 1,
    ai_n: int = 1,
    ai_k: int = 1,
    done_ptr: int | None = None,
) -> list[str]:
    """Return a list of `-DNAME=VALUE` flags derived from the model.

    Raises `ValueError` when the model does not publish enough of the descriptor
    contract to make the smoke payload meaningful -- the caller must then decide
    whether to supply explicit overrides or to stop.
    """
    soc = model.get("soc") or {}
    ai = soc.get("ai_island")
    if not ai:
        raise ValueError("the model has no soc.ai_island")
    cfg = ai.get("config") or {}
    layout = ai.get("desc_layout") or {}
    fields = layout.get("fields") or {}

    ai_base = _peripheral_base(model, ["ai-island"])
    if ai_base is None:
        raise ValueError("the model has no ai-island peripheral base")
    desc_base = cfg.get("desc_base")
    if desc_base is None:
        raise ValueError(
            "the model does not resolve ai_island.config.desc_base; "
            "the smoke payload cannot address the descriptor window"
        )
    ai_desc_base = ai_base + int(desc_base)

    uart_base = _peripheral_base(model, ["uart", "serial"])
    if uart_base is None:
        raise ValueError("the model has no uart/serial peripheral base")

    dram = soc.get("dram") or {}
    dram_base = int(dram.get("base"), 0) if dram.get("base") else 0x8000_0000
    ptr_done = done_ptr if done_ptr is not None else dram_base + 0x10000

    op_gemm = (layout.get("ops") or {}).get("OP_GEMM")
    if op_gemm is None:
        raise ValueError("the model does not publish OP_GEMM")

    version = layout.get("version")
    if version is None:
        version = 1  # deliberate fallback; see g6q-vm/src/device.rs

    # Queue-instruction encodings from the design's own instruction package, when it is present.
    instr = ai.get("instr_set") or {}
    for k in ("match_enq", "match_poll", "match_qfence"):
        if instr.get(k) is None:
            instr = None
            break

    # The smoke payload uses the four scalar shape fields and the done pointer.
    needed = {
        "m": "AI_OFF_M",
        "n": "AI_OFF_N",
        "k": "AI_OFF_K",
        "ptr_done": "AI_OFF_PTR_DONE",
    }
    flags = {
        "AI_DESC_BASE": f"0x{ai_desc_base:x}",
        "AI_DONE_PTR": f"0x{ptr_done:x}",
        "AI_OP_GEMM": str(int(op_gemm)),
        "AI_VERSION": str(int(version)),
        "AI_M": str(int(ai_m)),
        "AI_N": str(int(ai_n)),
        "AI_K": str(int(ai_k)),
        "UART_BASE": f"0x{uart_base:x}",
    }
    if instr:
        flags["AI_ENQ_MATCH"] = f"0x{int(instr['match_enq']):x}"
        flags["AI_POLL_MATCH"] = f"0x{int(instr['match_poll']):x}"
        flags["AI_QFENCE_MATCH"] = f"0x{int(instr['match_qfence']):x}"

    desc_bytes = int(layout.get("desc_bytes") or 64)
    # The in-memory descriptor sits immediately below the completion word. If that would
    # fall below DRAM base the payload would build its descriptor outside RAM, so refuse
    # rather than emit `0x-...`, which is not a valid C literal and fails with an
    # assembler error that says nothing about the real cause.
    desc_addr = ptr_done - desc_bytes
    if desc_addr < dram_base:
        raise ValueError(
            f"no room for a {desc_bytes}-byte descriptor below the completion word at "
            f"0x{ptr_done:x} (DRAM base 0x{dram_base:x}); pass a higher --ai-done-ptr"
        )
    flags["AI_DESC_BYTES"] = str(desc_bytes)
    flags["AI_DESC_ADDR"] = f"0x{desc_addr:x}"

    for field, macro in needed.items():
        off = _field_offset(fields, field)
        if off is None:
            raise ValueError(f"the model does not publish the {field} field offset")
        flags[macro] = str(off)

    return [f"-D{k}={v}" for k, v in flags.items()]


def _main() -> None:
    import json
    import sys

    if len(sys.argv) < 2:
        print("usage: payload_flags.py MODEL_JSON", file=sys.stderr)
        raise SystemExit(1)
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        model = json.load(f)
    for flag in compile_flags(model):
        print(flag)


if __name__ == "__main__":
    _main()
