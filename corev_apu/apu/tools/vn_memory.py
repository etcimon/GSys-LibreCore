#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Sparse device memory and aperture ownership, without Venus encoding.

Legacy allocator methods use word bases unless their name/docstring says
otherwise. DMA and aperture byte-access methods always use byte addresses.
An explicit DMA policy gates the byte API and stream fetches. Direct word
dictionaries remain trusted fixture/device-state interfaces, not guest APIs.
"""
from collections import defaultdict
from vn_dma import GuestDma


class SparseMemory:
    """Byte-access view over an existing sparse little-endian word dictionary."""

    def __init__(self, words, size_bytes):
        if size_bytes < 0:
            raise ValueError('negative memory size')
        self.words = words
        self.size_bytes = size_bytes

    def _check_range(self, address, size):
        if not isinstance(address, int) or not isinstance(size, int):
            raise TypeError('memory addresses and sizes must be integers')
        if address < 0 or size < 0 or address + size > self.size_bytes:
            raise ValueError('memory access outside address space')

    def read(self, address, size):
        self._check_range(address, size)
        result = bytearray()
        end = address + size
        while address < end:
            lane = address & 3
            count = min(4 - lane, end - address)
            word = self.words.get(address >> 2, 0) & 0xFFFFFFFF
            result.extend(word.to_bytes(4, 'little')[lane:lane + count])
            address += count
        return bytes(result)

    def write(self, address, data):
        # Snapshot a bytes-like input and check the entire range before writes.
        data = memoryview(data).tobytes()
        self._check_range(address, len(data))
        pos = 0
        while pos < len(data):
            lane = address & 3
            count = min(4 - lane, len(data) - pos)
            shift = 8 * lane
            mask = ((1 << (8 * count)) - 1) << shift
            old = self.words.get(address >> 2, 0)
            value = int.from_bytes(data[pos:pos + count], 'little') << shift
            self.words[address >> 2] = ((old & ~mask) | value) & 0xFFFFFFFF
            address += count
            pos += count


class ApertureState:
    """Shared vgpages allocation, sparse RAM and blob resource metadata."""

    def __init__(self, total_bytes, guest_bytes, page_bytes=4096, *, dma_policy=None):
        if (page_bytes < 4 or page_bytes & (page_bytes - 1) or
                total_bytes <= 0 or total_bytes % page_bytes or
                guest_bytes < 0 or guest_bytes > total_bytes or
                guest_bytes % page_bytes):
            raise ValueError('invalid aperture geometry')
        self.page_bytes = page_bytes
        self.guest_bytes = guest_bytes
        self.guest_pages = guest_bytes // page_bytes
        self.ap = defaultdict(int)
        self.ap_pages = [0] * (total_bytes // page_bytes)
        self.gmem = {}
        self.blobs = {}
        self.aperture = SparseMemory(self.ap, total_bytes)
        self.guest_ram = SparseMemory(self.gmem, 1 << 64)
        # Preserve legacy golden fixtures; backend callers install an explicit
        # (initially deny-all) policy before admitting guest DMA.
        self.dma = (GuestDma(self.guest_ram, dma_policy)
                    if dma_policy is not None else self.guest_ram)

    def dma_read(self, address, size):
        return self.dma.read(address, size)

    def dma_write(self, address, data):
        self.dma.write(address, data)

    def aperture_read(self, address, size):
        """Device-domain access; includes the private arena, unlike MAP_BLOB."""
        return self.aperture.read(address, size)

    def aperture_write(self, address, data):
        self.aperture.write(address, data)

    def ap_alloc(self, size, priv=False):
        """First-fit ALLOC/ALLOC_PRIV, returning a word base or -1."""
        pages = (size + self.page_bytes - 1) // self.page_bytes
        lo = self.guest_pages if priv else 0
        hi = len(self.ap_pages) if priv else self.guest_pages
        run = 0
        for i in range(lo, hi):
            run = 0 if self.ap_pages[i] else run + 1
            if run == pages:
                base = (i - pages + 1) * (self.page_bytes // 4)
                for j in range(i - pages + 1, i + 1):
                    self.ap_pages[j] = 1
                return base
        return -1

    def ap_free(self, base_w, size):
        # Drop every page touched by the byte range, as ALLOC_AT marks it.
        lo = (base_w * 4) // self.page_bytes
        hi = (base_w * 4 + size - 1) // self.page_bytes
        for j in range(lo, hi + 1):
            self.ap_pages[j] = 0

    def ap_alloc_at(self, base_b, size):
        """Reserve a kernel-selected guest extent; return a byte base or -1."""
        if size == 0 or base_b + size > self.guest_bytes:
            return -1
        lo = base_b // self.page_bytes
        hi = (base_b + size - 1) // self.page_bytes
        if any(self.ap_pages[lo:hi + 1]):
            return -1
        for j in range(lo, hi + 1):
            self.ap_pages[j] = 1
        return base_b

    def ap_alloc_hi(self, size, excl=(0, 0)):
        """Top-down guest first-fit, excluding byte interval [lo, hi)."""
        pages = (size + self.page_bytes - 1) // self.page_bytes
        el, eh = excl
        for s in range(self.guest_pages - pages, -1, -1):
            if s * self.page_bytes < eh and el < (s + pages) * self.page_bytes:
                continue
            if not any(self.ap_pages[s:s + pages]):
                for j in range(s, s + pages):
                    self.ap_pages[j] = 1
                return s * (self.page_bytes // 4)
        return -1

    def ap_move(self, src_b, dst_b, size):
        """Relocate whole words; retain destination data even on overlap.

        Page ownership is managed separately by the caller. As in the previous
        model, vacated source contents are removed from the sparse shadow.
        """
        sw, dw = src_b >> 2, dst_b >> 2
        n = size // 4
        if dw > sw:
            for i in range(n - 1, -1, -1):
                self.ap[dw + i] = self.ap[sw + i]
        else:
            for i in range(n):
                self.ap[dw + i] = self.ap[sw + i]
        for i in range(n):
            if not dw <= sw + i < dw + n:
                self.ap.pop(sw + i, None)

    def blob_of(self, rid):
        blob = self.blobs.get(rid)
        return blob if blob is not None and blob['mapped'] else None

    def gmem_slice(self, byte_addr, nbytes):
        """Legacy aligned whole-word view used by stream decoding."""
        if isinstance(self.dma, GuestDma):
            if byte_addr & 3 or nbytes & 3:
                raise ValueError('guest stream fetch must be word aligned')
            data = self.dma_read(byte_addr, nbytes)
            return [int.from_bytes(data[i:i + 4], 'little')
                    for i in range(0, nbytes, 4)]
        return [self.gmem.get((byte_addr >> 2) + i, 0)
                for i in range(nbytes // 4)]
