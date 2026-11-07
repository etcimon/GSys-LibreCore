# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Recording-scoped graphics binding operands; no work leases or draw execution."""
from dataclasses import dataclass

from vn_descriptor_operands import buffer_descriptor
from vn_graphics_dynamic import validate_recording
from vn_graphics_pipelines import operand as pipeline_operand
from vn_image_operands import image_descriptor
from vn_native_layouts import PipelineLayout


@dataclass(frozen=True)
class StageBindings:
    stage: int
    bindings: tuple
    push: tuple


@dataclass(frozen=True)
class GraphicsOperands:
    pipeline: object
    stages: tuple
    references: tuple
    validate: object


class GraphicsBindings:
    def __init__(self, engine, context_id, recording):
        validate_recording(engine, context_id, recording)
        self.engine, self.context_id, self.recording = engine, context_id, recording
        self.context = engine.contexts[context_id]
        self.front, self.kinds = self.context.frontend, engine.golden.KIND
        self.device = recording.device
        self.pipeline, self.sets, self.push, self.position = None, {}, {}, 0

    def _template(self, record):
        layout = record.get('native_pipeline_layout')
        if (not isinstance(layout, PipelineLayout) or layout.context is not self.context or
                layout.device != self.device):
            raise KeyError('graphics binding layout context/device is unavailable')
        return layout

    def _dataset(self, handle):
        status, slot, entry = self.front.resolve(handle, self.kinds['VkDescriptorSet'])
        if status != 'OK' or entry['ctx'] != self.context_id:
            raise KeyError('graphics binding descriptor generation/context is stale')
        dead, layout = self.front.dset_dead(entry)
        pool = self.front.ent[entry['parent']]
        if (dead or entry['aux'] & (1 << 31) or layout is None or pool is None or
                pool['parent'] != self.device & 0xFFFF or
                layout.get('native_signature') is None):
            raise KeyError('graphics binding descriptor pool/epoch/device is unavailable')
        return entry['gen'] << 16 | slot, layout

    def _payload(self, record, count, offset=0):
        length, base = record.get('payload_words', -1), record['imm'][7] + offset
        if (not 0 <= offset <= length <= 48 or not 0 <= count <= length - offset or
                base <= 0 or base + count > self.front.pay_words):
            raise ValueError('graphics binding payload exceeds record-local bounds')
        return [self.front.pay[base + i] for i in range(count)]

    def replay(self, name, record):
        validate_recording(self.engine, self.context_id, self.recording)
        records = self.recording.recording
        if self.position >= len(records) or records[self.position] is not record:
            raise ValueError('graphics binding records must be consumed in recording order')
        handled = True
        if name == 'vkCmdBindPipeline' and record['imm'][0] == 0:
            snapshot, refs = pipeline_operand(self.engine, self.context_id, record['handle'][0])
            if snapshot.device != self.device:
                raise ValueError('graphics binding pipeline belongs to another device')
            self.pipeline = refs[0][0]
        elif name == 'vkCmdBindDescriptorSets' and record['imm'][0] == 0:
            self._bind(record)
        elif (name == 'vkCmdPushConstants' and record['imm'][0] and
                not record['imm'][0] & ~0x11):
            self._push(record)
        else:
            handled = False
        self.position += 1
        return handled

    def _bind(self, record):
        _, first, count, dynamic_count = record['imm'][:4]
        template = self._template(record)
        if (not 0 < count <= 4 or first < 0 or first + count > len(template.sets) or
                not 0 <= dynamic_count <= 16 or
                record['payload_words'] != 2 * count + dynamic_count):
            raise ValueError('graphics binding set count/payload exceeds profile')
        data = self._payload(record, 2 * count + dynamic_count)
        cursor, staged = 2 * count, {}
        for i in range(count):
            handle, recorded_dynamic = data[2 * i:2 * i + 2]
            canonical, layout = self._dataset(handle)
            if layout['native_signature'] != template.sets[first + i]:
                raise ValueError('graphics binding descriptor layout is incompatible')
            offsets = {}
            for row in sorted(self.front.lay_rows(layout), key=lambda row: row['binding']):
                if row['dyn']:
                    end = cursor + row['count']
                    if end > len(data):
                        raise ValueError('graphics binding dynamic offsets are truncated')
                    offsets[row['binding']] = tuple(data[cursor:end])
                    cursor = end
            if sum(map(len, offsets.values())) != recorded_dynamic:
                raise ValueError('graphics binding dynamic descriptor count changed')
            staged[first + i] = canonical, template, offsets
        if cursor != len(data):
            raise ValueError('graphics binding dynamic offset count differs from layout')
        last = first + count - 1
        self.sets = {index: old for index, old in self.sets.items()
                     if index not in staged and old[1].compatible(template, min(index, last))}
        self.sets.update(staged)

    def _push(self, record):
        template = self._template(record)
        stages, offset, size = record['imm'][:3]
        if (not stages or offset < 0 or offset % 4 or size % 4 or
                not 0 < size <= 128 or offset + size > 128 or
                record['payload_words'] != 2 + size // 4 or
                self._payload(record, 2) != [offset, size]):
            raise ValueError('graphics binding push payload/range exceeds profile')
        values, staged = self._payload(record, size // 4, 2), {}
        for index, value in enumerate(values, offset // 4):
            coverage = 0
            for mask, begin, length in template.push:
                if begin <= index * 4 and index * 4 + 4 <= begin + length:
                    coverage |= mask
            if coverage != stages:
                raise ValueError('graphics binding push stage/range differs from layout')
            for stage in (1, 16):
                if stages & stage:
                    staged[stage, index] = value, template.push
        self.push.update(staged)

    def resolve(self):
        validate_recording(self.engine, self.context_id, self.recording)
        if self.pipeline is None:
            raise ValueError('graphics binding has no pipeline')
        handle = self.pipeline
        snapshot, references = pipeline_operand(self.engine, self.context_id, handle)
        guards, stages, references = [], [], list(references)
        _, _, cb = self.front.resolve(self.recording.command_buffer, self.kinds['VkCommandBuffer'])
        pool = self.front.ent[cb['parent']]
        references.extend(((self.recording.command_buffer, self.kinds['VkCommandBuffer']),
                           (pool['gen'] << 16 | cb['parent'], self.kinds['VkCommandPool'])))
        for requirement in snapshot.resources:
            bindings, push = [], [0] * 32
            for resource in requirement.bindings:
                bound = self.sets.get(resource.descriptor_set)
                if bound is None or not bound[1].compatible(snapshot.layout, resource.descriptor_set):
                    raise ValueError('graphics binding set is missing or disturbed/incompatible')
                descriptor, layout = self._dataset(bound[0])
                if layout['native_signature'] != snapshot.layout.sets[resource.descriptor_set]:
                    raise ValueError('graphics binding descriptor signature changed')
                dynamic = bound[2].get(resource.binding, (0,) * resource.count)
                if len(dynamic) < resource.count:
                    raise ValueError('graphics binding dynamic offsets exceed bound layout')
                for element in range(resource.count):
                    if resource.kind in (6, 7):
                        operand = buffer_descriptor(self.engine, self.context_id, descriptor,
                            resource.binding, element, dynamic_offset=dynamic[element],
                            set_index=resource.descriptor_set)
                    else:
                        operand = image_descriptor(self.engine, self.context_id, descriptor,
                            resource.binding, element, resource.descriptor_set)
                    if operand.binding.kind != resource.kind:
                        raise ValueError('graphics binding resource class differs from shader')
                    bindings.append(operand.binding)
                    references.extend(operand.references)
                    guards.append(operand.validate)
            for word in requirement.push_words:
                value = self.push.get((requirement.stage, word))
                if value is None or value[1] != snapshot.layout.push:
                    raise ValueError('graphics binding push word is undefined/incompatible')
                push[word] = value[0]
            stages.append(StageBindings(requirement.stage, tuple(bindings), tuple(push)))
        engine, context_id, recording = self.engine, self.context_id, self.recording

        def validate():
            validate_recording(engine, context_id, recording)
            if pipeline_operand(engine, context_id, handle)[0] is not snapshot:
                raise KeyError('graphics binding pipeline snapshot changed')
            for guard in guards:
                guard()

        validate()
        return GraphicsOperands(snapshot, tuple(stages), tuple(dict.fromkeys(references)), validate)
