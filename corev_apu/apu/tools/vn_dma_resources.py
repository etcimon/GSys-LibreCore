#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Owned DMA leases for the native backend, not a guest protocol parser.

The serialized backend owns all mapping mutations. Direct edits to the policy
are detected before access/revocation; raw fixture memory is not a guest API.
"""
from dataclasses import dataclass

from vn_dma import DmaPolicy, DmaRegion, GuestDma


@dataclass(frozen=True)
class DmaLease:
    context: int
    resource: int
    generation: int
    regions: tuple


class ResourceDma:
    """Context/resource ownership plus initially deny-all, scoped DMA access."""

    def __init__(self, memory):
        self._dma = GuestDma(memory)
        self._leases = {}
        # Native capabilities never wrap. They are not wire-format object IDs.
        self._generation = 0

    @property
    def policy(self):
        return self._dma.policy

    @staticmethod
    def _context(context):
        if type(context) is not int or not 0 <= context <= 0xFFFFFFFF:
            raise ValueError('invalid DMA context')

    def register(self, context, resource, regions):
        self._context(context)
        if type(resource) is not int or not 0 < resource <= 0xFFFFFFFF:
            raise ValueError('invalid DMA resource')
        key = (context, resource)
        if key in self._leases:
            raise KeyError('DMA resource is already registered')
        scope = DmaPolicy(self._dma.memory.size_bytes)
        added = []
        try:
            for region in regions:
                if not isinstance(region, DmaRegion):
                    raise TypeError('DMA mappings must be DmaRegion records')
                scope.grant(region.base, region.size, read=region.read, write=region.write)
                added.append(self.policy.grant(region.base, region.size,
                                               read=region.read, write=region.write))
            if not added:
                raise ValueError('DMA resource has no mappings')
        except BaseException:
            # Registration is all-or-nothing, including overlaps late in a batch.
            for region in reversed(added):
                self.policy.revoke(region.base, region.size)
            raise
        self._generation += 1
        lease = DmaLease(context, resource, self._generation, tuple(added))
        self._leases[key] = (lease, scope)
        return lease

    def _live(self, lease):
        if not isinstance(lease, DmaLease):
            raise KeyError('invalid DMA lease')
        current = self._leases.get((lease.context, lease.resource))
        if current is None or current[0] is not lease:
            raise KeyError('stale DMA lease')
        active = self.policy.regions
        if any(not any(region is item for item in active) for region in lease.regions):
            raise KeyError('DMA policy changed outside its resource owner')
        return current[1]

    def revoke(self, lease):
        self._live(lease)
        for region in lease.regions:
            self.policy.revoke(region.base, region.size)
        del self._leases[(lease.context, lease.resource)]

    def revoke_context(self, context):
        self._context(context)
        leases = [lease for (owner, _), (lease, _) in self._leases.items()
                  if owner == context]
        for lease in leases:
            self._live(lease)
        for lease in leases:
            self.revoke(lease)
        return len(leases)

    def read(self, lease, address, size):
        self._live(lease).check(address, size)
        return self._dma.read(address, size)

    def write(self, lease, address, data):
        view = memoryview(data)
        self._live(lease).check(address, view.nbytes, write=True)
        self._dma.write(address, view)
