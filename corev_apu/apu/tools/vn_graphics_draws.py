# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Nonexecuting per-draw state plans; no fetch, raster, leases or capset admission."""
from dataclasses import dataclass

from vn_graphics_bindings import GraphicsBindings
from vn_graphics_dynamic import DynamicCommand, Recording, validate as dynamic_values
from vn_graphics_dynamic import validate_recording
from vn_native_rendering import framebuffer_operand
from vn_render_pass_commands import BeginPass, EndPass, NextPass
from vn_vertex_operands import BufferBindings, BufferSource, operand as buffer_span


@dataclass(frozen=True)
class VertexFetch:
    location: int
    binding: int
    format: int
    offset: int
    stride: int
    rate: int
    span: object


@dataclass(frozen=True)
class DrawPlan(Recording):
    ordinal: int
    command: str
    values: tuple
    indirect: object
    pipeline: object
    stage_bindings: object
    pass_state: object
    subpass: int
    attachments: tuple
    framebuffer: object
    viewport: tuple
    scissor: tuple
    vertices: tuple
    indices: object
    references: tuple
    validate: object


class GraphicsDraws:
    DRAWS = frozenset(('vkCmdDraw', 'vkCmdDrawIndexed',
                        'vkCmdDrawIndirect', 'vkCmdDrawIndexedIndirect'))

    def __init__(self, engine, context_id, recording):
        validate_recording(engine, context_id, recording)
        self.engine, self.context_id, self.recording = engine, context_id, recording
        self.context = engine.contexts[context_id]
        self.front, self.kinds = self.context.frontend, engine.golden.KIND
        self.device = recording.device
        self.bindings = GraphicsBindings(engine, context_id, recording)
        self.viewport = self.scissor = None
        self.vertices, self.index_source = {}, None
        self.pass_state = None
        self.subpass = 0
        self.plans = []
        self.position = 0

    def replay(self, name, record):
        validate_recording(self.engine, self.context_id, self.recording)
        records = self.recording.recording
        if self.position >= len(records) or records[self.position] is not record:
            raise ValueError('graphics draw records must be consumed in recording order')
        handled = self.bindings.replay(name, record)
        if not handled:
            handled = self._state(name, record)
        self.position += 1
        return handled

    def _state(self, name, record):
        if name in ('vkCmdSetViewport', 'vkCmdSetScissor'):
            return self._dynamic(name, record)
        if name == 'vkCmdBindVertexBuffers':
            return self._vertex_bindings(record)
        if name == 'vkCmdBindIndexBuffer':
            return self._index_binding(record)
        if name == 'vkCmdBeginRenderPass':
            self._begin(record)
            return True
        if name == 'vkCmdEndRenderPass':
            self._end(record)
            return True
        if name == 'vkCmdNextSubpass':
            self._next(record)
            return True
        if name in self.DRAWS:
            self._draw(name, record)
            return True
        return False

    def _dynamic(self, name, record):
        snapshot = record.get('native_graphics_dynamic')
        kind = 'viewport' if name == 'vkCmdSetViewport' else 'scissor'
        if not isinstance(snapshot, DynamicCommand) or snapshot.kind != kind:
            raise KeyError('graphics draw dynamic snapshot is unavailable')
        values = dynamic_values(self.engine, self.context_id, snapshot)
        if kind == 'viewport':
            self.viewport = values
        else:
            self.scissor = values
        return True

    def _vertex_bindings(self, record):
        snapshot = record.get('native_graphics_buffers')
        if (not isinstance(snapshot, BufferBindings) or not snapshot.sources or
                any(source.index_bytes for source in snapshot.sources)):
            raise KeyError('graphics draw vertex binding snapshot is unavailable')
        for index, source in enumerate(snapshot.sources):
            self.vertices[snapshot.first + index] = source
        return True

    def _index_binding(self, record):
        snapshot = record.get('native_graphics_buffers')
        if (not isinstance(snapshot, BufferBindings) or len(snapshot.sources) != 1 or
                snapshot.sources[0].index_bytes not in (2, 4)):
            raise KeyError('graphics draw index binding snapshot is unavailable')
        self.index_source = snapshot.sources[0]
        return True

    def _begin(self, record):
        snapshot = record.get('native_render_pass')
        if not isinstance(snapshot, BeginPass):
            raise KeyError('graphics draw render-pass begin snapshot is unavailable')
        if self.pass_state is not None:
            raise ValueError('graphics draw render pass is nested')
        self.pass_state = snapshot
        self.subpass = 0

    def _next(self, record):
        snapshot = record.get('native_render_pass')
        if (not isinstance(snapshot, NextPass) or self.pass_state is None or
                snapshot.begin is not self.pass_state or
                snapshot.subpass != self.subpass + 1):
            raise ValueError('graphics draw next subpass does not match active pass')
        self.subpass = snapshot.subpass

    def _end(self, record):
        snapshot = record.get('native_render_pass')
        if not isinstance(snapshot, EndPass) or snapshot.begin is not self.pass_state:
            raise ValueError('graphics draw render-pass end does not match begin')
        self.pass_state = None
        self.subpass = 0

    def _indirect(self, name, record):
        size = 20 if 'Indexed' in name else 16
        draw_count, stride = record['imm'][0], record['imm'][1]
        if draw_count == 0:
            return (), None
        offset = record['imm'][2] | record['imm'][3] << 32
        if (draw_count != 1 or stride != size or offset > 0xFFFFFFFF or
                offset % 4 or record['payload_words']):
            raise ValueError('graphics indirect draw exceeds single-record profile')
        buffer_raw = next((handle for handle, kind in zip(record['handle'], record['kind'])
                           if kind == self.kinds['VkBuffer'] and handle), None)
        if buffer_raw is None:
            raise KeyError('graphics indirect draw buffer operand is unavailable')
        status, slot, entry = self.front.resolve(buffer_raw, self.kinds['VkBuffer'])
        if status != 'OK' or entry['ctx'] != self.context_id:
            raise KeyError('graphics indirect buffer generation/context is stale')
        device_slot = entry['parent']
        device_entry = self.front.ent[device_slot]
        if (device_entry is None or device_entry['kind'] != self.kinds['VkDevice'] or
                device_entry['ctx'] != self.context_id or
                device_entry['gen'] << 16 | device_slot != self.device):
            raise ValueError('graphics indirect buffer belongs to another device')
        memory_slot = entry.get('bind_mem', -1)
        if not 0 <= memory_slot < self.front.SLOTS:
            raise KeyError('graphics indirect buffer has no memory binding')
        memory_handle = entry.get('bind_mgen', 0) << 16 | memory_slot
        status, _, memory = self.front.resolve(memory_handle, self.kinds['VkDeviceMemory'])
        if (status != 'OK' or memory['parent'] != device_slot or
                memory['kind'] != self.kinds['VkDeviceMemory']):
            raise KeyError('graphics indirect buffer memory is stale')
        usage = entry.get('native_usage', 0)
        if (not usage & 0x100 or offset >= entry['size'] or
                entry.get('bind_off', 0) + entry['size'] > memory['size']):
            raise ValueError('graphics indirect usage/range exceeds logical buffer')
        source = BufferSource(self.context, self.device, entry['gen'] << 16 | slot,
                              memory_handle, entry.get('bind_off', 0), entry['size'],
                              usage, offset, 0)
        return (draw_count, stride, offset), buffer_span(
            self.engine, self.context_id, source, size)

    def _draw(self, name, record):
        if 'Indirect' in name and record['imm'][0] == 0:
            return
        if self.pass_state is None:
            raise ValueError('graphics draw has no active render pass')
        if self.viewport is None or self.scissor is None:
            raise ValueError('graphics draw requires viewport and scissor state')
        operands = self.bindings.resolve()
        snapshot = operands.pipeline
        if not snapshot.render_pass.compatible(self.pass_state.render_pass_state):
            raise ValueError('graphics draw pipeline/render pass is incompatible')
        if snapshot.subpass != self.subpass:
            raise ValueError('graphics draw pipeline subpass differs from active subpass')
        indexed = 'Indexed' in name
        indirect = 'Indirect' in name
        strides = {binding: (stride, rate) for binding, stride, rate in snapshot.fixed.bindings}
        vertices, references, guards = [], list(operands.references), [operands.validate]
        for location, binding, fmt, offset in snapshot.fixed.attributes:
            source = self.vertices.get(binding)
            if source is None:
                raise ValueError('graphics draw vertex binding is unbound')
            stride, rate = strides[binding]
            span = buffer_span(self.engine, self.context_id, source)
            vertices.append(VertexFetch(location, binding, fmt, offset, stride, rate, span))
            references.extend(span.references)
            guards.append(span.validate)
        indices = None
        if indexed:
            if self.index_source is None:
                raise ValueError('graphics draw index buffer is unbound')
            indices = buffer_span(self.engine, self.context_id, self.index_source)
            references.extend(indices.references)
            guards.append(indices.validate)
        values, args = (), None
        if indirect:
            values, args = self._indirect(name, record)
            if args is None:
                return
            references.extend(args.references)
            guards.append(args.validate)
        elif indexed:
            values = tuple(record['imm'][:5])
        else:
            values = tuple(record['imm'][:4])
        framebuffer = framebuffer_operand(self.engine, self.context_id, self.pass_state.framebuffer)
        references.extend(framebuffer.references)
        guards.append(framebuffer.validate)
        _, _, cb = self.front.resolve(self.recording.command_buffer, self.kinds['VkCommandBuffer'])
        pool = self.front.ent[cb['parent']]
        references.extend((
            (self.recording.command_buffer, self.kinds['VkCommandBuffer']),
            (pool['gen'] << 16 | cb['parent'], self.kinds['VkCommandPool'])))
        engine, context_id, recording = self.engine, self.context_id, self.recording

        def validate():
            validate_recording(engine, context_id, recording)
            for guard in guards:
                guard()

        validate()
        self.plans.append(DrawPlan(recording.context, recording.device,
            recording.command_buffer, recording.recording, len(self.plans), name,
            values, args, snapshot, operands, self.pass_state, self.subpass,
            framebuffer.attachments, framebuffer, self.viewport, self.scissor,
            tuple(vertices), indices, tuple(dict.fromkeys(references)), validate))
