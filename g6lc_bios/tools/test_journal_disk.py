# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT

import tempfile
import unittest
from pathlib import Path

from journal_disk import FW_A, FW_B, OFFSET, initial_record, make_disk, verify_disk


class JournalDiskTests(unittest.TestCase):
    def test_initial_record_is_g6bh_provisioning(self):
        rec = initial_record()
        self.assertEqual(rec[:4], b"G6BH")
        self.assertEqual(rec[16], 1)
        self.assertEqual(rec[18], 1)
        self.assertEqual(len(rec), 4096)

    def test_round_trip_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "j.img"
            make_disk(path)
            verify_disk(path)
            data = path.read_bytes()
            self.assertEqual(data[510:512], b"\x55\xaa")
            self.assertEqual(data[OFFSET : OFFSET + 4], b"G6BH")
            self.assertEqual(data[FW_A : FW_A + 4], b"G6FA")
            self.assertEqual(data[FW_B : FW_B + 4], b"G6FB")


if __name__ == "__main__":
    unittest.main()
