# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded specialized graphics I/O declarations; not complete shader admission."""
from dataclasses import dataclass

from shader.spirv_scan import BI_GFX, SC, TK


FORMAT_KIND = dict.fromkeys(
    (9, 10, 16, 17, 23, 24, 37, 38, 70, 71, 76, 77, 78, 83,
     84, 85, 90, 91, 92, 97, 100, 103, 106, 109), 'float')
FORMAT_KIND.update(dict.fromkeys((13, 20, 27, 41, 74, 81, 88, 95, 98, 101, 104, 107), 'uint'))
FORMAT_KIND.update(dict.fromkeys((14, 21, 28, 42, 75, 82, 89, 96, 99, 102, 105, 108), 'sint'))


@dataclass(frozen=True)
class GraphicsInterface:
    attributes: tuple
    varyings: tuple
    colors: tuple
    vertex_builtins: tuple
    fragment_builtins: tuple


def _shape(scan, tid):
    value = scan.types[tid]
    count = 1
    if value['kind'] == TK['VEC']:
        count = value['comps']
        if not 2 <= count <= 4:
            raise ValueError('graphics interface vector shape exceeds profile')
        value = scan.types[value['elem']]
    kind = {TK['FLOAT']: 'float', TK['INT']: 'sint' if value['sign'] else 'uint',
            TK['BOOL']: 'bool'}.get(value['kind'])
    if kind is None:
        raise ValueError('graphics interface scalar/vector type exceeds profile')
    return kind, count


def _collect(scan):
    raw = scan.entry['name_bytes']
    name = b''.join(word.to_bytes(4, 'little') for word in raw)
    end = name.find(b'\0')
    interface = raw[(end + 4) // 4:] if end >= 0 else ()
    if end < 0 or len(set(interface)) != len(interface) or any(i not in scan.vars for i in interface):
        raise ValueError('graphics interface entry list is malformed')
    inputs, outputs, builtins = {}, {}, {}

    def builtin(storage, identifier, shape):
        key = storage, identifier
        if key in builtins:
            raise ValueError('graphics interface has duplicate builtins')
        if scan.em == 0:
            valid = ((storage == SC['OUTPUT'] and identifier == BI_GFX['POSITION'] and
                      shape == ('float', 4)) or
                     (storage == SC['INPUT'] and identifier in (42, 43) and
                      shape in (('sint', 1), ('uint', 1))))
        else:
            valid = (storage == SC['INPUT'] and
                     ((identifier == BI_GFX['FRAGCOORD'] and shape == ('float', 4)) or
                      (identifier in (17, 23) and shape == ('bool', 1))))
        if not valid:
            raise ValueError('graphics interface builtin/type exceeds color profile')
        builtins[key] = shape

    for identifier, var in scan.vars.items():
        storage = var['storage']
        if storage == SC['WORKGROUP']:
            raise ValueError('graphics interface does not admit graphics workgroup variables')
        if storage not in (SC['INPUT'], SC['OUTPUT']):
            continue
        if identifier not in interface:
            raise ValueError('graphics interface variable is absent from selected entry')
        decoration = scan.decor.get(identifier, {})
        tid = var['type_id']
        if 'builtin' in decoration:
            if 'location' in decoration:
                raise ValueError('graphics interface mixes builtin and location')
            builtin(storage, decoration['builtin'], _shape(scan, tid))
        elif scan.types[tid]['kind'] == TK['STRUCT'] and scan.types[tid].get('has_bi'):
            if storage != SC['OUTPUT'] or scan.em != 0 or 'location' in decoration:
                raise ValueError('graphics interface builtin block exceeds profile')
            base = scan.member_base[tid]
            for index in range(scan.types[tid]['nmemb']):
                member = scan.members[base + index]
                bi = scan.mdecor.get((tid, index), {}).get('builtin')
                builtin(storage, bi, _shape(scan, member['type']))
        else:
            location = decoration.get('location')
            rows = inputs if storage == SC['INPUT'] else outputs
            if type(location) is not int or not 0 <= location <= 7 or location in rows:
                raise ValueError('graphics interface location is missing/duplicated')
            shape = _shape(scan, tid)
            if (scan.em == 4 or storage == SC['OUTPUT']) and shape[0] != 'float':
                raise ValueError('graphics interface requires floating varyings/colors')
            rows[location] = shape
    return inputs, outputs, builtins


def validate(vertex, fragment, fixed, render_pass):
    vin, vout, vbi = _collect(vertex)
    fin, fout, fbi = _collect(fragment)
    if (SC['OUTPUT'], BI_GFX['POSITION']) not in vbi:
        raise ValueError('graphics interface requires one vec4 Position output')
    attributes = {location: fmt for location, _, fmt, _ in fixed.attributes}
    for location, shape in vin.items():
        if location not in attributes or FORMAT_KIND.get(attributes[location]) != shape[0]:
            raise ValueError('graphics interface vertex input/format class mismatch')
    for location, shape in fin.items():
        if vout.get(location) != shape:
            raise ValueError('graphics interface vertex/fragment varying mismatch')
    for location in fout:
        if location >= len(render_pass.colors) or render_pass.colors[location][0] == 0xFFFFFFFF:
            raise ValueError('graphics interface fragment color exceeds active subpass')
    return GraphicsInterface(tuple(sorted(vin.items())), tuple(sorted(fin.items())),
                             tuple(sorted(fout.items())), tuple(sorted(vbi.items())),
                             tuple(sorted(fbi.items())))
