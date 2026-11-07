#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Reusable APU device state, independent of wire/vector generation.

The extracted state owns object handles, ObjPay and aperture memory. It is not
a bridge server or CTS backend; wire dispatch remains in the golden front.
"""

from vn_memory import ApertureState, SparseMemory
from vn_objects import ObjectTable

PAY_CHUNK = 64


class PayloadMemory:
    """Next-fit ObjPay state shared by the golden front and future backend."""

    def __init__(self, pay_words):
        self.pay_words = pay_words
        self.reset_payload()

    def reset_payload(self):
        # Chunk zero is the null-extent sentinel. Cursor counts bitmap words.
        self.pay_bits = 1
        self.pay_cur = 0
        self.pay = {}

    def pay_alloc(self, words):
        """Mirror StBmpCap: next-fit, carried runs, no extent across wrap."""
        if words == 0:
            return 0
        nch = (words + PAY_CHUNK - 1) // PAY_CHUNK
        bmpw = (self.pay_words // PAY_CHUNK + 63) // 64
        if nch > self.pay_words // PAY_CHUNK:
            return None
        scan, wrap, run, run_s = self.pay_cur, 0, 0, 0
        while True:
            bits = (self.pay_bits >> (scan * 64)) & 0xFFFFFFFFFFFFFFFF
            lsb = 64 if bits == 0 else (bits & -bits).bit_length() - 1
            riw = 64
            if nch <= 64:
                free = (~bits) & 0xFFFFFFFFFFFFFFFF
                m = free
                for i in range(1, 64):
                    if i < nch:
                        m &= free >> i
                riw = (m & -m).bit_length() - 1 if m else 64
            if run + lsb >= nch:
                a = run_s if run else scan * 64
            elif riw != 64:
                a = scan * 64 + riw
            else:
                a = -1
            if a >= 0:
                b = a + nch
                self.pay_bits |= ((1 << nch) - 1) << a
                self.pay_cur = (b >> 6) % bmpw
                return a * PAY_CHUNK
            if wrap == bmpw - 1:
                return None
            if bits == 0:
                if run == 0:
                    run_s = scan * 64
                run += 64
            else:
                ts = bits.bit_length() - 1
                run = 63 - ts
                run_s = scan * 64 + ts + 1
            wrap += 1
            if scan == bmpw - 1:
                scan, run, run_s = 0, 0, 0
            else:
                scan += 1

    def pay_free(self, base, words):
        if not words:
            return
        a = base // PAY_CHUNK
        nch = (words + PAY_CHUNK - 1) // PAY_CHUNK
        self.pay_bits &= ~(((1 << nch) - 1) << a)
        # FREE does not move the next-fit cursor.

    def pay_free_of(self, e):
        """Free an entry's aux[63:32] = {base_chunk, words} extent."""
        w = (e['aux'] >> 32) & 0xFFFF
        b = (e['aux'] >> 48) & 0xFFFF
        if w:
            self.pay_free(b << 6, w)
