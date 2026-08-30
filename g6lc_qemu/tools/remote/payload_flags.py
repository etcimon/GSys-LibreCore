#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# payload_flags.py — model-driven preprocessor flags and linker script for
# ai_island_smoke.S / ai_island_queue_smoke.S.
#
# The smoke payload is intentionally model-driven: it reads descriptor geometry,
# op/status tables, the island MMIO placement, and the DRAM base/length from the
# ingested TargetModel so that the same source can be compiled against any design
# package without hard-coding addresses, op values, or window bases.

from __future__ import annotations

from pathlib import Path


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
    dram_len = int(dram.get("len"), 0) if dram.get("len") else 0x1000_0000

    desc_bytes = int(layout.get("desc_bytes") or 64)
    # The done pointer and the descriptor below it must both fit inside DRAM.
    # The default 64 KiB offset is only safe when the design actually has 64 KiB
    # of headroom; otherwise move the completion word to the smallest valid
    # offset above the descriptor and below the end of RAM.
    min_offset = desc_bytes
    max_offset = dram_len - 8  # 8-byte completion word
    if min_offset > max_offset:
        raise ValueError(
            f"DRAM length 0x{dram_len:x} is too small for a {desc_bytes}-byte descriptor "
            f"plus an 8-byte completion word (base 0x{dram_base:x})"
        )
    default_offset = min(0x10000, max_offset)
    if default_offset < min_offset:
        default_offset = min_offset
    ptr_done = done_ptr if done_ptr is not None else dram_base + default_offset

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

    # Completion-word layout and status codes for the queue-instruction smoke, so the
    # payload can verify that ai.poll returns the ticket it submitted and the OK status.
    completion = layout.get("completion") or {}
    if completion:
        t_low = int(completion.get("ticket_bit_low") or 0)
        t_high = int(completion.get("ticket_bit_high") or 31)
        s_low = int(completion.get("status_bit_low") or 32)
        s_high = int(completion.get("status_bit_high") or 47)
    else:
        # The package did not publish make_completion; use the same fallback the
        # B1 device and B3 VM use (ticket in bits 0..31, status in bits 32..47).
        t_low, t_high = 0, 31
        s_low, s_high = 32, 47

    def _mask(low: int, high: int) -> int:
        if high < low:
            return 0
        return ((1 << (high - low + 1)) - 1) << low

    st_ok = (layout.get("statuses") or {}).get("ST_OK")
    if st_ok is None:
        st_ok = 0  # bring-up fallback; see g6q-vm/src/device.rs and g6q-emit-qemu
    flags["AI_ST_OK"] = str(int(st_ok))
    flags["AI_COMPLETION_TICKET_MASK"] = f"0x{_mask(t_low, t_high):x}ULL"
    flags["AI_COMPLETION_STATUS_SHIFT"] = str(s_low)
    flags["AI_COMPLETION_STATUS_MASK"] = f"0x{((1 << (s_high - s_low + 1)) - 1) if s_high >= s_low else 0:x}ULL"

    return [f"-D{k}={v}" for k, v in flags.items()]


def generate_payload_lds(model: dict, out_path: str | Path) -> Path:
    """Write a model-driven linker script for the smoke payloads.

    The link address and stack top come from `soc.dram.base` and
    `soc.dram.len` so that the payload is linked at the same DRAM base the
    native VM / QEMU machine uses.
    """
    soc = model.get("soc") or {}
    dram = soc.get("dram") or {}
    base = int(dram.get("base"), 0) if dram.get("base") else 0x8000_0000
    length = int(dram.get("len"), 0) if dram.get("len") else 0x1000_0000
    if length <= 0:
        length = 0x1000_0000
    stack_top = base + length

    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        f"""/* SPDX-License-Identifier: MIT */
/* Auto-generated by payload_flags.py from the ingested TargetModel. */

OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS {{
    . = 0x{base:x};
    .text : {{ *(.text*) }}
    .rodata : {{ *(.rodata*) }}
    .data : {{ *(.data*) }}
    .bss : {{ *(.bss*) *(COMMON) }}
    _stack_top = 0x{stack_top:x};

    /*
     * Without this, a *Linux-targeting* cross compiler (riscv64-linux-gnu-gcc) emits
     * .interp/.dynamic/.note and has to place the ELF program headers in a LOAD segment.
     * With .text pinned to the start of DRAM there is no room in front of it, so the
     * linker puts the segment one page *below* DRAM base. QEMU then reports
     * `image_low_addr` outside RAM, the payload never lands, and the reset vector jumps
     * into unmapped memory — a silent hang with no output at all.
     */
    /DISCARD/ : {{
        *(.interp)
        *(.dynamic)
        *(.dynsym)
        *(.dynstr)
        *(.hash)
        *(.gnu.hash)
        *(.gnu.version*)
        *(.note*)
        *(.comment)
        *(.riscv.attributes)
        *(.eh_frame*)
    }}
}}
""",
        encoding="utf-8",
    )
    return out


def _main() -> None:
    import json
    import sys

    if len(sys.argv) < 2:
        print("usage: payload_flags.py MODEL_JSON [--lds-out PATH]", file=sys.stderr)
        raise SystemExit(1)
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        model = json.load(f)
    if len(sys.argv) >= 4 and sys.argv[2] == "--lds-out":
        generate_payload_lds(model, sys.argv[3])
        print(f"wrote {sys.argv[3]}")
        return
    for flag in compile_flags(model):
        print(flag)


if __name__ == "__main__":
    _main()
