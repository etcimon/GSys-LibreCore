# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Nonexecuting per-draw state plans; no fetch, raster, leases or capset admission."""
from dataclasses import dataclass

from vn_graphics_bindings import GraphicsBindings
from vn_graphics_dynamic import DynamicCommand, Recording, validate as dynamic_values
from vn_graphics_dynamic import validate_recording, _BOOL_DYNAMIC, _VECTOR_DYNAMIC
from vn_native_rendering import framebuffer_operand
from vn_render_pass_commands import BeginPass, EndPass, NextPass
from vn_dynamic_rendering import BeginRendering, EndRendering
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
    restart: object
    discard: object
    cull: object
    front_face: object
    depth_test: object
    depth_write: object
    depth_compare: object
    bounds_test: object
    bounds: object
    depth_bias_enable: object
    depth_bias: object
    topology: object
    stencil_test: object
    stencil_op: object
    stencil_compare_mask: object
    stencil_write_mask: object
    stencil_reference: object
    blend_constants: object
    stipple: object
    vertices: tuple
    indices: object
    references: tuple
    validate: object


# DynamicCommand kind -> GraphicsDraws shadow attribute for the single-
# scalar dynamic-state commands.
_BOOL_ATTR = {'primitive_restart': 'restart',
              'rasterizer_discard': 'discard',
              'cull': 'cull',
              'front_face': 'front_face',
              'depth_test': 'depth_test',
              'depth_write': 'depth_write',
              'depth_compare': 'depth_compare',
              'bounds_test': 'bounds_test',
              'depth_bias_enable': 'depth_bias_enable',
              'topology': 'topology',
              'stencil_test': 'stencil_test'}


class GraphicsDraws:
    DRAWS = frozenset(('vkCmdDraw', 'vkCmdDrawIndexed',
                        'vkCmdDrawIndirect', 'vkCmdDrawIndexedIndirect',
                        'vkCmdDrawIndirectCount', 'vkCmdDrawIndexedIndirectCount'))

    def __init__(self, engine, context_id, recording):
        validate_recording(engine, context_id, recording)
        self.engine, self.context_id, self.recording = engine, context_id, recording
        self.context = engine.contexts[context_id]
        self.front, self.kinds = self.context.frontend, engine.golden.KIND
        self.device = recording.device
        self.bindings = GraphicsBindings(engine, context_id, recording)
        self.viewport = self.scissor = None
        self.restart = self.discard = self.cull = self.front_face = None
        self.depth_test = self.depth_write = self.depth_compare = None
        self.bounds_test = self.bounds = None
        self.depth_bias_enable = self.depth_bias = None
        self.topology = None
        self.stencil_test = self.stencil_op = self.stencil_compare_mask = None
        self.stencil_write_mask = self.stencil_reference = None
        self.blend_constants = None
        # vkCmdSetLineStipple is dynamic-command state only (the static
        # VkPipelineRasterizationLineStateCreateInfo pNext is not admitted
        # and there is no SetLineStippleEnableEXT in the catalog): stipple
        # carries (factor,pattern); the hardware ties the enable to the
        # declared dynamic bit with an all-ones default pattern.
        self.stipple = None
        # line width is bounded-inert: create-info requires exactly 1.0 and
        # the raster ignores width, so the dynamic command is validated and
        # consumed but carries no per-draw override into DrawPlan.
        self.line_width = None
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
        if name in ('vkCmdSetViewport', 'vkCmdSetScissor',
                    'vkCmdSetViewportWithCount', 'vkCmdSetScissorWithCount'):
            return self._dynamic(name, record)
        if name in _BOOL_DYNAMIC:
            return self._bool(record, _BOOL_DYNAMIC[name])
        if name in _VECTOR_DYNAMIC:
            return self._vector(record, _VECTOR_DYNAMIC[name][0])
        if name == 'vkCmdSetBlendConstants':
            return self._vector(record, 'blend_constants')
        if name in ('vkCmdBindVertexBuffers', 'vkCmdBindVertexBuffers2'):
            return self._vertex_bindings(record)
        if name in ('vkCmdBindIndexBuffer', 'vkCmdBindIndexBuffer2'):
            return self._index_binding(record)
        if name in ('vkCmdBeginRenderPass', 'vkCmdBeginRenderPass2'):
            self._begin(record)
            return True
        if name in ('vkCmdEndRenderPass', 'vkCmdEndRenderPass2'):
            self._end(record)
            return True
        if name in ('vkCmdNextSubpass', 'vkCmdNextSubpass2'):
            self._next(record)
            return True
        if name == 'vkCmdBeginRendering':
            self._begin_dynamic(record)
            return True
        if name == 'vkCmdEndRendering':
            self._end_dynamic(record)
            return True
        if name in ('vkCmdSetRenderingAttachmentLocations',
                    'vkCmdSetRenderingInputAttachmentIndices'):
            # Dynamic-rendering attachment remap / input-attachment index
            # state: the bounded fragment model has no input-attachment read
            # path and the attachment-location permutation is deferred, so
            # both are recognised no-ops (handled, no state change).
            return True
        if name in self.DRAWS:
            self._draw(name, record)
            return True
        return False

    def _dynamic(self, name, record):
        snapshot = record.get('native_graphics_dynamic')
        kind = 'viewport' if 'Viewport' in name else 'scissor'
        if not isinstance(snapshot, DynamicCommand) or snapshot.kind != kind:
            raise KeyError('graphics draw dynamic snapshot is unavailable')
        values = dynamic_values(self.engine, self.context_id, snapshot)
        if kind == 'viewport':
            self.viewport = values
        else:
            self.scissor = values
        return True

    def _bool(self, record, kind):
        snapshot = record.get('native_graphics_dynamic')
        if (not isinstance(snapshot, DynamicCommand) or
                snapshot.kind != kind):
            raise KeyError('graphics draw dynamic snapshot is unavailable')
        setattr(self, _BOOL_ATTR[kind],
                dynamic_values(self.engine, self.context_id, snapshot)[0])
        return True

    def _vector(self, record, kind):
        snapshot = record.get('native_graphics_dynamic')
        if (not isinstance(snapshot, DynamicCommand) or
                snapshot.kind != kind):
            raise KeyError('graphics draw dynamic snapshot is unavailable')
        setattr(self, kind,
                dynamic_values(self.engine, self.context_id, snapshot))
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

    def _begin_dynamic(self, record):
        snapshot = record.get('native_dynamic_render')
        if not isinstance(snapshot, BeginRendering):
            raise KeyError('graphics draw dynamic-rendering begin snapshot is unavailable')
        if self.pass_state is not None:
            raise ValueError('graphics draw render pass is nested')
        self.pass_state = snapshot
        self.subpass = 0

    def _end_dynamic(self, record):
        snapshot = record.get('native_dynamic_render')
        if not isinstance(snapshot, EndRendering) or snapshot.begin is not self.pass_state:
            raise ValueError('graphics draw dynamic-rendering end does not match begin')
        self.pass_state = None
        self.subpass = 0

    def _buffer_binding(self, raw):
        """Resolve one generational VkBuffer handle to (slot, entry, memory, handle)."""
        status, slot, entry = self.front.resolve(raw, self.kinds['VkBuffer'])
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
        return slot, entry, memory, memory_handle

    def _indirect_count(self, entry, memory_handle, count_offset, max_draw_count):
        """Read the u32 draw count a Count-indirect command carries in memory.

        The count is sampled when the submission's ops are assembled; the
        per-command argument fetches stay execution-time, matching how the
        executor re-reads each stride-offset command at draw issue."""
        if count_offset % 4 or count_offset + 4 > entry['size']:
            raise ValueError('graphics indirect count range exceeds buffer')
        base = self.engine.memory(self.context_id, memory_handle).base
        if base is None:
            raise ValueError('graphics indirect count buffer is unbacked')
        addr = base + entry.get('bind_off', 0) + count_offset
        count = int.from_bytes(self.engine.state.aperture.read(addr, 4), 'little')
        return min(count, max_draw_count)

    def _indirect(self, name, record):
        indexed = 'Indexed' in name
        size = 20 if indexed else 16
        count_cmd = 'IndirectCount' in name
        stride = record['imm'][1]
        offset = record['imm'][2] | record['imm'][3] << 32
        draw_count = None
        if count_cmd:
            max_draw_count = record['imm'][0]
            count_offset = record['imm'][4] | record['imm'][5] << 32
        else:
            draw_count = record['imm'][0]
            if draw_count == 0:
                return (), ()
        if (stride < size or stride % 4 or offset > 0xFFFFFFFF or
                offset % 4 or record['payload_words']):
            raise ValueError('graphics indirect draw exceeds profile')
        buffers = [handle for handle, kind in zip(record['handle'], record['kind'])
                   if kind == self.kinds['VkBuffer'] and handle]
        if not buffers:
            raise KeyError('graphics indirect draw buffer operand is unavailable')
        slot, entry, memory, memory_handle = self._buffer_binding(buffers[0])
        if count_cmd:
            if len(buffers) < 2:
                raise KeyError('graphics indirect count buffer operand is unavailable')
            _, count_entry, _, count_handle = self._buffer_binding(buffers[1])
            draw_count = self._indirect_count(count_entry, count_handle,
                                              count_offset, max_draw_count)
            if draw_count == 0:
                return (), ()
        # each command becomes one draw plan/op, so the count is bounded
        # by the executor's per-job operation budget (a larger request
        # could never be admitted and must not spin the plan loop).
        if draw_count > self.engine.transfers.max_operations:
            raise ValueError('graphics indirect draw count exceeds profile')
        usage = entry.get('native_usage', 0)
        if (not usage & 0x100 or offset >= entry['size'] or
                entry.get('bind_off', 0) + entry['size'] > memory['size'] or
                offset + (draw_count - 1) * stride + size > entry['size']):
            raise ValueError('graphics indirect usage/range exceeds logical buffer')
        spans = []
        for i in range(draw_count):
            source = BufferSource(self.context, self.device, entry['gen'] << 16 | slot,
                                  memory_handle, entry.get('bind_off', 0), entry['size'],
                                  usage, offset + i * stride, 0)
            spans.append(buffer_span(self.engine, self.context_id, source, size))
        return (draw_count, stride, offset), tuple(spans)

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
        values, indirect_ops = (), ()
        if indirect:
            values, indirect_ops = self._indirect(name, record)
            if not indirect_ops:
                return
            for op in indirect_ops:
                references.extend(op.references)
                guards.append(op.validate)
        elif indexed:
            values = tuple(record['imm'][:5])
        else:
            values = tuple(record['imm'][:4])
        if isinstance(self.pass_state, BeginRendering):
            framebuffer = self.pass_state.operand
        else:
            framebuffer = framebuffer_operand(self.engine, self.context_id,
                                              self.pass_state.framebuffer)
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
        references = tuple(dict.fromkeys(references))
        vertices = tuple(vertices)
        # one plan per executed draw: a multi-draw-indirect record expands
        # to one stride-offset operand apiece so each fetch resolves its own
        # command arguments at execution time; direct/single draws yield one.
        for indirect_op in (indirect_ops if indirect else (None,)):
            self.plans.append(DrawPlan(recording.context, recording.device,
                recording.command_buffer, recording.recording, len(self.plans),
                name, values, indirect_op, snapshot, operands, self.pass_state,
                self.subpass, framebuffer.attachments, framebuffer,
                self.viewport, self.scissor, self.restart, self.discard,
                self.cull, self.front_face,
                self.depth_test, self.depth_write, self.depth_compare,
                self.bounds_test, self.bounds,
                self.depth_bias_enable, self.depth_bias, self.topology,
                self.stencil_test, self.stencil_op,
                self.stencil_compare_mask, self.stencil_write_mask,
                self.stencil_reference, self.blend_constants,
                self.stipple,
                vertices, indices, references, validate))
