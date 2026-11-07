# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Native graphics stage/state identity; snapshots do not admit draw execution."""
from dataclasses import dataclass, replace

from shader import spirv_scan
from vn_graphics_interfaces import validate as validate_interfaces
from vn_graphics_resources import validate as validate_resources
from vn_graphics_state import validate as validate_state
from vn_native_rendering import RenderPass
from vn_specialization import read_specialization, specialize


@dataclass(frozen=True)
class ShaderStage:
    module: int
    code: tuple
    entry: bytes
    module_code: tuple


@dataclass(frozen=True)
class GraphicsPipeline:
    context: object
    device: int
    layout_handle: int
    layout: object
    render_pass: RenderPass
    subpass: int
    vertex: ShaderStage
    fragment: ShaderStage
    wire: tuple
    fixed: object
    interfaces: object
    resources: tuple
    state: tuple = ()
    flat: int = 0
    nopersp: int = 0


def capture(engine, current, name, words, record):
    if name != 'vkCreateGraphicsPipelines':
        return None
    if not 0 < len(words) <= 4096:
        raise ValueError('graphics pipeline packet exceeds identity budget')
    front, kinds = current.frontend, engine.golden.KIND
    decoder = engine.golden.Sim(engine.model, engine.assembly)
    decoded = decoder.run(words, want_trace=True)
    if decoded['fault'] or decoded['words'] != len(words):
        raise ValueError('graphics pipeline packet is malformed')
    fields, state_fields, blobs, specs, pending = {}, {}, {}, [], None
    for pc, op, position in decoder.trace:
        note = engine.assembly['dec_ops'][pc][3].split(':')[0]
        if op in ('U32', 'FLAGS'):
            value = words[position]
        elif op in ('HANDLE', 'PTR', 'BLOB', 'ARRAY', 'PNEXT'):
            value = words[position] | words[position + 1] << 32
            if note == 'pName' and op in ('PTR', 'BLOB'):
                if not 0 < value <= 256:
                    raise ValueError('graphics shader entry name exceeds bounds')
                raw = b''.join(word.to_bytes(4, 'little') for word in
                               words[position + 2:position + 2 + (value + 3) // 4])[:value]
                if raw[-1:] != b'\0' or b'\0' in raw[:-1]:
                    raise ValueError('graphics shader entry name is not terminated')
                value = raw[:-1]
        else:
            continue
        fields.setdefault(note, []).append(value)
        if pending is None and note != 'pSpecializationInfo':
            state_fields.setdefault(note, []).append(value)
        if note in ('pDynamicStates', 'blendConstants', 'pSampleMask') and op == 'BLOB':
            blobs[note] = tuple(words[position + 2:position + 2 + value])
        if note == 'pSpecializationInfo' and op == 'PTR':
            if pending is not None or value not in (0, 1):
                raise ValueError('graphics specialization shape exceeds profile')
            specs.append((position, position + 2 if not value else None))
            pending = len(specs) - 1 if value else None
        elif note == 'pData' and op == 'BLOB' and pending is not None:
            specs[pending] = specs[pending][0], position + 2 + (value + 3) // 4
            pending = None
    if (fields.get('createInfoCount') != [1] or fields.get('stageCount') != [2] or
            sorted(fields.get('stage', ())) != [1, 0x10] or
            any(len(fields.get(key, ())) != 2 for key in ('module', 'pName')) or
            len(specs) != 2 or pending is not None or
            any(fields.get('flags', ())) or any(fields.get('pNext', ())) or
            fields.get('pipelineCache') != [0] or
            fields.get('basePipelineHandle') != [0] or
            fields.get('basePipelineIndex') not in ([0], [0xFFFFFFFF]) or
            fields.get('pAllocator') != [0]):
        raise ValueError('graphics pipeline stage/count/flags/base exceeds identity profile')

    def resolve(value, kind):
        status, slot, entry = front.resolve(value, kinds[kind])
        if status != 'OK' or entry['ctx'] != front.ctx:
            raise KeyError('graphics pipeline generation/context is stale')
        return entry['gen'] << 16 | slot, entry

    def one(key):
        values = fields.get(key, ())
        if len(values) != 1:
            raise ValueError('graphics pipeline field/count mismatch: ' + key)
        return values[0]

    owner = engine.contexts[front.ctx]
    device, _ = resolve(one('device'), 'VkDevice')
    layout_handle, le = resolve(one('layout'), 'VkPipelineLayout')
    _, rpe = resolve(one('renderPass'), 'VkRenderPass')
    layout, render_pass = le.get('native_pipeline_layout'), rpe.get('native_rendering')
    if (layout is None or layout.context is not owner or layout.device != device or
            not isinstance(render_pass, RenderPass) or render_pass.context is not owner or
            render_pass.device != device):
        raise ValueError('graphics layout/render-pass identity crosses devices')
    pipeline_subpass = one('subpass')
    if not 0 <= pipeline_subpass < render_pass.subpass_count:
        raise ValueError('graphics pipeline subpass exceeds render pass profile')
    stages, scans, allocation = {}, {}, [2]
    for i, stage in enumerate(fields['stage']):
        module, entry = resolve(fields['module'][i], 'VkShaderModule')
        original = tuple(front.sh_code.get(module, ()))
        if entry['parent'] != device & 0xFFFF or not 5 <= len(original) <= 4096:
            raise ValueError('graphics shader module/device exceeds profile')
        code = specialize(original, read_specialization(words, *specs[i]))
        try:
            scan = spirv_scan.Scanner(list(code)).scan()
        except (spirv_scan.Fault, IndexError, KeyError, TypeError, RecursionError) as error:
            raise ValueError('graphics shader scan failed') from error
        selected = b''.join(word.to_bytes(4, 'little')
                            for word in scan.entry['name_bytes']).split(b'\0')[0]
        if scan.em != (0 if stage == 1 else 4) or fields['pName'][i] != selected:
            raise ValueError('graphics shader stage/selected entry does not match module')
        stages[stage] = ShaderStage(module, code, selected, original)
        scans[stage] = scan
    # Legacy allocation expects VS then FS; retain the original wire separately.
    for stage in (1, 0x10):
        raw = fields['module'][fields['stage'].index(stage)]
        allocation.extend((stage, raw & 0xFFFFFFFF, raw >> 32))
    if len(record['pay']) < 7 or record['pay'][:7] != [
            2, *[value for stage, raw in zip(fields['stage'], fields['module'])
                 for value in (stage, raw & 0xFFFFFFFF, raw >> 32)]]:
        raise ValueError('graphics stage allocation payload differs from wire')
    allocation.extend(record['pay'][7:])
    slot = (engine.model.cmd_info[name]['act']['flags'] >> 1) & 1
    base, length = record['blob'][slot]
    if length != 2:
        raise ValueError('graphics pipeline output count exceeds profile')
    identifier = words[base] | words[base + 1] << 32
    fixed = validate_state(engine, state_fields, blobs, render_pass, pipeline_subpass)
    interfaces = validate_interfaces(scans[1], scans[0x10], fixed, render_pass,
                                     pipeline_subpass)
    resources = validate_resources(scans, layout)
    snapshot = GraphicsPipeline(owner, device, layout_handle, layout, render_pass,
                                pipeline_subpass, stages[1], stages[0x10], tuple(words),
                                fixed, interfaces, resources,
                                flat=scans[0x10].flat_mask,
                                nopersp=scans[0x10].nopersp_mask)
    return (identifier,), (snapshot,), tuple(allocation)


def attach(engine, current, out, captured):
    if captured is None or out['fault'] or out['result'] or 0 in out['null_mask']:
        return
    status, _, entry = current.frontend.resolve(captured[0][0], engine.golden.KIND['VkPipeline'])
    if status != 'OK':
        raise KeyError('created graphics pipeline is unavailable')
    base = ((entry['aux'] >> 16) & 0xFFFF) << 6
    state = tuple(current.frontend.pay.get(base + i) for i in range(engine.golden.GP_PAY_WORDS))
    entry['native_graphics_pipeline'] = replace(captured[1][0], state=state)


def operand(engine, context_id, handle):
    context = engine.contexts[context_id]
    front, kinds = context.frontend, engine.golden.KIND
    status, slot, entry = front.resolve(handle, kinds['VkPipeline'])
    if status != 'OK' or not engine.transfers._live(context):
        raise KeyError('native graphics pipeline is unavailable')
    snapshot = entry.get('native_graphics_pipeline')
    if (not isinstance(snapshot, GraphicsPipeline) or snapshot.context is not context or
            entry['parent'] != snapshot.device & 0xFFFF or not entry['aux'] & 0x40 or
            entry['aux'] >> 32 != snapshot.layout_handle or
            front.resolve(snapshot.device, kinds['VkDevice'])[0] != 'OK'):
        raise ValueError('pipeline has no live native graphics identity')
    base = ((entry['aux'] >> 16) & 0xFFFF) << 6
    if tuple(front.pay.get(base + i) for i in range(engine.golden.GP_PAY_WORDS)) != snapshot.state:
        raise KeyError('graphics pipeline parked state changed')
    refs = [(entry['gen'] << 16 | slot, kinds['VkPipeline']), (snapshot.device, kinds['VkDevice'])]
    for stage, offset in ((snapshot.vertex, 44), (snapshot.fragment, 46)):
        status, _, module = front.resolve(stage.module, kinds['VkShaderModule'], allow_zomb=True)
        if (status != 'OK' or not module['pins'] or module['ctx'] != context_id or
                module['parent'] != entry['parent'] or snapshot.state[offset] != stage.module or
                snapshot.state[offset + 1] != module['aux'] >> 32 or
                tuple(front.sh_code.get(stage.module, ())) != stage.module_code):
            raise KeyError('graphics shader module provenance changed')
        refs.append((stage.module, kinds['VkShaderModule']))
    return snapshot, tuple(refs)
