# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded native scalar specialization; shared module words stay immutable."""
from shader.spirv_scan import Fault, Scanner, TK


def read_specialization(words, start, end):
    if not 0 <= start <= end <= len(words):
        raise ValueError('specialization record bounds')
    position = start

    def take(count):
        nonlocal position
        if count > end - position:
            raise ValueError('specialization record is truncated')
        value = words[position:position + count]
        position += count
        return value

    def u64():
        lo, hi = take(2)
        return lo | hi << 32

    present = u64()
    entries, result = [], []
    if present:
        if present != 1:
            raise ValueError('specialization pointer encoding')
        count, = take(1)
        if count > 32 or u64() != count:
            raise ValueError('specialization entry count exceeds profile')
        seen = set()
        for _ in range(count):
            identifier, offset = take(2)
            size = u64()
            if identifier in seen or size not in (1, 2, 4):
                raise ValueError('specialization duplicate ID or unsupported size')
            seen.add(identifier)
            entries.append((identifier, offset, size))
        size = u64()
        if size > 64 or u64() != size:
            raise ValueError('specialization data size exceeds profile')
        data = b''.join(word.to_bytes(4, 'little') for word in take((size + 3) // 4))[:size]
        for identifier, offset, length in entries:
            if offset > size or length > size - offset:
                raise ValueError('specialization entry exceeds data')
            result.append((identifier, data[offset:offset + length]))
    if position != end:
        raise ValueError('specialization record has trailing words')
    return tuple(result)


def specialize(words, entries=()):
    """Fold supported scalar/default composite constants, then use the normal scanner."""
    if (not 5 <= len(words) <= 4096 or
            any(type(word) is not int or not 0 <= word <= 0xFFFFFFFF for word in words)):
        raise ValueError('specialization module word bounds')
    values = dict(entries)
    if len(entries) > 32 or len(values) != len(entries):
        raise ValueError('specialization entry count/IDs')
    if any(type(key) is not int or not 0 <= key <= 0xFFFFFFFF or
           not isinstance(value, bytes) or len(value) not in (1, 2, 4)
           for key, value in entries):
        raise ValueError('specialization value encoding')
    instructions, types, decorations, targets = [], {}, {}, set()
    position = 5
    while position < len(words):
        count, opcode = words[position] >> 16, words[position] & 0xFFFF
        if not count or count > len(words) - position:
            raise ValueError('specialization malformed instruction')
        operands = tuple(words[position + 1:position + count])
        instructions.append((opcode, operands))
        if opcode == 20 and len(operands) == 1:
            types[operands[0]] = 'bool'
        elif opcode == 21 and len(operands) == 3 and operands[1] == 32:
            types[operands[0]] = 'scalar'
        elif opcode == 22 and len(operands) == 2 and operands[1] == 32:
            types[operands[0]] = 'scalar'
        elif opcode == 71 and len(operands) >= 2 and operands[1] == 1:
            if len(operands) != 3 or operands[0] in decorations:
                raise ValueError('specialization malformed SpecId decoration')
            decorations[operands[0]] = operands[2]
        elif opcode in (48, 49, 50):
            if len(operands) != (3 if opcode == 50 else 2):
                raise ValueError('specialization malformed scalar constant')
            targets.add(operands[1])
        position += count
    if not decorations.keys() <= targets or len(set(decorations.values())) != len(decorations):
        raise ValueError('specialization SpecId does not identify a unique scalar')
    result = list(words[:5])
    for opcode, operands in instructions:
        if opcode == 71 and len(operands) >= 2 and operands[1] == 1:
            continue
        if opcode in (48, 49, 50):
            kind = types.get(operands[0])
            if kind != ('scalar' if opcode == 50 else 'bool'):
                raise ValueError('specialization scalar type exceeds profile')
            value = values.get(decorations.get(operands[1]))
            if value is not None and len(value) != 4:
                raise ValueError('specialization value size does not match scalar type')
            if opcode == 50:
                opcode = 43
                if value is not None:
                    operands = (*operands[:2], int.from_bytes(value, 'little'))
            else:
                truth = opcode == 48 if value is None else bool(int.from_bytes(value, 'little'))
                opcode = 41 if truth else 42
        elif opcode == 51:
            opcode = 44
        result.extend(((len(operands) + 1) << 16 | opcode, *operands))
    if any(opcode == 52 for opcode, _ in instructions):
        try:
            scan = Scanner(result, native_spec_ops=True).scan()
        except (Fault, IndexError, AssertionError, RecursionError) as error:
            raise ValueError('specialization constant operations exceed profile') from error
        folded, position = list(result[:5]), 5
        while position < len(result):
            count, opcode = result[position] >> 16, result[position] & 0xFFFF
            if opcode == 52:
                rty, rid = result[position + 1:position + 3]
                value = scan.consts[rid][0]
                if scan.types[rty]['kind'] == TK['BOOL']:
                    folded.extend((3 << 16 | (41 if value else 42), rty, rid))
                else:
                    folded.extend((4 << 16 | 43, rty, rid, value))
            else:
                folded.extend(result[position:position + count])
            position += count
        return tuple(folded)
    return tuple(result)
