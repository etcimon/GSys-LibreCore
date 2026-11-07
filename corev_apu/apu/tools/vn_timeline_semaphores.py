#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Native diagnostic timeline creation, host APIs and queued value state."""
from vn_rings import RingBlocked
from vn_timeline_jobs import TimelineJobs


class TimelineSemaphores:
    NAMES = frozenset(('vkGetSemaphoreCounterValue', 'vkSignalSemaphore', 'vkWaitSemaphores'))

    def __init__(self, submissions, reader):
        self.submissions, self.reader = submissions, reader
        self.values = {}
        self.jobs = TimelineJobs(self)

    def creation(self, words):
        r, model = self.reader(words), self.submissions.execution.model
        r.u64()
        if r.u64() != 1 or r.u32() != model.stype_values['VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO']:
            raise ValueError('invalid native semaphore create info')
        kind, value = 0, 0
        chain = r.u64()
        if chain:
            if (chain != 1 or
                    r.u32() != model.stype_values['VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO'] or
                    r.u64()):
                raise ValueError('external/extended semaphore creation is not admitted')
            kind, value = r.u32(), r.u64()
            if kind not in (0, 1) or not kind and value:
                raise ValueError('invalid semaphore type/initial value')
        if r.u32() or r.u64() not in (0, 1) or r.u64() != 1:
            raise ValueError('invalid native semaphore flags/pointers')
        r.u64()
        r.end()
        return kind, value

    def _object(self, context, value, device):
        handle, entry = self.submissions._object(context, value, 'VkSemaphore')
        key = id(context), handle
        if entry['parent'] != device or key not in self.values:
            raise KeyError('native timeline generation/type/device mismatch')
        return key

    def host(self, current, name, words):
        context = self.submissions.execution.contexts[current.frontend.ctx]
        model = self.submissions.execution.model
        r = self.reader(words)
        device, _ = self.submissions._object(context, r.u64(), 'VkDevice')
        device &= 0xFFFF
        if self.submissions.lost(context):
            return self.submissions.execution.golden.VK_ERR_LOST, []
        if name == 'vkGetSemaphoreCounterValue':
            key = self._object(context, r.u64(), device)
            if r.u64() != 1:
                raise ValueError('timeline counter output pointer is absent')
            r.end()
            value = self.values[key]
            return 0, [value & 0xFFFFFFFF, value >> 32]
        stype = ('VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO' if name == 'vkSignalSemaphore'
                 else 'VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO')
        if r.u64() != 1 or r.u32() != model.stype_values[stype] or r.u64():
            raise ValueError('timeline host operation has unsupported info/chain')
        if name == 'vkSignalSemaphore':
            key, value = self._object(context, r.u64(), device), r.u64()
            r.end()
            if value <= self.values[key]:
                raise ValueError('timeline signal must strictly increase the counter')
            self.jobs.host_signal(key, value)
            self.values[key] = value
            return 0, []
        flags, count = r.u32(), r.u32()
        r.array(count, 16)
        if flags & ~1 or not count:
            raise ValueError('unsupported/empty timeline wait')
        keys = [self._object(context, r.u64(), device) for _ in range(count)]
        r.array(count, 16)
        values = [r.u64() for _ in range(count)]
        timeout = r.u64()
        r.end()
        token = tuple(words)
        saved = current.timeline_wait
        if saved is not None and saved[0] == token and saved[1] != tuple(keys):
            raise KeyError('timeline wait generation changed while suspended')
        ready = [self.values[key] >= value for key, value in zip(keys, values)]
        if any(ready) if flags & 1 else all(ready):
            current.timeline_wait = None
            return 0, []
        if any(key in self.jobs.failed for key, done in zip(keys, ready) if not done):
            current.timeline_wait = None
            return self.submissions.execution.golden.VK_ERR_LOST, []
        if not timeout:
            current.timeline_wait = None
            return 2, []
        if saved is None or saved[0] != token:
            current.timeline_wait = (token, tuple(keys), None if timeout == (1 << 64) - 1
                                     else self.submissions.clock() + timeout / 1e9)
        deadline = current.timeline_wait[2]
        if deadline is None or self.submissions.clock() < deadline:
            raise RingBlocked('timeline host wait has not completed or timed out')
        current.timeline_wait = None
        return 2, []

    def clean(self, context):
        kind = self.submissions.execution.golden.KIND['VkSemaphore']
        for key in tuple(self.values):
            if key[0] == id(context) and context.frontend.resolve(key[1], kind)[0] != 'OK':
                del self.values[key]
                self.jobs.failed.discard(key)

    def retire_context(self, context):
        self.jobs.discard(context)
        for key in tuple(self.values):
            if key[0] == id(context):
                del self.values[key]
