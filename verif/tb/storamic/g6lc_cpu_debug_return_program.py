# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Independent seven-write debug-return firmware; the six-write images are unchanged."""
import argparse
import hashlib
import json
from pathlib import Path

from g6lc_cpu_debug_program import build_debug_program


def build_return_program(privilege=3):
    normal, original = build_debug_program(privilege)
    words = [int(word, 16) for word in original.splitlines()]
    resume = words.index(0x7b151073)  # CSRW DPC,x10 after the last verification load/fence.
    if words[resume + 1] != 0x7b200073 or words[-1] != 0x13:
        raise ValueError("unexpected debug handler layout")
    words.insert(resume, (6 << 20) | (5 << 15) | (2 << 12) | (28 << 7) | 0x23)
    words.pop()
    return normal, "".join(f"{word:08x}\n" for word in words).encode("ascii")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--entry-privilege", type=int, choices=(0, 1, 3), default=3)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    out = args.output_root.resolve()
    if not out.is_relative_to(repo / "build-platform/workspace"):
        parser.error("output must be contained in build-platform/workspace")
    normal, debug = build_return_program(args.entry_privilege)
    out.mkdir(exist_ok=False)
    (out / "program.hex").write_bytes(normal)
    (out / "debug.hex").write_bytes(debug)
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    report = {"status": "prepared", "qualification": False, "scope": "seven-write debug return firmware only",
              "entry_privilege": args.entry_privilege, "expected_writes": 7, "expected_reads": 4,
              "debug_writes": 4, "debug_reads": 2, "held_debug_offset": 28,
              "program_sha256": sha(out / "program.hex"), "debug_sha256": sha(out / "debug.hex"),
              "generator_sha256": sha(Path(__file__)),
              "base_generator_sha256": sha(Path(__file__).with_name("g6lc_cpu_debug_program.py"))}
    (out / "result.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
