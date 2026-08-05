# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# erc.py — Electrical Rule Check helpers for the SKiDL design loop.
#
# `run_erc` wraps skidl.ERC() and captures the messages so the design loop can
# turn a failing net/part into a pcbparts.dev query (alternatives / pinout /
# footprint) and iterate, matching the "read ERC -> re-query -> fix" cycle.

from __future__ import annotations

import io
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import dataclass, field


@dataclass
class ErcReport:
    ok: bool
    errors: int
    warnings: int
    text: str
    messages: list[str] = field(default_factory=list)


def run_erc() -> ErcReport:
    """Run skidl.ERC() and return a structured report (never raises)."""
    try:
        import skidl  # noqa: PLC0415 (optional dependency)
    except Exception as exc:  # noqa: BLE001
        return ErcReport(False, 1, 0, f"skidl not importable: {exc}", [str(exc)])

    buf = io.StringIO()
    try:
        with redirect_stdout(buf), redirect_stderr(buf):
            skidl.ERC()
    except Exception as exc:  # noqa: BLE001
        text = buf.getvalue()
        return ErcReport(False, 1, 0, text + f"\nERC raised: {exc}", [str(exc)])

    text = buf.getvalue()
    errors = _count(text, "ERROR")
    warnings = _count(text, "WARNING")
    messages = [ln.strip() for ln in text.splitlines() if "ERROR" in ln or "WARNING" in ln]
    return ErcReport(errors == 0, errors, warnings, text, messages)


def _count(text: str, token: str) -> int:
    return sum(1 for line in text.splitlines() if token in line)
