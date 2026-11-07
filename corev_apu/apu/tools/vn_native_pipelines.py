# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Native compute-pipeline snapshots and canonical module lifetime resolution."""
from dataclasses import dataclass

from shader import spirv_scan
from vn_specialization import read_specialization, specialize


@dataclass(frozen=True)
class ComputePipeline:
    context: object
    device: int
    module: int
    layout: object
    code: tuple
    entry: bytes
    module_code: tuple


def capture(engine, current, name, words, record):
    if name != 'vkCreateComputePipelines':
        return None
    front, kinds = current.frontend, engine.golden.KIND
    decoder = engine.golden.Sim(engine.model, engine.assembly)
    decoded = decoder.run(words, want_trace=True)
    if decoded['fault'] or decoded['words'] != len(words):
        raise ValueError('native pipeline packet is malformed')
    fields, locations = {}, {}
    for pc, op, position in decoder.trace:
        note = engine.assembly['dec_ops'][pc][3].split(':')[0]
        if note not in ('module', 'layout', 'device', 'pName', 'stage', 'flags',
                        'pSpecializationInfo', 'mapEntryCount', 'createInfoCount'):
            continue
        if op in ('U32', 'FLAGS'):
            value = words[position]
        elif op in ('HANDLE', 'PTR', 'BLOB'):
            value = words[position] | words[position + 1] << 32
            if note == 'pName':
                if not 0 < value <= 256:
                    raise ValueError('native shader entry name exceeds bounds')
                raw = b''.join(w.to_bytes(4, 'little')
                               for w in words[position + 2:position + 2 + (value + 3) // 4])
                value = raw[:value]
                if value[-1:] != b'\0' or b'\0' in value[:-1]:
                    raise ValueError('native shader entry name is not terminated')
                value = value[:-1]
        else:
            continue
        fields.setdefault(note, []).append(value)
        locations.setdefault(note, []).append(position)
    count = len(fields.get('module', ()))
    if (not 0 < count <= 4 or fields.get('createInfoCount') != [count] or
            any(len(fields.get(key, ())) != count for key in
                ('layout', 'pName', 'stage', 'pSpecializationInfo')) or
            len(fields.get('flags', ())) != 2 * count or any(fields['flags']) or
            fields.get('stage') != [0x20] * count or len(fields.get('device', ())) != 1):
        raise ValueError('native compute pipeline count/stage/flags mismatch')

    def resolve(handle, kind):
        status, slot, entry = front.resolve(handle, kinds[kind])
        if status != 'OK' or entry['ctx'] != front.ctx:
            raise KeyError('native pipeline operand generation/context is stale')
        return entry['gen'] << 16 | slot, entry

    device, _ = resolve(fields['device'][0], 'VkDevice')
    owner, result = engine.contexts[front.ctx], []
    for i in range(count):
        module, entry = resolve(fields['module'][i], 'VkShaderModule')
        _, layout = resolve(fields['layout'][i], 'VkPipelineLayout')
        template = layout.get('native_pipeline_layout')
        original = tuple(front.sh_code.get(module, ()))
        if (entry['parent'] != device & 0xFFFF or template is None or
                template.context is not owner or template.device != device or
                not 5 <= len(original) <= 4096):
            raise ValueError('native pipeline module/layout/device exceeds profile')
        entries = read_specialization(words, locations['pSpecializationInfo'][i],
                                      locations['layout'][i])
        code = specialize(original, entries)
        try:
            scan = spirv_scan.Scanner(list(code)).scan()
        except (spirv_scan.Fault, IndexError, KeyError, TypeError) as error:
            raise ValueError('native specialization/module scan failed') from error
        if scan.em != 5:
            raise ValueError('native pipeline module is not valid compute')
        entry_name = b''.join(w.to_bytes(4, 'little') for w in scan.entry['name_bytes']).split(b'\0')[0]
        if fields['pName'][i] != entry_name:
            raise ValueError('selected shader entry does not match the module')
        result.append(ComputePipeline(owner, device, module, template, code, entry_name, original))
    slot = (engine.model.cmd_info[name]['act']['flags'] >> 1) & 1
    base, length = record['blob'][slot]
    if length != 2 * count:
        raise ValueError('native pipeline output count mismatch')
    ids = tuple(words[base + 2 * i] | words[base + 2 * i + 1] << 32 for i in range(count))
    # The legacy frontend owns allocation/pinning only; execution uses the fully
    # validated immutable native code, never its unspecialized shader path.
    allocation = tuple(word for i in range(count) for word in
                       (fields['module'][i] & 0xFFFFFFFF, fields['module'][i] >> 32, 0,
                        fields['layout'][i] & 0xFFFFFFFF, fields['layout'][i] >> 32))
    return ids, tuple(result), allocation


def attach(engine, current, out, captured):
    if captured is None or out['fault']:
        return
    ids, snapshots, _ = captured
    for i, (handle, snapshot) in enumerate(zip(ids, snapshots)):
        if i in out['null_mask']:
            continue
        status, _, entry = current.frontend.resolve(handle, engine.golden.KIND['VkPipeline'])
        if status == 'OK':
            entry['native_pipeline'] = snapshot


def operand(engine, context_id, handle):
    context = engine.contexts[context_id]
    front, kinds = context.frontend, engine.golden.KIND
    status, slot, entry = front.resolve(handle, kinds['VkPipeline'])
    if status != 'OK' or not engine.transfers._live(context):
        raise KeyError('native compute pipeline is unavailable')
    snapshot = entry.get('native_pipeline')
    if snapshot is None or snapshot.context is not context:
        raise ValueError('pipeline has no native compute snapshot')
    status, _, module = front.resolve(snapshot.module, kinds['VkShaderModule'], allow_zomb=True)
    status_device, _, _ = front.resolve(snapshot.device, kinds['VkDevice'])
    base = ((entry['aux'] >> 16) & 0xFFFF) << 6
    if (status != 'OK' or status_device != 'OK' or not module['pins'] or
            module['ctx'] != context_id or module['parent'] != entry['parent'] or
            entry['parent'] != snapshot.device & 0xFFFF or
            front.pay.get(base) != snapshot.module or
            tuple(front.sh_code.get(snapshot.module, ())) != snapshot.module_code):
        raise KeyError('native pipeline module/device snapshot is stale')
    references = ((entry['gen'] << 16 | slot, kinds['VkPipeline']),
                  (snapshot.module, kinds['VkShaderModule']),
                  (snapshot.device, kinds['VkDevice']))
    return snapshot, references
