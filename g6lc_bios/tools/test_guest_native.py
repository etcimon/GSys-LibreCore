# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT

import struct
import unittest

from guest_native import archive_entry, validate_image, ROLE

BASE = 0x84000000
NAME = b"_ZN9g6b_guest12native_entry17h0123456789abcdefE"


def image():
    data = bytearray(0x1100)
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHIQQQIHHHHHH", data, 16, 2, 243, 1, BASE, 64, 0, 1, 64, 56, 1, 64, 0, 0)
    struct.pack_into("<IIQQQQQQ", data, 64, 1, 5, 0x1000, BASE, BASE, 16, 16, 4096)
    return data


def archive():
    names = b"\0" + NAME + b"\0"
    data = bytearray(64 + 3 * 64 + 48 + len(names))
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHIQQQIHHHHHH", data, 16, 1, 243, 1, 0, 0, 64, 1, 64, 0, 0, 64, 3, 0)
    struct.pack_into("<IIQQQQIIQQ", data, 128, 0, 2, 0, 0, 256, 48, 2, 0, 8, 24)
    struct.pack_into("<IIQQQQIIQQ", data, 192, 0, 3, 0, 0, 304, len(names), 0, 0, 1, 0)
    struct.pack_into("<IBBHQQ", data, 280, 1, 0x12, 0, 1, 0, 16)
    data[304:] = names
    header = (
        b"guest.o/        "
        + b"0           "
        + b"0     "
        + b"0     "
        + b"644     "
        + str(len(data)).encode().ljust(10)
        + b"`\n"
    )
    return b"!<arch>\n" + header + data + (b"\n" if len(data) % 2 else b"")


class NativeImageTests(unittest.TestCase):
    def test_image_reports_checked_callee_contract(self):
        report = validate_image(bytes(image()), BASE)
        self.assertEqual(report["entry"], BASE)
        self.assertEqual(report["frame_bytes"], 256)
        self.assertEqual(report["segments"][0]["flags"], 5)
        self.assertEqual(report["role"], ROLE)
        self.assertIn("not-bootable", report["role"])

    def test_wrong_machine_truncation_and_entry_are_refused(self):
        for at, fmt, value in [
            (18, "<H", 62),
            (24, "<Q", BASE + 20),
            (24, "<Q", BASE + 1),
            (64 + 32, "<Q", 8192),
        ]:
            data = image()
            struct.pack_into(fmt, data, at, value)
            with self.assertRaises(ValueError):
                validate_image(bytes(data), BASE)
        for length in [0, 63, 119, 4095]:
            with self.assertRaises(ValueError):
                validate_image(bytes(image()[:length]), BASE)

    def test_wx_dynamic_rw_bss_and_unbounded_segments_are_refused(self):
        for at, fmt, value in [
            (68, "<I", 7),
            (68, "<I", 6),
            (64, "<I", 2),
            (64 + 40, "<Q", 1 << 25),
            (64 + 24, "<Q", BASE + 4096),
            (64 + 48, "<Q", 1),
            (64 + 40, "<Q", 32),
        ]:
            data = image()
            struct.pack_into(fmt, data, at, value)
            with self.assertRaises(ValueError):
                validate_image(bytes(data), BASE)
        for base in [0, BASE + 1, 1 << 64]:
            with self.assertRaises(ValueError):
                validate_image(bytes(image()), base)

    def test_overlapping_segments_are_refused(self):
        data = image()
        struct.pack_into("<H", data, 56, 2)
        data[120:176] = data[64:120]
        with self.assertRaises(ValueError):
            validate_image(bytes(data), BASE)

    def test_archive_has_one_defined_entry_without_unmangled_exports(self):
        self.assertEqual(archive_entry(archive()), NAME.decode())
        data = archive()
        with self.assertRaises(ValueError):
            archive_entry(data + data[8:])
        for length in [0, 8, 67, len(data) - 1]:
            with self.assertRaises(ValueError):
                archive_entry(data[:length])


if __name__ == "__main__":
    unittest.main()
