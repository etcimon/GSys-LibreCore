#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Borrowed aliases share memory ownership; RESOURCE_UNREF never frees their pages."""
from vn_blobs import BlobStore, BlobMapping
from vn_borrowed_memory import MemoryOwner


class MemoryBlobs(BlobStore):
    def __init__(self, state, **kwargs):
        super().__init__(state, **kwargs)
        self.owners = {}

    def create_alias(self, resource, size, owner):
        if not isinstance(owner, MemoryOwner):
            raise TypeError('memory aliases require a host owner capability')
        if owner.execution.state is not self.state:
            raise KeyError('memory owner belongs to another device')
        if size > owner.size or owner.size > self.state.guest_bytes:
            raise ValueError('memory alias exceeds page-rounded owner extent')
        self.create(resource, size)
        try:
            owner.pin()
        except BaseException:
            del self.blobs[resource]
            raise
        self.owners[resource] = owner

    def _aliases(self, owner):
        return [(rid, self.blobs[rid]) for rid, item in self.owners.items() if item is owner]

    def _guard(self, owner):
        if any(blob.pins for _, blob in self._aliases(owner)):
            raise BlockingIOError('borrowed mapping has pinned aliases')

    def map(self, resource, base):
        owner = self.owners.get(resource)
        if owner is None:
            return super().map(resource, base)
        self._guard(owner)
        blob = self.blobs[resource]
        if (type(base) is not int or base < 0 or base % self.state.page_bytes or
                base + owner.size > self.state.guest_bytes):
            raise ValueError('memory alias outside guest aperture')
        for rid, alias in self._aliases(owner):
            if rid != resource and alias.mapped and alias.mapping.base != base:
                raise ValueError('simultaneous aliases require the same guest base')
        if blob.mapped and blob.mapping.base == base:
            return blob.mapping
        owner.relocate(base)
        self._generation += 1
        blob.mapping = BlobMapping(resource, self._generation, base, blob.size)
        blob.mapped = True
        return blob.mapping

    def unmap(self, resource):
        owner = self.owners.get(resource)
        if owner is None:
            return super().unmap(resource)
        self._guard(owner)
        blob = self.blobs[resource]
        if not blob.mapped:
            return
        other_mapped = any(rid != resource and alias.mapped
                           for rid, alias in self._aliases(owner))
        if not other_mapped:
            count = owner.size // self.state.page_bytes
            for start in range(self.state.guest_pages, len(self.state.ap_pages) - count + 1):
                if not any(self.state.ap_pages[start:start + count]):
                    owner.relocate(start * self.state.page_bytes)
                    break
            else:
                raise MemoryError('private backing unavailable for memory owner')
        blob.mapping, blob.mapped = None, False

    def unref(self, resource):
        owner = self.owners.get(resource)
        if owner is None:
            return super().unref(resource)
        if self.blobs[resource].pins:
            raise BlockingIOError('memory alias is pinned')
        owner._live()
        del self.blobs[resource]
        del self.owners[resource]
        owner.unpin()

    def _live(self, mapping, offset, size):
        blob = super()._live(mapping, offset, size)
        owner = self.owners.get(mapping.resource)
        if owner is not None and owner.base != mapping.base:
            raise KeyError('borrowed memory owner moved outside its alias manager')
        return blob
