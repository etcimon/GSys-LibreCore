#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded internal command-buffer replay; not wire GPU/profile admission."""
from vn_transfer_executor import Transfer
from vn_image_replay import ImageReplay
from vn_image_barriers import replay as replay_image_barrier
from vn_event_replay import replay as replay_event
from vn_query_replay import replay as replay_query
from vn_conditional_replay import replay as replay_conditional
from vn_compute_replay import ComputeReplay
from vn_render_pass_replay import replay as replay_render_pass
from vn_graphics_dynamic import Recording
from vn_graphics_draws import GraphicsDraws
from vn_graphics_draw_replay import operation as draw_operation


class TransferReplay:
    def __init__(self, execution):
        self.execution = execution
        self.held = {}

    def enqueue(self, context_id, command_buffers, *, compute=False):
        if type(compute) is not bool:
            raise ValueError('compute replay admission must be explicit')
        engine, objects, buffers, operations = self.execution, {}, {}, []
        guards, dispatch_budget = [], [16]
        context = engine.contexts[context_id]
        if not engine.transfers._live(context):
            raise KeyError('replay context is unavailable')
        if (not isinstance(command_buffers, (tuple, list)) or
                not 0 < len(command_buffers) <= 16):
            raise ValueError('replay command-buffer count exceeds profile')
        front, golden = context.frontend, engine.golden
        remaining, payload_bytes = engine.max_commands, engine.max_bytes

        def remember(handle, kind, *, allow_zomb=False):
            status, slot, entry = front.resolve(handle, kind, allow_zomb=allow_zomb)
            if status != 'OK' or entry['ctx'] != context_id:
                raise KeyError('replay object is stale or belongs to another context')
            handle = entry['gen'] << 16 | slot
            result = (handle, entry)
            seen = set()
            for _ in range(front.SLOTS):
                if handle in seen:
                    raise ValueError('replay parent cycle')
                seen.add(handle)
                if handle in objects:
                    return result
                objects[handle] = entry
                parent = entry['parent']
                if parent < 0:
                    return result
                entry = front.ent[parent] if parent < front.SLOTS else None
                if entry is None or entry['ctx'] != context_id:
                    raise KeyError('replay object has a dead parent')
                handle = entry['gen'] << 16 | parent
            raise ValueError('replay parent cycle')

        def charge(count):
            nonlocal payload_bytes
            if count < 0 or count > payload_bytes:
                raise MemoryError('replay payload/I/O byte budget exhausted')
            payload_bytes -= count

        def payload(record, count, offset=0):
            nonlocal payload_bytes
            base = record['imm'][7] + offset
            length = record.get('payload_words', -1)
            if (offset < 0 or offset > length or count > length - offset or
                    count < 0 or count * 4 > payload_bytes or base <= 0 or
                    base + count > front.pay_words):
                raise ValueError('replay payload budget/bounds exceeded')
            charge(count * 4)
            return [front.pay[base + i] for i in range(count)]

        def extent(record, index, kind='VkBuffer'):
            _, entry = remember(record['handle'][index], golden.KIND[kind])
            memory = entry['bind_mem']
            owner_entry = front.ent[memory] if 0 <= memory < front.SLOTS else None
            if (owner_entry is None or owner_entry['kind'] != golden.KIND['VkDeviceMemory'] or
                    owner_entry['gen'] != entry['bind_mgen']):
                raise KeyError('replay buffer memory binding is stale')
            owner = engine.memory(context_id, owner_entry['gen'] << 16 | memory)
            if owner.base is None:
                raise ValueError('replay buffer memory is unbacked')
            offset = entry['bind_off']
            if offset > owner_entry['size'] or entry['size'] > owner_entry['size'] - offset:
                raise ValueError('replay buffer binding exceeds allocation')
            return owner, offset, entry['size']

        def append(op):
            if len(operations) >= engine.transfers.max_operations:
                raise MemoryError('replay transfer-operation budget exhausted')
            operations.append(op)

        images = ImageReplay(engine, remember, payload, extent, operations)

        def replay(buffer, depth):
            nonlocal remaining
            handle, entry = remember(buffer, golden.KIND['VkCommandBuffer'])
            if handle in buffers:
                raise ValueError('repeated command buffers require a separate profile')
            if entry['state'] & golden.CB_PEND:
                raise BlockingIOError('command buffer already has pending work')
            descriptor = front.cbd.get(handle & 0xFFFF)
            if (entry['state'] & 0xF != golden.CB_EXEC or descriptor is None or
                    descriptor['addr'] != entry['aux'] >> 32 or
                    descriptor['count'] != len(descriptor['recs']) or
                    not descriptor['flags'] >> golden.CBF_SEALED & 1 or
                    bool(descriptor['flags'] >> golden.CBF_SECONDARY & 1) != bool(depth) or
                    descriptor['flags'] & ((1 << golden.CBF_SIMULT) |
                                           (1 << golden.CBF_RPCONT))):
                raise ValueError('command buffer is not executable in the transfer profile')
            _, pool = remember(descriptor['pool'], golden.KIND['VkCommandPool'])
            shader = None
            if compute:
                parent = pool['parent']
                device = front.ent[parent] if 0 <= parent < front.SLOTS else None
                if device is None or device['kind'] != golden.KIND['VkDevice']:
                    raise KeyError('compute command pool has no live device')
                shader = ComputeReplay(engine, context, device['gen'] << 16 | parent,
                                       remember, payload, append, charge, guards, dispatch_budget, extent)
            buffers[handle] = (entry['state'], descriptor['flags'] >> golden.CBF_OTIME & 1)
            records = descriptor['recs']
            parent = pool['parent']
            device_entry = front.ent[parent] if 0 <= parent < front.SLOTS else None
            draws = GraphicsDraws(engine, context_id, Recording(
                context, (device_entry['gen'] << 16 | parent)
                if device_entry is not None else 0, handle, records))
            if len(records) > remaining:
                raise MemoryError('replay record budget exhausted')
            for record in records:
                remaining -= 1
                if remaining < 0:
                    raise MemoryError('replay expanded record budget exhausted')
                name = engine.names[record['ctype']]
                plans = len(draws.plans)
                handled = draws.replay(name, record)
                if len(draws.plans) > plans:
                    op = draw_operation(engine, context_id, draws.plans[-1],
                                        remember, guards)
                    if op is not None:
                        append(op)
                if handled and name not in ('vkCmdBeginRenderPass',
                                            'vkCmdEndRenderPass',
                                            'vkCmdClearAttachments',
                                            'vkCmdNextSubpass'):
                    continue
                if shader is not None and name in shader.NAMES:
                    shader.replay(name, record)
                elif name in images.NAMES:
                    images.replay(name, record)
                elif name == 'vkCmdExecuteCommands':
                    if depth or not 0 < record['imm'][0] <= 16:
                        raise ValueError('secondary replay depth/count exceeds profile')
                    for child in payload(record, record['imm'][0]):
                        replay(child, depth + 1)
                    if shader is not None:
                        shader.reset()
                elif name in ('vkCmdBeginRenderPass', 'vkCmdEndRenderPass',
                              'vkCmdClearAttachments', 'vkCmdNextSubpass'):
                    replay_render_pass(engine, context_id, name, record,
                                       remember, append, guards)
                elif name == 'vkCmdPipelineBarrier':
                    replay_image_barrier(images, record, compute=compute, device=pool['parent'])
                elif name in ('vkCmdSetEvent', 'vkCmdResetEvent', 'vkCmdWaitEvents'):
                    replay_event(images, record, name, compute=compute,
                                 device=pool['parent'])
                elif name in ('vkCmdBeginConditionalRenderingEXT',
                              'vkCmdEndConditionalRenderingEXT'):
                    replay_conditional(images, record, name,
                                       device=pool['parent'])
                elif name in ('vkCmdResetQueryPool', 'vkCmdBeginQuery',
                              'vkCmdEndQuery', 'vkCmdWriteTimestamp',
                              'vkCmdWriteTimestamp2',
                              'vkCmdCopyQueryPoolResults',
                              'vkCmdBeginQueryIndexedEXT',
                              'vkCmdEndQueryIndexedEXT'):
                    replay_query(images, record, name, compute=compute,
                                 device=pool['parent'])
                elif name in ('vkCmdFillBuffer', 'vkCmdUpdateBuffer'):
                    header = payload(record, 4)
                    offset, size = header[0] | header[1] << 32, header[2] | header[3] << 32
                    owner, binding, capacity = extent(record, 0)
                    if name == 'vkCmdFillBuffer' and size == (1 << 64) - 1:
                        size = max(0, capacity - offset) & ~3
                    if offset % 4 or offset > capacity or size > capacity - offset:
                        raise ValueError('replay transfer exceeds buffer extent')
                    if name == 'vkCmdFillBuffer':
                        append(Transfer('fill', owner, binding + offset, size,
                                        data=record['imm'][0].to_bytes(4, 'little')))
                    else:
                        if not 0 < size <= 65536 or size % 4:
                            raise ValueError('replay update size is invalid')
                        data = payload(record, size // 4, 4)
                        append(Transfer('update', owner, binding + offset, size,
                                        data=b''.join(w.to_bytes(4, 'little') for w in data)))
                elif name == 'vkCmdCopyBuffer':
                    count = record['imm'][0]
                    if not 0 < count <= engine.transfers.max_operations - len(operations):
                        raise MemoryError('replay copy-region budget exhausted')
                    data = payload(record, count * 6)
                    source, source_binding, source_size = extent(record, 0)
                    destination, dest_binding, dest_size = extent(record, 1)
                    ranges = []
                    for i in range(count):
                        values = [data[6 * i + j] | data[6 * i + j + 1] << 32
                                  for j in (0, 2, 4)]
                        start, target, size = values
                        if (not size or start > source_size or size > source_size - start or
                                target > dest_size or size > dest_size - target):
                            raise ValueError('replay copy region exceeds buffer extent')
                        ranges.append((source.base + source_binding + start,
                                       destination.base + dest_binding + target, size))
                        append(Transfer('copy', destination, dest_binding + target, size,
                                        source, source_binding + start))
                    if any(s < d + dn and d < s + sn
                           for s, _, sn in ranges for _, d, dn in ranges):
                        raise ValueError('replay copy regions overlap across source/destination')
                else:
                    raise ValueError('unsupported replay command: ' + name)

        for buffer in command_buffers:
            replay(buffer, 0)
        if images.qopen:
            raise ValueError('occlusion query left active at submit end')
        if images.cond is not None:
            raise ValueError('conditional rendering left open at submit end')
        acquired = []

        def release(committed):
            error = None
            for handle in reversed(acquired):
                key = (id(context), handle)
                try:
                    self.held[key] -= 1
                    if not self.held[key]:
                        del self.held[key]
                        if handle in buffers:
                            old, once = buffers[handle]
                            objects[handle]['state'] = (
                                (old & ~0xF) | golden.CB_INV if committed and once else old)
                    status, _ = front.unpin(handle)
                    if status != 'OK':
                        raise KeyError('replay object lease became stale')
                except (KeyError, ValueError) as failure:
                    error = failure
            acquired.clear()
            if error is not None:
                raise error

        try:
            for guard in guards:
                guard()
            if not engine.transfers._live(context):
                raise KeyError('replay context retired during admission')
            for handle, entry in objects.items():
                if entry['pins'] >= 255:
                    raise MemoryError('replay object pin budget exhausted')
                if front.pin(handle) != 'OK':
                    raise KeyError('replay object pin failed')
                acquired.append(handle)
                key = (id(context), handle)
                self.held[key] = self.held.get(key, 0) + 1
            for handle in buffers:
                objects[handle]['state'] = (
                    objects[handle]['state'] & ~0xF) | golden.CB_PEND
            for guard in guards:
                guard()
            job = engine.transfers.enqueue(context, operations)
            job.retire = lambda: release(True)
            return job
        except BaseException:
            release(False)
            raise

    def blocked(self, current, name, record):
        context = self.execution.contexts[current.frontend.ctx]
        if name in ('vkDeviceWaitIdle', 'vkQueueWaitIdle'):
            return (not self.execution.submissions.enabled and
                    id(context) in self.execution.transfers.queues)
        if not self.held:
            return False
        kinds = self.execution.golden.KIND
        targets = set()
        action = self.execution.model.cmd_info[name]['act']['class']
        if action in ('CB_BEGIN', 'CB_END', 'CB_RESET', 'RECORD'):
            targets.add(kinds['VkCommandBuffer'])
        if name in ('vkResetCommandPool', 'vkDestroyCommandPool'):
            targets.add(kinds['VkCommandPool'])
        if name in ('vkBindBufferMemory', 'vkDestroyBuffer'):
            targets.add(kinds['VkBuffer'])
        if name in ('vkBindImageMemory', 'vkDestroyImage'):
            targets.add(kinds['VkImage'])
        if name == 'vkDestroyImageView':
            targets.add(kinds['VkImageView'])
        if name == 'vkDestroyEvent':
            targets.add(kinds['VkEvent'])
        if name == 'vkDestroyQueryPool':
            targets.add(kinds['VkQueryPool'])
        if name == 'vkDestroySampler':
            targets.add(kinds['VkSampler'])
        if name == 'vkDestroyPipeline':
            targets.add(kinds['VkPipeline'])
        if name in ('vkResetDescriptorPool', 'vkDestroyDescriptorPool'):
            targets.add(kinds['VkDescriptorPool'])
        if name in ('vkUpdateDescriptorSets', 'vkFreeDescriptorSets',
                    'vkUpdateDescriptorSetWithTemplate', 'vkUpdateDescriptorSetWithTemplateKHR'):
            return any(key[0] == id(context) and
                       current.frontend.ent[key[1] & 0xFFFF]['kind'] == kinds['VkDescriptorSet']
                       for key in self.held)
        if name == 'vkDestroyDevice':
            targets.add(kinds['VkDevice'])
        if name in ('vkFreeCommandBuffers', 'vkBindBufferMemory2', 'vkBindImageMemory2'):
            return any(key[0] == id(context) for key in self.held)
        for i in range(8):
            if record['qv'] >> i & 1 and record['kind'][i] in targets:
                status, slot, entry = current.frontend.resolve(record['q'][i], record['kind'][i])
                if status == 'OK' and (id(context), entry['gen'] << 16 | slot) in self.held:
                    return True
        return False
