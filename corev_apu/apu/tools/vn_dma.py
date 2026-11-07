#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Guest DMA grants for the native backend; caller serializes map/access changes."""
from bisect import bisect_left, bisect_right
from dataclasses import dataclass


@dataclass(frozen=True)
class DmaRegion:
    base: int
    size: int
    read: bool
    write: bool

    @property
    def end(self):
        return self.base + self.size


class DmaPolicy:
    """Nonoverlapping grants. An empty policy denies every nonempty transfer."""

    def __init__(self, size_bytes=1 << 64):
        if type(size_bytes) is not int or not 0 < size_bytes <= 1 << 64:
            raise ValueError('invalid guest DMA address space')
        self.size_bytes = size_bytes
        self._bases = []
        self._regions = []

    @property
    def regions(self):
        return tuple(self._regions)

    def _range(self, address, size):
        if type(address) is not int or type(size) is not int:
            raise TypeError('DMA addresses and sizes must be integers')
        if address < 0 or size < 0 or address + size > self.size_bytes:
            raise ValueError('DMA range outside guest address space')

    def grant(self, base, size, *, read=True, write=False):
        self._range(base, size)
        if type(read) is not bool or type(write) is not bool:
            raise TypeError('DMA permissions must be booleans')
        if not size or not (read or write):
            raise ValueError('empty DMA grant')
        index = bisect_left(self._bases, base)
        if ((index and self._regions[index - 1].end > base) or
                (index < len(self._regions) and base + size > self._bases[index])):
            raise ValueError('overlapping DMA grants')
        region = DmaRegion(base, size, read, write)
        self._bases.insert(index, base)
        self._regions.insert(index, region)
        return region

    def revoke(self, base, size):
        self._range(base, size)
        index = bisect_left(self._bases, base)
        if (index >= len(self._regions) or self._bases[index] != base or
                self._regions[index].size != size):
            raise KeyError('DMA revoke must match an existing grant')
        del self._bases[index]
        del self._regions[index]

    def check(self, address, size, *, write=False):
        if type(write) is not bool:
            raise TypeError('DMA access direction must be boolean')
        self._range(address, size)
        if not size:
            return
        end = address + size
        index = max(0, bisect_right(self._bases, address) - 1)
        # Adjacent regions may authorize a transfer, but every byte and every
        # permission is checked before the backing store can be modified.
        while index < len(self._regions):
            region = self._regions[index]
            if (region.base > address or region.end <= address or
                    not (region.write if write else region.read)):
                break
            address = min(end, region.end)
            if address == end:
                return
            index += 1
        raise PermissionError('guest DMA range is not authorized')


class GuestDma:
    """Authorized view over SparseMemory. No grants are installed implicitly."""

    def __init__(self, memory, policy=None):
        self.memory = memory
        self.policy = policy if policy is not None else DmaPolicy(memory.size_bytes)
        if not isinstance(self.policy, DmaPolicy):
            raise TypeError('DMA policy must be a DmaPolicy')

    def read(self, address, size):
        self.memory._check_range(address, size)
        self.policy.check(address, size)
        return self.memory.read(address, size)

    def write(self, address, data):
        view = memoryview(data)
        self.memory._check_range(address, view.nbytes)
        self.policy.check(address, view.nbytes, write=True)
        self.memory.write(address, view)
