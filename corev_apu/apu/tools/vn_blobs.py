#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Native blob-owned aperture extents; no VkDeviceMemory aliasing yet."""
from contextlib import contextmanager
from dataclasses import dataclass


@dataclass(frozen=True)
class BlobMapping:
    resource: int
    generation: int
    base: int
    size: int


@dataclass
class Blob:
    size: int
    mapping: object = None
    mapped: bool = False
    pins: int = 0


class BlobStore:
    """Serialized metadata transactions over one native ApertureState.

    Relocation snapshots bytes before overlapping moves. Synchronous I/O errors
    propagate without publishing new ownership; remote bus failure additionally
    requires device reset, since already-written external bytes cannot roll back.
    """

    def __init__(self, state, *, max_blobs=4096):
        if type(max_blobs) is not int or max_blobs <= 0 or state.blobs:
            raise ValueError('invalid or already-owned blob catalogue')
        self.state = state
        self.blobs = state.blobs
        self.max_blobs = max_blobs
        self._generation = 0

    def create(self, resource, size):
        if (type(resource) is not int or not 0 < resource <= 0xFFFFFFFF or
                type(size) is not int or not 0 < size <= self.state.guest_bytes):
            raise ValueError('invalid blob resource or extent')
        if resource in self.blobs:
            raise KeyError('blob already exists')
        if len(self.blobs) >= self.max_blobs:
            raise MemoryError('blob budget exhausted')
        self.blobs[resource] = Blob(size)

    def _pages(self, mapping):
        if mapping is None:
            return set()
        page = self.state.page_bytes
        return set(range(mapping.base // page,
                         (mapping.base + mapping.size + page - 1) // page))

    def _move(self, resource, base, mapped):
        blob = self.blobs[resource]
        if blob.pins:
            raise BlockingIOError('blob mapping is pinned')
        old = blob.mapping
        if old is not None and old.base == base and blob.mapped == mapped:
            return old
        page = self.state.page_bytes
        limit = self.state.guest_bytes if mapped else self.state.aperture.size_bytes
        lo = 0 if mapped else self.state.guest_bytes
        if (type(base) is not int or base < lo or base % page or
                base + blob.size > limit):
            raise ValueError('blob mapping outside aperture partition')
        self._generation += 1
        new = BlobMapping(resource, self._generation, base, blob.size)
        old_pages, new_pages = self._pages(old), self._pages(new)
        if any(self.state.ap_pages[p] and p not in old_pages for p in new_pages):
            raise ValueError('blob mapping overlaps a live allocation')
        if old is not None:
            data = self.state.aperture.read(old.base, blob.size)
            self.state.aperture.write(base, data)
        for p in old_pages - new_pages:
            self.state.ap_pages[p] = 0
        for p in new_pages:
            self.state.ap_pages[p] = 1
        blob.mapping, blob.mapped = new, mapped
        return new

    def map(self, resource, base):
        return self._move(resource, base, True)

    def unmap(self, resource):
        blob = self.blobs[resource]
        if not blob.mapped:
            return
        if blob.pins:
            raise BlockingIOError('blob mapping is pinned')
        page = self.state.page_bytes
        count = (blob.size + page - 1) // page
        for start in range(self.state.guest_pages, len(self.state.ap_pages) - count + 1):
            if not any(self.state.ap_pages[start:start + count]):
                self._move(resource, start * page, False)
                return
        raise MemoryError('private aperture exhausted')

    def unref(self, resource):
        blob = self.blobs[resource]
        if blob.pins:
            raise BlockingIOError('blob mapping is pinned')
        for p in self._pages(blob.mapping):
            self.state.ap_pages[p] = 0
        del self.blobs[resource]

    def mapping(self, resource):
        blob = self.blobs[resource]
        if not blob.mapped:
            raise KeyError('blob has no guest mapping')
        return blob.mapping

    def _live(self, mapping, offset, size):
        if not isinstance(mapping, BlobMapping):
            raise KeyError('invalid blob mapping')
        blob = self.blobs.get(mapping.resource)
        if blob is None or blob.mapping is not mapping or not blob.mapped:
            raise KeyError('stale blob mapping')
        if (type(offset) is not int or type(size) is not int or
                offset < 0 or size < 0 or offset + size > mapping.size):
            raise ValueError('access exceeds blob extent')
        return blob

    def read(self, mapping, offset, size):
        self._live(mapping, offset, size)
        return self.state.aperture.read(mapping.base + offset, size)

    def write(self, mapping, offset, data):
        data = memoryview(data).tobytes()
        self._live(mapping, offset, len(data))
        self.state.aperture.write(mapping.base + offset, data)

    @contextmanager
    def pin(self, mapping):
        blob = self._live(mapping, 0, 0)
        blob.pins += 1
        try:
            yield mapping
        finally:
            blob.pins -= 1
