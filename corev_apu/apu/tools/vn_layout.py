# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Canonical descriptor layout rows; independent of wire encoding."""


def descriptor_bindings(payload, count):
    """Parse kept binding headers and optional sampler arrays."""
    if not 0 <= count <= 16:
        return None
    bindings = []
    pos = 0
    for _ in range(count):
        if pos + 5 > len(payload):
            return None
        binding, kind, size, flags, ns = payload[pos:pos + 5]
        pos += 5
        if pos + 2 * ns > len(payload) or (ns and (ns != size or kind not in (0, 1))):
            return None
        samplers = [payload[pos + 2 * i] | (payload[pos + 2 * i + 1] << 32)
                    for i in range(ns)]
        bindings.append((binding & 0xFFFF, kind & 0xFF, size & 0xFFFF,
                         flags, samplers))
        pos += 2 * ns
    return sorted(bindings, key=lambda b: b[0]) if pos == len(payload) else None


def descriptor_rows(payload, count):
    """Return rows in binding order, or None for exceeded/invalid row limits."""
    bindings = descriptor_bindings(payload, count)
    if bindings is None:
        return None
    rows = []
    off = ndyn = 0
    previous = None
    for binding, kind, size, _flags, _samplers in bindings:
        dynamic = int(kind in (8, 9))
        if (binding == previous or off + size > 2047 or
                (dynamic and ndyn + size > 16)):
            return None
        rows.append((binding, kind, size, off, dynamic, ndyn))
        off += size
        if dynamic:
            ndyn += size
        previous = binding
    return rows


def descriptor_row_words(row, immutable=False):
    binding, kind, size, off, dynamic, ndyn = row
    return (((binding & 0xFF) << 24) | (kind << 16) | size,
            ((binding >> 8) << 24) | (off << 12) |
            (dynamic << 11) | (int(immutable) << 10) | (ndyn & 0xF))
