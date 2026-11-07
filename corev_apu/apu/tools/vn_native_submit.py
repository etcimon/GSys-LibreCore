#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Explicitly opt-in serialized transfer submission; no Vulkan capset admission."""
import time

from vn_rings import RingBlocked
from vn_binary_semaphores import BinarySemaphores
from vn_timeline_semaphores import TimelineSemaphores
from vn_query_replay import _stat_bits

VK_ERR_VALIDATION_FAILED = 0xC4650B08  # VK_ERROR_VALIDATION_FAILED


class WordReader:
    def __init__(self, words):
        self.words, self.position = words, 2

    def u32(self):
        if self.position >= len(self.words):
            raise ValueError('truncated native submit/wait packet')
        value = self.words[self.position]
        self.position += 1
        return value

    def u64(self):
        return self.u32() | self.u32() << 32

    def array(self, count, limit):
        if not 0 <= count <= limit or self.u64() != count:
            raise ValueError('native submit/wait array count mismatch or budget exceeded')

    def end(self):
        if self.position != len(self.words):
            raise ValueError('native submit/wait packet has trailing words')


def check_submission_modes(transfer, compute):
    if type(transfer) is not bool or type(compute) is not bool or compute and not transfer:
        raise ValueError('compute submission requires explicit transfer submission; modes must be bool')


class NativeSubmissions:
    NAMES = frozenset(('vkQueueSubmit', 'vkWaitForFences', 'vkResetFences',
                       'vkGetFenceStatus', 'vkDeviceWaitIdle', 'vkQueueWaitIdle',
                       'vkGetQueryPoolResults')) | TimelineSemaphores.NAMES
    # EVENT-class host commands bypass NAMES (the golden frontend owns
    # their state); _command reports DEVICE_LOST for them once the
    # owning context faults, matching the fence/query/timeline paths
    EVENT_NAMES = frozenset(('vkGetEventStatus', 'vkSetEvent',
                             'vkResetEvent'))
    # Device-state act classes whose VkResult replies report
    # DEVICE_LOST once the owning context faults: object creation,
    # memory/image binding, descriptor/command-pool resets and
    # command-buffer state transitions. RETIRE (void cleanup),
    # RECORD (void vkCmd*), QUERY (instance/device-independent),
    # MAP/UPDATE/NOP_OK and TRANSPORT stay live.
    LOST_CLASSES = frozenset(('ALLOC', 'BIND', 'POOL_RESET',
                              'CB_BEGIN', 'CB_END', 'CB_RESET'))

    def __init__(self, execution, enabled=False, clock=time.monotonic, *, compute_submit=False):
        check_submission_modes(enabled, compute_submit)
        self.execution, self.enabled, self.clock = execution, enabled, clock
        self.compute_enabled = compute_submit
        self.pending, self.faults = {}, set()
        self.semaphores = BinarySemaphores(self)
        self.timelines = TimelineSemaphores(self, WordReader)

    def _object(self, context, value, kind):
        status, slot, entry = context.frontend.resolve(
            value, self.execution.golden.KIND[kind])
        if status != 'OK' or entry['ctx'] != context.frontend.ctx:
            raise KeyError('native submission uses a stale ' + kind)
        return entry['gen'] << 16 | slot, entry

    def lost(self, current):
        # `current` may be a replace() view; faults keys the canonical
        # ExecutionContext, so resolve through the frontend ctx like step()
        context = self.execution.contexts[current.frontend.ctx]
        return id(context) in self.faults or context.gpu_lost

    def _fence(self, context, value):
        handle, entry = self._object(context, value, 'VkFence')
        if entry['aux'] & 255 >= context.frontend.FENCES:
            raise ValueError('native fence arena index exceeds bounds')
        return handle, entry

    def _query_results(self, context, words):
        """vkGetQueryPoolResults over ordered qslots state.

        Returns (VkResult, reply exec words).  The bounded profile admits
        64-bit occlusion/timestamp results only; WAIT blocks via
        RingBlocked until ordered query ops publish availability, matching
        fence waits.
        """
        golden = self.execution.golden
        reader = WordReader(words)
        device, _ = self._object(context, reader.u64(), 'VkDevice')
        _, entry = self._object(context, reader.u64(), 'VkQueryPool')
        first, count = reader.u32(), reader.u32()
        size, blob_count = reader.u64(), reader.u64()
        stride, flags = reader.u64(), reader.u32()
        reader.end()
        if entry['parent'] != device & 0xFFFF:
            raise ValueError('query results cross devices')
        if self.lost(context):
            return golden.VK_ERR_LOST, []
        pool_size, slots = entry.get('size'), entry.get('qslots')
        pool_type = entry['aux'] & 0xFF
        if (pool_type not in (0, 1, 2) or type(pool_size) is not int or
                not isinstance(slots, list) or len(slots) != pool_size):
            raise ValueError('query pool is outside the admitted profile')
        # VK_QUERY_RESULT_64_BIT is required (values are u64); WAIT and
        # WITH_AVAILABILITY are admitted, PARTIAL_BIT/unknown bits refuse
        if flags & ~0xB or not flags & 0x1:
            return golden.VK_ERR_FEATURE, []
        if blob_count != size:
            raise ValueError('query results blob count differs from dataSize')
        # statistics pools return an array of per-counter u64 values in
        # spec bit order per query; other types return one u64
        counters = (len(_stat_bits((entry['aux'] & 0xFFFFFFFF) >> 8))
                    if pool_type == 1 else 1)
        record_bytes = counters * 8 + (4 if flags & 0x8 else 0)
        packed = stride if stride else record_bytes
        if packed < record_bytes or packed % 4:
            return VK_ERR_VALIDATION_FAILED, []
        needed = count * packed
        if first + count > pool_size or size < needed:
            return VK_ERR_VALIDATION_FAILED, []
        unavailable = any(slots[first + i] is None for i in range(count))
        if unavailable and flags & 0x2:
            raise RingBlocked('query pool results are not yet available')
        out = [needed]
        for i in range(count):
            slot = slots[first + i]
            present = slot is not None
            if pool_type == 1:
                values = slot if present else [0] * counters
                for value in values:
                    out += [value & 0xFFFFFFFF, (value >> 32) & 0xFFFFFFFF]
            else:
                value = slot if present else 0
                out += [value & 0xFFFFFFFF, (value >> 32) & 0xFFFFFFFF]
            if flags & 0x8:
                out.append(1 if present else 0)
            out += [0] * ((packed - record_bytes) // 4)
        return (golden.VK_NOT_READY if unavailable
                else golden.VK_OK), out

    def _submit(self, context, words):
        reader = WordReader(words)
        queue, count = reader.u64(), reader.u32()
        reader.array(count, 4)
        buffers, wait_ids, signal_ids = [], [], []
        timeline_values = None
        stype = self.execution.model.stype_values['VK_STRUCTURE_TYPE_SUBMIT_INFO']
        for _ in range(count):
            if reader.u32() != stype:
                raise ValueError('invalid native submit info')
            chain = reader.u64()
            if chain:
                if (chain != 1 or count != 1 or
                        reader.u32() != self.execution.model.stype_values[
                            'VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO'] or
                        reader.u64()):
                    raise ValueError('native submit extension exceeds timeline profile')
                nv = reader.u32()
                reader.array(nv, 16)
                wait_values = [reader.u64() for _ in range(nv)]
                nv = reader.u32()
                reader.array(nv, 16)
                signal_values = [reader.u64() for _ in range(nv)]
                timeline_values = wait_values, signal_values
            waits = reader.u32()
            reader.array(waits, 16)
            wait_ids.extend(reader.u64() for _ in range(waits))
            reader.array(waits, 16)
            if any(not reader.u32() for _ in range(waits)):
                raise ValueError('native wait stage mask must be nonzero')
            n = reader.u32()
            reader.array(n, 16 - len(buffers))
            buffers.extend(reader.u64() for _ in range(n))
            signals = reader.u32()
            reader.array(signals, 16)
            signal_ids.extend(reader.u64() for _ in range(signals))
            if timeline_values is not None and (
                    len(timeline_values[0]) != waits or len(timeline_values[1]) != signals):
                raise ValueError('timeline value counts differ from semaphore counts')
        if count > 1 and (wait_ids or signal_ids):
            raise ValueError('multi-batch semaphore sequencing exceeds native profile')
        fence_id = reader.u64()
        reader.end()
        queue_handle, queue_entry = self._object(context, queue, 'VkQueue')
        for buffer in buffers:
            _, entry = self._object(context, buffer, 'VkCommandBuffer')
            parent = entry['parent']
            pool = context.frontend.ent[parent] if 0 <= parent < context.frontend.SLOTS else None
            if (pool is None or pool['kind'] != self.execution.golden.KIND['VkCommandPool'] or
                    pool['parent'] != queue_entry['parent']):
                raise ValueError('queue and command buffer belong to different devices')
        binary_ids, timeline_pairs = [[], []], [[], []]
        for role, ids in enumerate((wait_ids, signal_ids)):
            for index, value in enumerate(ids):
                handle, _ = self._object(context, value, 'VkSemaphore')
                if (id(context), handle) in self.timelines.values:
                    if timeline_values is None:
                        raise ValueError('timeline submission is missing value arrays')
                    timeline_pairs[role].append((value, timeline_values[role][index]))
                else:
                    binary_ids[role].append(value)
        binary = self.semaphores.plan(context, *binary_ids, queue_entry['parent'])
        timeline = self.timelines.jobs.plan(context, *timeline_pairs, queue_entry['parent'])
        fence = self._fence(context, fence_id) if fence_id else None
        if fence:
            handle, entry = fence
            if entry['parent'] != queue_entry['parent']:
                raise ValueError('queue and fence belong to different devices')
            key = id(context), handle
            if key in self.pending:
                raise RingBlocked('fence still belongs to an earlier submission')
            if context.frontend.fence_sig >> (entry['aux'] & 255) & 1:
                raise ValueError('submission fence must be reset before reuse')
        leases = ([(queue_handle, queue_entry)] + ([fence] if fence else []) +
                  binary.objects + timeline.objects)
        leases = list({handle: entry for handle, entry in leases}.items())
        acquired = []
        try:
            for handle, entry in leases:
                if entry['pins'] >= 255:
                    raise MemoryError('native queue/fence pin budget exhausted')
                if context.frontend.pin(handle) != 'OK':
                    raise KeyError('cannot pin native queue/fence')
                acquired.append(handle)
            try:
                job = (self.execution.replay.enqueue(context.frontend.ctx, buffers,
                                                     compute=self.compute_enabled)
                       if buffers else self.execution.transfers.enqueue(context, ()))
            except BlockingIOError as error:
                raise RingBlocked(str(error)) from error
        except BaseException:
            for handle in reversed(acquired):
                context.frontend.unpin(handle)
            raise
        def complete():
            live = (self.execution.contexts.get(context.frontend.ctx) is context and
                    not context.retired and not context.faulted)
            if live and job.state != 'done':
                context.gpu_lost = True
                self.faults.add(id(context))
            try:
                binary.finish(live and job.state == 'done')
                timeline.finish(live and job.state == 'done')
                if fence:
                    self.pending.pop((id(context), fence[0]), None)
                    if live:
                        bit = 1 << (fence[1]['aux'] & 255)
                        context.frontend.fence_sig |= bit
                        if job.state != 'done':
                            context.frontend.fence_lost |= bit
            finally:
                for handle in reversed(acquired):
                    context.frontend.unpin(handle)
                acquired.clear()
        job.complete = complete
        if fence:
            self.pending[(id(context), fence[0])] = job
        binary.commit()
        timeline.commit()
        job.lane = queue_entry.get('native_lane', queue_handle)
        job.prepare = lambda: timeline.ready() and binary.ready()

    def _fences(self, context, words, wait):
        reader = WordReader(words)
        device, _ = self._object(context, reader.u64(), 'VkDevice')
        count = reader.u32()
        reader.array(count, 16)
        if not count:
            raise ValueError('empty native fence wait/reset')
        fences = [self._fence(context, reader.u64()) for _ in range(count)]
        if any(entry['parent'] != (device & 0xFFFF) for _, entry in fences):
            raise ValueError('fence operation crosses devices')
        all_fences, timeout = (reader.u32(), reader.u64()) if wait else (0, 0)
        if all_fences not in (0, 1):
            raise ValueError('invalid waitAll')
        reader.end()
        return fences, all_fences, timeout

    def _idle(self, current, context, name, words):
        reader = WordReader(words)
        queue = name == 'vkQueueWaitIdle'
        handle, entry = self._object(context, reader.u64(), 'VkQueue' if queue else 'VkDevice')
        reader.end()
        lane = entry.get('native_lane', handle) if queue else None
        token, snapshot = (name, tuple(words)), (handle, lane)
        if (current.idle_wait is not None and current.idle_wait[0] == token and
                current.idle_wait[1] != snapshot):
            raise KeyError('idle wait generation/scope changed while suspended')
        current.idle_wait = token, snapshot
        if id(context) in self.faults:
            current.idle_wait = None
            return self.execution.golden.VK_ERR_LOST
        jobs = self.execution.transfers.queues.get(id(context), ())
        for job in jobs:
            # Internal jobs are context-wide ordering barriers. Native lanes
            # carry immutable (device, family, index), including queue aliases.
            if (job.lane is None or queue and job.lane == lane or
                    not queue and (not isinstance(job.lane, tuple) or job.lane[0] == handle)):
                raise RingBlocked('idle wait has owned work pending')
        current.idle_wait = None
        return self.execution.golden.VK_OK

    def blocked(self, current, name, record):
        if not self.enabled or name not in ('vkDestroyFence', 'vkDestroySemaphore'):
            return False
        context = self.execution.contexts[current.frontend.ctx]
        kind = 'VkFence' if name == 'vkDestroyFence' else 'VkSemaphore'
        for i in range(8):
            if record['qv'] >> i & 1 and record['kind'][i] == self.execution.golden.KIND[kind]:
                handle, entry = self._object(context, record['q'][i], kind)
                if ((id(context), handle) in self.pending or
                        kind == 'VkSemaphore' and entry['pins']):
                    return True
        return False

    def step(self, current, name, words, record):
        context = self.execution.contexts[current.frontend.ctx]
        golden, front = self.execution.golden, context.frontend
        result = golden.VK_OK
        extra = []
        if name in self.timelines.NAMES:
            result, extra = self.timelines.host(current, name, words)
        elif name == 'vkQueueSubmit':
            if id(context) in self.faults:
                result = golden.VK_ERR_LOST
            else:
                self._submit(context, words)
        elif name == 'vkGetFenceStatus':
            reader = WordReader(words)
            device, _ = self._object(context, reader.u64(), 'VkDevice')
            _, entry = self._fence(context, reader.u64())
            reader.end()
            if entry['parent'] != device & 0xFFFF:
                raise ValueError('fence status crosses devices')
            bit = 1 << (entry['aux'] & 255)
            result = (golden.VK_ERR_LOST if id(context) in self.faults or front.fence_lost & bit
                      else golden.VK_OK if front.fence_sig & bit else 1)
        elif name == 'vkGetQueryPoolResults':
            result, extra = self._query_results(context, words)
        elif name in ('vkWaitForFences', 'vkResetFences'):
            wait = name == 'vkWaitForFences'
            fences, all_fences, timeout = self._fences(context, words, wait)
            token, handles = tuple(words), tuple(handle for handle, _ in fences)
            if (wait and current.fence_wait is not None and
                    current.fence_wait[0] == token and current.fence_wait[1] != handles):
                raise KeyError('fence wait generation changed while suspended')
            mask = sum(1 << (entry['aux'] & 255) for _, entry in
                       {handle: entry for handle, entry in fences}.items())
            if not wait:
                if any((id(context), handle) in self.pending for handle, _ in fences):
                    raise RingBlocked('cannot reset an executor-owned fence')
                front.fence_sig &= ~mask
                front.fence_lost &= ~mask
            elif id(context) in self.faults or front.fence_lost & mask:
                current.fence_wait = None
                result = golden.VK_ERR_LOST
            elif ((front.fence_sig & mask) == mask if all_fences else front.fence_sig & mask):
                result = golden.VK_OK
            elif not timeout:
                result = 2  # VK_TIMEOUT, not VK_NOT_READY.
            else:
                if current.fence_wait is None or current.fence_wait[0] != token:
                    current.fence_wait = (token, handles, None if timeout == (1 << 64) - 1
                                          else self.clock() + timeout / 1e9)
                deadline = current.fence_wait[2]
                if deadline is None or self.clock() < deadline:
                    raise RingBlocked('fence wait has not reached retirement or timeout')
                result = 2
            current.fence_wait = None
        else:
            result = self._idle(current, context, name, words)
        out = {'result': result, 'null_mask': set(), 'rep': [], 'fault': 0}
        front._reply(out, words, record, self.execution.reply_decoder,
                     self.execution.model.cmd_info[name], extra)
        return out

    def after_command(self, current, name, record, out, creation=None):
        if (self.enabled and name in ('vkGetDeviceQueue', 'vkGetDeviceQueue2') and
                out['result'] == self.execution.golden.VK_OK):
            context = self.execution.contexts[current.frontend.ctx]
            for i in range(8):
                if record['qv'] >> i & 1 and record['role'][i] == 1:
                    _, entry = self._object(context, record['q'][i], 'VkQueue')
                    parent = context.frontend.ent[entry['parent']]
                    device = parent['gen'] << 16 | entry['parent']
                    first = int(name.endswith('2'))
                    entry['native_lane'] = (device, *record['imm'][first:first + 2])
        if (self.enabled and name == 'vkCreateSemaphore' and
                out['result'] == self.execution.golden.VK_OK):
            context = self.execution.contexts[current.frontend.ctx]
            for i in range(8):
                if record['qv'] >> i & 1 and record['role'][i] == 1:
                    handle, _ = self._object(context, record['q'][i], 'VkSemaphore')
                    if creation is None:
                        raise ValueError('missing native semaphore creation type')
                    if creation[0]:
                        self.timelines.values[(id(context), handle)] = creation[1]
                    else:
                        self.semaphores.created.add((id(context), handle))
        if self.enabled and name == 'vkDestroySemaphore':
            self.semaphores.clean(self.execution.contexts[current.frontend.ctx])
            self.timelines.clean(self.execution.contexts[current.frontend.ctx])
        if not self.enabled or name != 'vkCreateFence' or out['result'] != self.execution.golden.VK_OK:
            return
        context = self.execution.contexts[current.frontend.ctx]
        for i in range(8):
            if record['qv'] >> i & 1 and record['role'][i] == 1:
                _, entry = self._fence(context, record['q'][i])
                if record['imm'][0] & 1:
                    context.frontend.fence_sig |= 1 << (entry['aux'] & 255)
                return

    def validate_command(self, name, words):
        if not self.enabled or name != 'vkCreateSemaphore':
            return
        return self.timelines.creation(words)

    def retire_context(self, context):
        self.faults.discard(id(context))
        self.semaphores.retire_context(context)
        self.timelines.retire_context(context)
