# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Firmware generator checks, not CPU/privilege implementation qualification."""
import hashlib
import unittest

from g6lc_cpu_origin_program import build_program


def signed(value, width):
    return value - (1 << width) if value & (1 << (width - 1)) else value


def branch_offset(word):
    return signed(((word >> 31) << 12) | (((word >> 7) & 1) << 11) |
                  (((word >> 25) & 63) << 5) | (((word >> 8) & 15) << 1), 13)


def trace_program(image, corrupt_read=False):
    words = [int(word, 16) for word in image.splitlines()]
    regs, csrs, memory, stores = [0] * 32, {}, {}, []
    pc, mode, reads = 0x80000000, 3, 0
    for _ in range(256):
        word = words[(pc - 0x80000000) // 4]
        opcode, rd, rs1, rs2 = word & 127, (word >> 7) & 31, (word >> 15) & 31, (word >> 20) & 31
        next_pc = pc + 4
        if opcode == 0x17:
            regs[rd] = pc + signed(word & 0xfffff000, 32)
        elif opcode == 0x37:
            regs[rd] = signed(word & 0xfffff000, 32)
        elif opcode == 0x13:
            if (word >> 12) & 7 == 5:
                regs[rd] = regs[rs1] >> ((word >> 20) & 63)
            else:
                assert (word >> 12) & 7 == 0
                regs[rd] = regs[rs1] + signed(word >> 20, 12)
        elif word == 0x30200073:
            next_pc, mode = csrs[0x341], (csrs[0x300] >> 11) & 3
            if mode != 3:
                csrs[0x300] &= ~(1 << 17)
        elif word == 0x10200073:
            next_pc, mode = csrs[0x141], (csrs[0x100] >> 8) & 1
        elif opcode == 0x73:
            assert rd == 0 and (word >> 12) & 7 == 1
            csrs[word >> 20] = regs[rs1]
        elif opcode == 0x23:
            offset = signed(((word >> 25) << 5) | ((word >> 7) & 31), 12)
            address = regs[rs1] + offset
            value = regs[rs2] & 0xffffffff
            status = csrs.get(0x300, 0)
            effective = (status >> 11) & 3 if status & (1 << 17) else mode
            stores.append((address - 0x50000000, value, mode, effective))
            memory[address] = value
            if address in (0x50000020, 0x50000024):
                return stores, reads
        elif opcode == 0x03:
            address = regs[rs1] + signed(word >> 20, 12)
            regs[rd] = signed(memory[address], 32)
            reads += 1
            if corrupt_read:
                regs[rd] ^= 1
        elif opcode == 0x63:
            assert (word >> 12) & 7 == 1
            if regs[rs1] != regs[rs2]:
                next_pc = pc + branch_offset(word)
        elif opcode == 0x0f:
            pass
        else:
            raise AssertionError(f"unexpected instruction {word:08x}")
        regs = [value & ((1 << 64) - 1) for value in regs]
        regs[0] = 0
        pc = next_pc
    raise AssertionError("program did not reach a completion or failure store")


class ProgramTests(unittest.TestCase):
    def test_legacy_image_unchanged(self):
        self.assertEqual(hashlib.sha256(build_program()).hexdigest(),
                         "ee0fd42bb5d49c4bf8e370e0853c70231ba724bbb074473ba33e8cf4e8ca36a6")

    def test_legacy_privilege_sequence(self):
        stores, reads = trace_program(build_program())
        self.assertEqual(stores, [(0, 0x11, 3, 3), (24, 0x44, 3, 1), (8, 0x22, 1, 1),
                                  (16, 0x33, 0, 0), (32, 0x55, 0, 0)])
        self.assertEqual(reads, 4)

    def test_extended_effective_privilege_sequence(self):
        stores, reads = trace_program(build_program(True))
        self.assertEqual(stores, [(0, 0x11, 3, 3), (24, 0x44, 3, 1), (40, 0x66, 3, 0),
                                  (48, 0x77, 3, 3), (8, 0x22, 1, 1),
                                  (16, 0x33, 0, 0), (32, 0x55, 0, 0)])
        self.assertEqual(reads, 6)

    def test_non_machine_sections_unchanged(self):
        basic, extended = build_program().splitlines(), build_program(True).splitlines()
        self.assertEqual(len(extended), 1024)
        self.assertEqual(basic[64:], extended[64:])

    def test_all_readback_failure_branches_target_trap(self):
        for extended in (False, True):
            branches = 0
            for index, raw in enumerate(build_program(extended).splitlines()):
                word = int(raw, 16)
                if word & 127 == 0x63:
                    branches += 1
                    self.assertEqual(index * 4 + branch_offset(word), 0x300)
            self.assertEqual(branches, 6 if extended else 4)

    def test_corrupted_readback_reaches_failure_store(self):
        for extended in (False, True):
            stores, reads = trace_program(build_program(extended), corrupt_read=True)
            self.assertEqual(stores[-1][:2], (36, 0x7f))
            self.assertEqual(reads, 1)


if __name__ == "__main__":
    unittest.main()
