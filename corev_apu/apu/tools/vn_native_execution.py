#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded native Venus execution; transfer-only submission is explicitly opt-in."""
from contextlib import nullcontext
from dataclasses import dataclass, field, replace
from functools import lru_cache
import struct
import tomllib

from vn_ring_scheduler import RingScheduler
from vn_rings import RingBlocked
from vn_stream_task import StreamTask
from vn_transfer_executor import TransferExecutor
from vn_transfer_replay import TransferReplay
from vn_native_submit import NativeSubmissions, check_submission_modes
from vn_image_barriers import FIELDS as BARRIER_FIELDS, capture as capture_barrier
from vn_native_layouts import capture as capture_layout, attach as attach_layout
from vn_native_pipelines import capture as capture_pipeline, attach as attach_pipeline
from vn_native_rendering import capture as capture_rendering, attach as attach_rendering
from vn_graphics_pipelines import capture as capture_graphics, attach as attach_graphics
from vn_vertex_operands import capture as capture_vertex, attach as attach_vertex
from vn_graphics_dynamic import capture as capture_dynamic, attach as attach_dynamic
from vn_render_pass_commands import capture as capture_pass, attach as attach_pass


class StreamFault(ValueError):
    pass


class MemoryWords:
    """Uncached word view: guest writes must not disappear behind a shadow dict."""

    def __init__(self, memory):
        self.memory = memory

    def __getitem__(self, index):
        if type(index) is not int or index < 0:
            raise ValueError('invalid device word address')
        return int.from_bytes(self.memory.read(index * 4, 4), 'little')

    def __setitem__(self, index, value):
        if type(index) is not int or index < 0:
            raise ValueError('invalid device word address')
        self.memory.write(index * 4, (value & 0xFFFFFFFF).to_bytes(4, 'little'))

    def get(self, index, default=0):
        return self[index]

    def pop(self, index, default=None):
        value = self[index]
        self[index] = 0
        return value


TIMELINE_COMMANDS = ('vkGetSemaphoreCounterValue', 'vkSignalSemaphore', 'vkWaitSemaphores')


@lru_cache(maxsize=2)
def load_decoder(native_timeline=False):
    # Lazy: control-only startup/presence checks do not parse XML or need Mako.
    import vn_golden as golden
    generator = golden.G
    profile = tomllib.loads((generator.TOOLS / 'vn_device_profile.toml').read_text())
    if native_timeline:
        profile['chain_structs'] = [*profile.get('chain_structs', ()),
                                    'VkSemaphoreTypeCreateInfo',
                                    'VkTimelineSemaphoreSubmitInfo']
        profile.setdefault('keep', {})['vkCmdPipelineBarrier'] = {
            'fields': list(BARRIER_FIELDS)}
        wait = profile.setdefault('keep', {}).setdefault(
            'vkCmdWaitEvents', {'fields': []})
        wait['fields'] = list(dict.fromkeys(
            list(wait.get('fields', ())) + list(BARRIER_FIELDS)))
        profile.setdefault('keep', {})['vkCmdBeginConditionalRenderingEXT'] = {
            'fields': ['buffer', 'offset', 'flags']}
    model = generator.Model(profile)
    names = model.read_command_set(generator.TOOLS / 'vn_command_set.txt')
    if native_timeline:
        names.extend(TIMELINE_COMMANDS)
    if model.run(names):
        raise RuntimeError('native decoder profile contains unfit commands')
    model, assembly = golden.build_assembly(model)
    for ty in model.reg.type_table.values():
        if ty.category == golden.vkxml.VkType.HANDLE:
            golden.KIND[ty.name] = model.kind(ty.name)
    return golden, model, assembly


@dataclass
class ExecutionContext:
    frontend: object
    reply: object = None
    faulted: bool = False
    gpu_lost: bool = False
    retired: bool = False
    owners: dict = field(default_factory=dict)
    active_ring: object = None
    vq_seqno: int = 0
    reply_version: int = 0
    fence_wait: object = None
    timeline_wait: object = None
    idle_wait: object = None


class LinearExecution:
    """Per-context decode/execute/reply with shared device aperture ownership.

    No frame/command is allowed to mint a memory grant. Decoding and execution
    reuse the existing reference model, not a new firmware renderer. Transfer-only
    queue submission is explicitly opt-in; compute needs a separate diagnostic
    opt-in. No Vulkan capset is admitted.
    """

    def __init__(self, state, blobs, *, max_bytes=65536, max_commands=256,
                 transfer_submit=False, compute_submit=False):
        check_submission_modes(transfer_submit, compute_submit)
        if (type(max_bytes) is not int or max_bytes <= 0 or max_bytes % 4 or
                type(max_commands) is not int or max_commands <= 0):
            raise ValueError('invalid linear execution budgets')
        self.state, self.blobs = state, blobs
        self.max_bytes, self.max_commands = max_bytes, max_commands
        self.golden, self.model, self.assembly = load_decoder(transfer_submit)
        self.decoder = self.golden.Sim(self.model, self.assembly)
        self.reply_decoder = self.golden.ReplySim(self.model, self.assembly)
        self.names = {info['type_id']: name for name, info in self.model.cmd_info.items()}
        self.session = {'T': {name: info['type_id']
                              for name, info in self.model.cmd_info.items()}}
        self.contexts = {}
        self.state.ap = MemoryWords(state.aperture)
        self.rings = RingScheduler(self)
        self.tasks = {}
        self.transfers = TransferExecutor(self)
        self.replay = TransferReplay(self)
        self.submissions = NativeSubmissions(self, transfer_submit, compute_submit=compute_submit)

    def _context(self, context):
        current = self.contexts.get(context)
        if current is None:
            frontend = self.golden.FrontModel(self.model, self.assembly)
            frontend.ap, frontend.ctx = self.state, context
            frontend.descriptor_sources = {}
            current = self.contexts[context] = ExecutionContext(frontend)
        return current

    def execute(self, context, data):
        current = self._context(context)
        if current.faulted or current.retired:
            raise StreamFault('context stream is faulted or retired')
        try:
            task = self.start_view(replace(current, owners=current.owners), data)
            task.advance([self.max_commands, self.max_bytes], quantum=self.max_commands)
            return task.size if task.state == 'done' else task
        except (ValueError, KeyError, OSError, MemoryError) as error:
            # Earlier commands may have completed; never continue a partially
            # failed stream or silently replay it against changed state.
            current.faulted = True
            self.cancel_tasks(current)
            self.rings.retire_context(current)
            self.transfers.cancel_context(current)
            if type(error) is ValueError:
                raise StreamFault(str(error)) from error
            raise

    def start_view(self, current, data):
        if len(self.tasks) >= 128:
            raise MemoryError('native continuation budget exhausted')
        if len(data) % 4 or len(data) > self.max_bytes:
            raise StreamFault('command stream exceeds byte/alignment bounds')
        parent = self.contexts[current.frontend.ctx]
        if parent.frontend is not current.frontend or parent.retired or parent.faulted:
            raise StreamFault('continuation view belongs to an unavailable context')
        task = StreamTask(self, current, parent, data)
        self.tasks[id(task)] = task
        return task

    def _command(self, current, name, command, record, budget, depth):
        info = self.model.cmd_info[name]
        action = info['act']['class']
        if (self.replay.blocked(current, name, record) or
                self.submissions.blocked(current, name, record)):
            raise RingBlocked('command waits for executor-owned object retirement')
        if action == 'TRANSPORT':
            self._transport(current, name, command, record, budget, depth)
            return
        if (action in ('UNSUPPORTED', 'SUBMIT') and
                not (self.submissions.enabled and name in self.submissions.NAMES)):
            raise StreamFault('GPU work submission is not budgeted/supported')
        creation = self.submissions.validate_command(name, command)
        layout = capture_layout(self, current, name, record)
        pipeline = capture_pipeline(self, current, name, command, record)
        rendering = capture_rendering(self, current, name, command, record)
        graphics = capture_graphics(self, current, name, command, record)
        vertex = capture_vertex(self, current, name, record)
        dynamic = capture_dynamic(self, current, name, record)
        render_pass = capture_pass(self, current, name, command, record)
        if self.submissions.enabled and name == 'vkCmdPipelineBarrier':
            capture_barrier(self, current.frontend, record)
        elif self.submissions.enabled and name == 'vkCmdWaitEvents':
            # retained payload leads with 2 words per event id; the
            # barrier structs follow verbatim after capture canonicalizes
            # their embedded buffer/image handles
            capture_barrier(self, current.frontend, record,
                            2 * (record['imm'][0] & 0xFFFF))
        if self._defer_memory_free(current, name, command, record):
            return
        wants_reply = record['flags'] & 1 and info['reply_id'] and info['act']['flags'] & 1
        if wants_reply and current.reply is None:
            raise StreamFault('reply requested without a reply stream')
        mapping = current.reply[0] if wants_reply else None
        with self.blobs.pin(mapping) if mapping is not None else nullcontext():
            if (self.submissions.enabled and
                    (name in self.submissions.EVENT_NAMES or
                     action in self.submissions.LOST_CLASSES) and
                    self.submissions.lost(current)):
                # DEVICE_LOST for host feedback and device-state
                # commands once the owning context faults; object
                # creation/binding and command-buffer state transitions
                # are skipped so no stale object is published
                out = {'result': self.golden.VK_ERR_LOST, 'null_mask': set(),
                       'rep': [], 'fault': 0}
                current.frontend._reply(out, command, record,
                                        self.reply_decoder,
                                        self.model.cmd_info[name], [])
            elif self.submissions.enabled and name in self.submissions.NAMES:
                out = self.submissions.step(current, name, command, record)
            else:
                try:
                    allocation = pipeline or graphics
                    allocation_record = dict(record, pay=list(allocation[2])) if allocation else record
                    out = current.frontend.step(name, None, command, allocation_record,
                                                self.reply_decoder, self.session)
                except NotImplementedError as error:
                    raise StreamFault('unsupported native frontend semantics: ' + str(error)) from error
                attach_layout(current.frontend, name, record, out, layout)
                attach_pipeline(self, current, out, pipeline)
                attach_rendering(current.frontend, name, record, out, rendering)
                attach_graphics(self, current, out, graphics)
                attach_vertex(out, vertex)
                attach_dynamic(out, dynamic)
                attach_pass(out, render_pass)
                self.submissions.after_command(current, name, record, out, creation)
            if out['fault']:
                raise StreamFault('front execution fault')
            if out['rep']:
                self._reply(current, out['rep'])

    def _reply(self, current, words):
        if current.reply is None:
            raise StreamFault('reply stream is absent')
        mapping, offset, size, position = current.reply
        data = struct.pack('<%dI' % len(words), *words)
        if len(data) > size - position:
            raise StreamFault('reply stream overflow')
        self.blobs.write(mapping, offset + position, data)
        current.reply = (mapping, offset, size, position + len(data))

    def _transport(self, current, name, words, record, budget, depth):
        def u64(index):
            return words[index] | words[index + 1] << 32

        if name == 'vkSetReplyCommandStreamMESA':
            mapping = self.blobs.mapping(words[4])
            offset, size = u64(5), u64(7)
            self.blobs._live(mapping, offset, size)
            if offset % 4 or size % 4:
                raise StreamFault('unaligned reply stream')
            current.reply = (mapping, offset, size, 0)
        elif name == 'vkSeekReplyCommandStreamMESA':
            position = u64(2)
            if current.reply is None or position % 4 or position > current.reply[2]:
                raise StreamFault('invalid reply position')
            current.reply = (*current.reply[:3], position)
        elif name == 'vkImportSemaphoreResourceMESA':
            # 0:type 1:flags 2-3:device 4-5:presence64 6:sType
            # 7..: pNext chain, then semaphore u64 + resourceId u32
            # always close the command (they follow the chain on wire).
            sem, rid = u64(len(words) - 3), words[-1]
            if sem == 0:
                raise StreamFault('null semaphore resource import')
            try:
                self.blobs.mapping(rid)
            except (KeyError, ValueError) as error:
                raise StreamFault(
                    'semaphore resource is absent or unmapped') from error
            self.rings.sem_res[sem] = rid
        elif name == 'vkWaitSemaphoreResourceMESA':
            # 0:type 1:flags 2-3:device 4-5:semaphore
            rid = self.rings.sem_res.get(u64(4))
            if rid is None:
                raise StreamFault('semaphore resource was never imported')
            # pending work through the bound resource: any live ring
            # created on this blob resource still holding unconsumed
            # submissions ([head,tail) non-empty) or already fatal.
            for ring in self.rings.rings.values():
                if ring.mapping.resource != rid:
                    continue
                if (ring.fatal or
                        self.rings.read32(ring, ring.tail_offset) > ring.head):
                    raise RingBlocked()
        elif name in ('vkCreateRingMESA', 'vkDestroyRingMESA', 'vkNotifyRingMESA',
                      'vkWriteRingExtraMESA', 'vkWaitRingSeqnoMESA',
                      'vkSubmitVirtqueueSeqnoMESA', 'vkWaitVirtqueueSeqnoMESA'):
            self.rings.command(current, name, words, record, depth)
        else:
            raise StreamFault('transport operation not implemented')

    def retire_context(self, context):
        current = self.contexts.pop(context, None)
        if current is not None:
            current.retired = True
            self.cancel_tasks(current)
            self.rings.retire_context(current)
            self.transfers.cancel_context(current)
            self.submissions.retire_context(current)
            current.frontend.reset_ctx(context)

    def cancel_tasks(self, context):
        for task in tuple(self.tasks.values()):
            if task.parent is context:
                task.cancel()

    def publish_reply_cursor(self, task):
        parent = task.parent
        if (task.current.active_ring is None and task.current.reply != task.initial_reply and
                parent.reply_version == task.reply_version and task.live()):
            parent.reply = task.current.reply
            parent.reply_version += 1

    def memory(self, context, memory_id):
        from vn_borrowed_memory import MemoryOwner
        current = self.contexts[context]
        if current.faulted or current.retired:
            raise KeyError('memory context is unavailable')
        status, slot, entry = current.frontend.resolve(
            memory_id, self.golden.KIND['VkDeviceMemory'])
        if status != 'OK':
            raise KeyError('unknown device memory')
        handle = entry['gen'] << 16 | slot
        owner = current.owners.get(handle)
        if owner is None:
            owner = current.owners[handle] = MemoryOwner(self, current, handle, entry)
        if owner.deferred_free is not None:
            raise KeyError('memory ID has been freed')
        return owner

    def _defer_memory_free(self, current, name, words, record):
        if name != 'vkFreeMemory':
            return False
        target = next((record['q'][i] for i in range(8)
                       if record['qv'] >> i & 1 and record['role'][i] == 2), 0)
        if not target:
            return False
        owner = self.memory(current.frontend.ctx, target)
        if not (owner.refs or owner.work_refs):
            return False
        if owner.deferred_free is not None:
            raise StreamFault('memory was already freed')
        owner.deferred_free = lambda: current.frontend.step(
            name, None, words, record, self.reply_decoder, self.session)
        return True

    def reset(self):
        for context in tuple(self.contexts):
            self.retire_context(context)


class ExecutionService:
    """Keep XML/profile initialization out of ordinary control-only startup."""

    def __init__(self, state, blobs, *, transfer_submit=False, compute_submit=False):
        check_submission_modes(transfer_submit, compute_submit)
        self.state, self.blobs, self.engine = state, blobs, None
        self.transfer_submit = transfer_submit
        self.compute_submit = compute_submit

    def execute(self, context, data):
        if self.engine is None:
            self.engine = LinearExecution(self.state, self.blobs,
                                          transfer_submit=self.transfer_submit,
                                          compute_submit=self.compute_submit)
        return self.engine.execute(context, data)

    def memory(self, context, memory_id):
        if self.engine is None:
            raise KeyError('device memory has not been allocated')
        return self.engine.memory(context, memory_id)

    @property
    def active(self):
        return (self.engine is not None and
                (self.engine.rings.active or self.engine.transfers.active))

    def poll(self):
        if self.engine is None:
            return 0
        return self.engine.transfers.poll() + self.engine.rings.poll()

    def prepare_reset(self):
        if self.engine is not None:
            self.engine.rings.prepare_reset()

    def retire_context(self, context):
        if self.engine is not None:
            self.engine.retire_context(context)

    def reset(self):
        if self.engine is not None:
            self.engine.reset()
