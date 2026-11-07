#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Generation-checked borrowed VkDeviceMemory backing for native blob aliases."""


class MemoryOwner:
    def __init__(self, execution, context, handle, entry):
        self.execution, self.context = execution, context
        self.handle, self.entry = handle, entry
        self.refs = 0
        self.work_refs = 0
        self.deferred_free = None

    def _live(self):
        if self.context.owners.get(self.handle) is not self:
            raise KeyError('forged memory owner capability')
        golden = self.execution.golden
        status, _, entry = self.context.frontend.resolve(
            self.handle, golden.KIND['VkDeviceMemory'])
        if status != 'OK' or entry is not self.entry:
            raise KeyError('stale memory owner capability')
        return entry

    @property
    def size(self):
        page = self.execution.state.page_bytes
        size = self._live()['size']
        return (size + page - 1) // page * page

    @property
    def base(self):
        base = self._live()['aux'] >> 32 & 0xFFFFFFFF
        return None if base == self.execution.golden.UNBACKED else base

    def pin(self):
        self._pin(False)

    def pin_work(self):
        self._pin(True)

    def _pin(self, work):
        entry = self._live()
        if self.context.retired or self.deferred_free is not None:
            raise KeyError('memory owner no longer admits new references')
        if entry['pins'] >= 255:
            raise MemoryError('memory pin counter exhausted')
        if self.context.frontend.pin(self.handle) != 'OK':
            raise KeyError('cannot pin memory owner')
        if work:
            self.work_refs += 1
        else:
            self.refs += 1

    def unpin(self):
        self._unpin(False)

    def unpin_work(self):
        self._unpin(True)

    def _unpin(self, work):
        self._live()
        if (self.work_refs if work else self.refs) <= 0:
            raise KeyError('unbalanced borrowed memory release')
        self.context.frontend.unpin(self.handle)
        if work:
            self.work_refs -= 1
        else:
            self.refs -= 1
        if self.context.retired:
            self.context.frontend.reset_ctx(self.context.frontend.ctx)
        elif self.refs + self.work_refs == 0 and self.deferred_free is not None:
            release, self.deferred_free = self.deferred_free, None
            release()

    def relocate(self, base):
        entry = self._live()
        if entry['pins'] > self.refs:
            raise BlockingIOError('memory has non-blob users')
        state, size, old = self.execution.state, self.size, self.base
        page = state.page_bytes
        if (type(base) is not int or base < 0 or base % page or
                base + size > state.aperture.size_bytes):
            raise ValueError('memory owner relocation out of bounds')
        if old == base:
            return
        previous = set() if old is None else set(range(old // page, (old + size) // page))
        target = set(range(base // page, (base + size) // page))
        if any(state.ap_pages[p] and p not in previous for p in target):
            raise ValueError('memory owner relocation overlaps another extent')
        if old is not None:
            data = state.aperture.read(old, size)
            state.aperture.write(base, data)
        for p in previous - target:
            state.ap_pages[p] = 0
        for p in target:
            state.ap_pages[p] = 1
        entry['aux'] = base << 32 | (entry['aux'] & 0xFFFFFFFE)
