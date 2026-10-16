#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""`tools/rtlil_width_map.py`: RTLIL wires -> per-module elaborated widths."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))

from rtlil_width_map import base_module_name, parse_rtlil, split_rtlil  # noqa: E402

RTLIL = """\
autoidx 42
attribute \\src "instr_queue.sv:1.1-900.10"
module \\instr_queue$cva6.i_frontend.i_instr_queue
  wire input 1 \\clk_i
  wire width 4 input 2 \\valid_i
  wire width 8 \\slot_fifo
  wire width 2 \\idx_is_q
  wire width 64 $auto$proc_dff.cc:123:tmp$7
  cell $add $add$x:1
  end
end
module \\instr_queue$cva6.i_frontend2.i_instr_queue
  wire width 16 \\slot_fifo
  wire width 2 \\idx_is_q
end
module cva6
  wire width 64 output 3 \\data_o
end
"""


class RtlilWidthMapTest(unittest.TestCase):
    def test_base_name_strips_slang_specialization(self) -> None:
        self.assertEqual(base_module_name("\\instr_queue$cva6.i_frontend.i_instr_queue"), "instr_queue")
        self.assertEqual(base_module_name("cva6"), "cva6")
        self.assertEqual(base_module_name("\\alu"), "alu")

    def test_wires_are_keyed_by_base_module_with_widest_specialization(self) -> None:
        mods = parse_rtlil(RTLIL.splitlines(keepends=True))
        self.assertEqual(set(mods), {"instr_queue", "cva6"})
        iq = mods["instr_queue"]
        self.assertEqual(iq["clk_i"], 1, "a wire without `width` is one bit")
        self.assertEqual(iq["valid_i"], 4, "attributes before the name are skipped")
        self.assertEqual(iq["slot_fifo"], 16, "two specializations: the widest wins")
        self.assertEqual(iq["idx_is_q"], 2)
        self.assertNotIn("auto", " ".join(iq), "internal $-wires are not nets")
        self.assertFalse(any(k.startswith("$") for k in iq))
        self.assertEqual(mods["cva6"], {"data_o": 64})


class RtlilSplitTest(unittest.TestCase):
    def test_split_writes_one_file_per_module_with_the_header(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            written = split_rtlil(RTLIL.splitlines(keepends=True), out)
            self.assertEqual([n for _, _, n in written], [
                "\\instr_queue$cva6.i_frontend.i_instr_queue",
                "\\instr_queue$cva6.i_frontend2.i_instr_queue",
                "cva6",
            ])
            self.assertEqual(written[0][1].name, "0001_instr_queue_cva6.i_frontend.i_instr_queue.il")
            first = written[0][1].read_text(encoding="utf-8")
            self.assertTrue(first.startswith("autoidx 42\n"), first[:40])
            self.assertIn("attribute \\src", first, "attributes before `module` travel with it")
            self.assertIn("  wire width 8 \\slot_fifo\n", first)
            self.assertTrue(first.rstrip().endswith("end"))
            self.assertNotIn("i_frontend2", first)
            third = written[2][1].read_text(encoding="utf-8")
            self.assertIn("module cva6\n", third)
            self.assertNotIn("attribute", third)
            tsv = (out / "modules.tsv").read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(tsv), 3)
            self.assertTrue(tsv[2].startswith("3\t0003_cva6.il\tcva6"))


if __name__ == "__main__":
    unittest.main()
