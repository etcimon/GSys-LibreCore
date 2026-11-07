# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Internal opt-in compute recording replay; not wire shader admission."""
from vn_compute import Compute, IndirectArguments, spirv_scan
from vn_descriptor_operands import buffer_descriptor
from vn_native_layouts import PipelineLayout
from vn_native_pipelines import operand as pipeline_operand
from vn_image_operands import image_descriptor


class ComputeReplay:
    NAMES = frozenset(('vkCmdBindPipeline', 'vkCmdBindDescriptorSets',
                       'vkCmdPushConstants', 'vkCmdDispatch', 'vkCmdDispatchIndirect'))

    def __init__(self, engine, context, device, remember, payload, append,
                 charge, guards, dispatch_budget, extent):
        self.engine, self.context, self.device = engine, context, device
        self.front, self.kinds = context.frontend, engine.golden.KIND
        self.remember, self.payload, self.append, self.charge = remember, payload, append, charge
        self.guards, self.dispatch_budget = guards, dispatch_budget
        self.extent = extent
        self.dataset_guards = set()
        self.reset()

    def reset(self):
        self.pipeline, self.sets, self.push = None, {}, {}

    def template(self, record):
        template = record.get('native_pipeline_layout')
        if (not isinstance(template, PipelineLayout) or template.context is not self.context or
                template.device != self.device):
            raise KeyError('recorded layout snapshot belongs to a different context/device')
        return template

    def dataset(self, handle):
        handle, entry = self.remember(handle, self.kinds['VkDescriptorSet'])
        dead, layout = self.front.dset_dead(entry)
        if dead or entry['aux'] & (1 << 31) or layout is None:
            raise KeyError('compute descriptor set/pool/epoch is unavailable')
        pool = self.front.ent[entry['parent']]
        if pool is None or pool['parent'] != self.device & 0xFFFF:
            raise ValueError('compute descriptor set belongs to a different device')
        signature = layout.get('native_signature')
        if signature is None:
            raise ValueError('compute set has no by-value layout identity')
        if handle not in self.dataset_guards:
            def validate():
                status, _, live = self.front.resolve(handle, self.kinds['VkDescriptorSet'])
                if (not self.engine.transfers._live(self.context) or status != 'OK' or
                        live is not entry or entry['aux'] & (1 << 31) or
                        self.front.dset_dead(entry)[0]):
                    raise KeyError('bound descriptor set retired/poisoned during admission')

            self.guards.append(validate)
            self.dataset_guards.add(handle)
        return entry, layout, signature

    def replay(self, name, record):
        if name == 'vkCmdBindPipeline':
            if record['imm'][0] != 1:
                raise ValueError('graphics pipeline binding exceeds compute replay profile')
            handle = record['handle'][0]
            snapshot, references = pipeline_operand(self.engine, self.front.ctx, handle)
            if snapshot.device != self.device:
                raise ValueError('pipeline and command buffer belong to different devices')
            for ref, kind in references:
                self.remember(ref, kind, allow_zomb=kind == self.kinds['VkShaderModule'])
            self.pipeline = handle
        elif name == 'vkCmdBindDescriptorSets':
            point, first, count, dynamic_count = record['imm'][:4]
            template = self.template(record)
            if (point != 1 or not 0 < count <= 4 or first + count > len(template.sets) or
                    first < 0 or not 0 <= dynamic_count <= 16 or
                    record['payload_words'] != 2 * count + dynamic_count):
                raise ValueError('compute bind-set count/payload exceeds profile')
            data = self.payload(record, 2 * count + dynamic_count)
            cursor, staged = 2 * count, {}
            for i in range(count):
                handle, recorded_dynamic = data[2 * i:2 * i + 2]
                _, layout, signature = self.dataset(handle)
                if signature != template.sets[first + i]:
                    raise ValueError('descriptor set is incompatible with the recorded layout')
                offsets = {}
                for row in sorted(self.front.lay_rows(layout), key=lambda row: row['binding']):
                    if row['dyn']:
                        end = cursor + row['count']
                        if end > len(data):
                            raise ValueError('dynamic offsets are truncated')
                        offsets[row['binding']] = tuple(data[cursor:end])
                        cursor = end
                if sum(len(values) for values in offsets.values()) != recorded_dynamic:
                    raise ValueError('recorded dynamic descriptor count changed')
                staged[first + i] = (handle, template, offsets)
            if cursor != len(data):
                raise ValueError('dynamic offset count does not match bound layouts')
            last = first + count - 1
            self.sets = {index: old for index, old in self.sets.items()
                         if index not in staged and old[1].compatible(template, min(index, last))}
            self.sets.update(staged)
        elif name == 'vkCmdPushConstants':
            template = self.template(record)
            stages, offset, size = record['imm'][:3]
            if (not stages or offset % 4 or size % 4 or not 0 < size <= 128 or
                    offset + size > 128 or record['payload_words'] != 2 + size // 4):
                raise ValueError('compute push update exceeds recorded payload/profile')
            header = self.payload(record, 2)
            if header != [offset, size]:
                raise ValueError('compute push header differs from recorded immediates')
            words = self.payload(record, size // 4, 2)
            for index, word in enumerate(words, offset // 4):
                coverage = 0
                for mask, begin, length in template.push:
                    if begin <= index * 4 and index * 4 + 4 <= begin + length:
                        coverage |= mask
                if stages != coverage:
                    raise ValueError('push update stage/range is incompatible with layout')
                if stages & 0x20:
                    self.push[index] = (word, template.push)
        else:
            self.dispatch(record, indirect=name == 'vkCmdDispatchIndirect')

    def dispatch(self, record, *, indirect=False):
        if self.pipeline is None or not self.dispatch_budget[0]:
            raise ValueError('compute dispatch has no pipeline or exceeds job budget')
        snapshot, _ = pipeline_operand(self.engine, self.front.ctx, self.pipeline)
        scan = spirv_scan.Scanner(list(snapshot.code))
        scan.scan()
        bindings, keys, has_images = [], {}, False
        for variable in scan.vars.values():
            storage = variable['storage']
            image = storage == spirv_scan.SC['UNIFORMCONST']
            if storage == spirv_scan.SC['PUSHCONST']:
                size = scan.type_size(variable['type_id'])
                if not 0 < size <= 128 or size % 4:
                    raise ValueError('push block size exceeds compute replay profile')
                for index in range(size // 4):
                    value = self.push.get(index)
                    if value is None or value[1] != snapshot.layout.push:
                        raise ValueError('compute push block has undefined/incompatible words')
                continue
            if not image and storage not in (spirv_scan.SC['UNIFORM'], spirv_scan.SC['SBUF']):
                continue
            shape = scan.types[variable['type_id']]
            count = 1
            if image:
                kind = {spirv_scan.TK['SAMP']: 0, spirv_scan.TK['SIMG']: 1}.get(shape['kind'])
                info = scan.types[shape['elem']] if kind == 1 else shape
                if kind is None and shape['kind'] == spirv_scan.TK['IMG']:
                    kind = 2 if shape['cols'] == 1 else 3
                if kind is None or kind and (info['comps'] or info['sign']):
                    raise ValueError('array/depth image shader variables exceed compute profile')
                has_images = True
            else:
                if shape['kind'] == spirv_scan.TK['ARRAY']:
                    count, shape = shape['length'], scan.types[shape['elem']]
                if shape['kind'] != spirv_scan.TK['STRUCT'] or not 0 < count <= 16:
                    raise ValueError('buffer descriptor shape exceeds compute replay profile')
                kind = 6 if storage == spirv_scan.SC['UNIFORM'] else 7
            key = variable['set'], variable['binding']
            if key in keys:
                if keys[key] != (kind, count):
                    raise ValueError('shader descriptor aliases have incompatible shapes/classes')
                continue
            keys[key] = kind, count
            state = self.sets.get(key[0])
            if state is None or not state[1].compatible(snapshot.layout, key[0]):
                raise ValueError('shader descriptor set is missing or disturbed/incompatible')
            handle, _, offsets = state
            _, layout, _ = self.dataset(handle)
            signature_row = next((row for row in layout['native_signature'][1]
                                  if row[0] == key[1]), None)
            if (signature_row is None or not signature_row[3] & 0x20 or
                    count > signature_row[2]):
                raise ValueError('shader binding is not visible or count exceeds layout')
            dynamic = offsets.get(key[1], (0,) * count)
            if len(dynamic) < count or count > 16 - len(bindings):
                raise ValueError('shader descriptor rows/offsets exceed compute profile')
            for element in range(count):
                self.charge(32)
                if image:
                    operand = image_descriptor(self.engine, self.front.ctx, handle, key[1],
                                               element, key[0])
                else:
                    operand = buffer_descriptor(self.engine, self.front.ctx, handle, key[1], element,
                                                dynamic_offset=dynamic[element], set_index=key[0])
                if operand.binding.kind != kind:
                    raise ValueError('shader resource storage class differs from descriptor type')
                for ref, ref_kind in operand.references:
                    self.remember(ref, ref_kind)
                self.guards.append(operand.validate)
                bindings.append(operand.binding)
        push = tuple(self.push.get(index, (0, None))[0] for index in range(32))
        arguments = None
        if indirect:
            handle, entry = self.remember(record['handle'][0], self.kinds['VkBuffer'])
            owner, binding, capacity = self.extent(record, 0)
            offset = record['imm'][2] | record['imm'][3] << 32
            if (entry['parent'] != self.device & 0xFFFF or
                    owner.entry['parent'] != entry['parent'] or
                    not entry.get('native_usage', 0) & 0x100 or offset % 4 or
                    offset > capacity or 12 > capacity - offset):
                raise ValueError('indirect buffer usage/device/alignment/range exceeds profile')
            fields = ('bind_mem', 'bind_mgen', 'bind_off', 'size', 'native_usage')
            captured = tuple(entry.get(field) for field in fields)

            def validate():
                status, _, live = self.front.resolve(handle, self.kinds['VkBuffer'])
                if (status != 'OK' or live is not entry or
                        tuple(entry.get(field) for field in fields) != captured):
                    raise KeyError('indirect buffer binding changed during admission')

            self.guards.append(validate)
            arguments = IndirectArguments(owner, binding + offset)
        groups = (1, 1, 1) if indirect else tuple(record['imm'][:3])
        self.append(Compute(snapshot.code, tuple(bindings), groups, push, indirect=arguments,
                            allow_images=has_images))
        self.dispatch_budget[0] -= 1
