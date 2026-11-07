# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Graphics shader resource requirements; no descriptor binding or execution."""
from dataclasses import dataclass

from shader.spirv_scan import SC, TK


@dataclass(frozen=True)
class Resource:
    descriptor_set: int
    binding: int
    kind: int
    count: int
    layout_kind: int


@dataclass(frozen=True)
class StageResources:
    stage: int
    bindings: tuple
    push_words: tuple


def _blocks(scan):
    # Scanner flag bits intentionally alias decorations for the table ABI.
    # Read exact Block/BufferBlock decorations without changing that ABI.
    result, position = {}, 5
    while position < len(scan.w):
        word = scan.w[position]
        if word & 0xFFFF == 71:
            target, decoration = scan.w[position + 1:position + 3]
            if decoration in (2, 3):
                result.setdefault(target, set()).add(decoration)
        position += word >> 16
    return result


def _push_words(scan, tid, blocks):
    shape = scan.types[tid]
    if shape['kind'] != TK['STRUCT'] or blocks.get(tid) != {2} or not shape['nmemb']:
        raise ValueError('graphics resource push block exceeds flat struct profile')
    words = set()
    for index in range(shape['nmemb']):
        member = scan.members[scan.member_base[tid] + index]
        value = scan.types[member['type']]
        count = value['comps'] if value['kind'] == TK['VEC'] else 1
        scalar = scan.types[value['elem']] if value['kind'] == TK['VEC'] else value
        offset = member['offset']
        if (scalar['kind'] not in (TK['BOOL'], TK['INT'], TK['FLOAT']) or
                not 1 <= count <= 4 or offset % 4 or offset + count * 4 > 128 or
                'offset' not in scan.mdecor.get((tid, index), {})):
            raise ValueError('graphics resource push member shape/offset exceeds profile')
        used = set(range(offset // 4, offset // 4 + count))
        if words & used:
            raise ValueError('graphics resource push members overlap')
        words.update(used)
    return tuple(sorted(words))


def validate(scans, layout):
    result = []
    for stage, execution_model in ((1, 0), (0x10, 4)):
        scan = scans[stage]
        if scan.em != execution_model:
            raise ValueError('graphics resource stage differs from selected shader')
        blocks, bindings, push = _blocks(scan), {}, None
        for identifier, variable in scan.vars.items():
            storage, tid = variable['storage'], variable['type_id']
            if storage == SC['PUSHCONST']:
                if push is not None:
                    raise ValueError('graphics resource has multiple push blocks')
                push = _push_words(scan, tid, blocks)
                for word in push:
                    if not any(mask & stage and begin <= word * 4 and word * 4 + 4 <= begin + size
                               for mask, begin, size in layout.push):
                        raise ValueError('graphics resource push word is not visible in layout')
                continue
            if storage not in (SC['UNIFORM'], SC['SBUF'], SC['UNIFORMCONST']):
                continue
            shape, count = scan.types[tid], 1
            if storage == SC['UNIFORMCONST']:
                kind = {TK['SAMP']: 0, TK['SIMG']: 1}.get(shape['kind'])
                image = scan.types[shape['elem']] if kind == 1 else shape
                if kind is None and shape['kind'] == TK['IMG']:
                    kind = 2 if shape['cols'] == 1 else 3
                if kind is None or kind and (image['comps'] or image['sign']):
                    raise ValueError('graphics resource image shape exceeds scalar 2D profile')
            else:
                if shape['kind'] == TK['ARRAY']:
                    count, tid = shape['length'], shape['elem']
                    shape = scan.types[tid]
                decoration = blocks.get(tid)
                if (shape['kind'] != TK['STRUCT'] or not 0 < count <= 16 or
                        decoration not in ({2}, {3}) or storage == SC['SBUF'] and decoration != {2}):
                    raise ValueError('graphics resource buffer shape/block exceeds profile')
                kind = 7 if storage == SC['SBUF'] or decoration == {3} else 6
            decoration = scan.decor.get(identifier, {})
            key = variable['set'], variable['binding']
            if ('set' not in decoration or 'binding' not in decoration or
                    not 0 <= key[0] < len(layout.sets) or not 0 <= key[1] < 256):
                raise ValueError('graphics resource descriptor set/binding is missing')
            row = next((row for row in layout.sets[key[0]][1] if row[0] == key[1]), None)
            if (row is None or not row[3] & stage or count > row[2] or
                    {8: 6, 9: 7}.get(row[1], row[1]) != kind):
                raise ValueError('graphics resource layout type/count/stage is incompatible')
            resource = Resource(*key, kind, count, row[1])
            if key in bindings and bindings[key] != resource:
                raise ValueError('graphics resource aliases have incompatible shapes')
            bindings[key] = resource
        if sum(value.count for value in bindings.values()) > 16:
            raise ValueError('graphics resource stage descriptor budget exceeds profile')
        result.append(StageResources(stage, tuple(bindings[key] for key in sorted(bindings)),
                                     () if push is None else push))
    return tuple(result)
