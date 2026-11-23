# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Index compiler DFG snapshots, without task, host ISA or trace prerequisites."""
from collections import Counter, defaultdict
from math import isqrt


def transpose_reduction(k, nodes, inputs, users):
    """Identify complete static square-transpose/column-reduction cones, not execution hotness."""
    matrix = nodes[k]
    size = matrix["bits"]
    side = isqrt(size)
    if (not 8 <= side <= 64 or side*side != size or len(users[k]) != side
            or matrix["keep"] or matrix["module_refs"] or matrix["external_refs"]):
        return None
    mask = None
    columns = {}
    for s in users[k]:
        sel = nodes[s]
        if (sel["op"] != "SEL" or sel["bits"] != side or sel["lsb"] % side
                or not 0 <= sel["lsb"] < size or len(users[s]) != 1):
            return None
        a, = users[s]
        if nodes[a]["op"] != "AND" or len(users[a]) != 1 or len(inputs[a]) != 2:
            return None
        r, = users[a]
        other = inputs[a][1] if inputs[a][0] == s else inputs[a][0]
        if (nodes[r]["op"] != "REDOR" or nodes[other]["op"] != "VARPACKED"
                or nodes[other]["bits"] != side or (mask is not None and other != mask)):
            return None
        mask = other
        columns[sel["lsb"]//side] = r
    if len(columns) != side:
        return None
    # Follow only the explicitly recorded drivers of this internal temporary.
    # Verify every destination bit once; sorting by input slot alone is unsound
    # for e.g. 40-bit columns split among 64-bit drivers.
    source = None
    offset = 0
    for _, root, start in sorted(matrix["inputs"], key=lambda t: t[2]):
        if start != offset:
            return None
        stack = [root]
        budget = 2*nodes[root]["bits"]-1
        while stack:
            n = stack.pop()
            node = nodes[n]
            if budget <= 0 or len(users[n]) != 1:
                return None
            budget -= 1
            if node["op"] == "CONCAT":
                stack.extend((inputs[n][0], inputs[n][1]))
                continue
            if (node["op"] != "SEL" or node["bits"] != 1 or offset >= size
                    or node["lsb"] != (offset % side)*side + offset//side):
                return None
            src = inputs[n][0]
            if (nodes[src]["op"] != "VARPACKED" or nodes[src]["bits"] != size
                    or src == k or (source is not None and src != source)):
                return None
            source = src
            offset += 1
        if offset != start + nodes[root]["bits"]:
            return None
    if offset != size:
        return None
    return dict(operation="masked_transpose_reductions", side=side, source=source, mask=mask,
                reduction_vertices=[columns[c] for c in range(side)],
                evidence="static bit map and consumer set only; check SCC and source epoch before fusion")


def dataflow_index(raw):
    nodes = {n["id"]: n for n in raw["vertices"]}
    if len(nodes) != len(raw["vertices"]):
        raise ValueError("duplicate dataflow vertex")
    inputs, users = {}, defaultdict(list)
    for k, n in nodes.items():
        ins = {}
        for slot, src, *_ in n["inputs"]:
            if src not in nodes or slot in ins:
                raise ValueError("unknown source or duplicate operand slot")
            ins[slot] = src
            users[src].append(k)
        inputs[k] = ins

    def describe(k, **attrs):
        n = nodes[k]
        return dict(vertex=k, file=n["file"], line=n["line"], consumers=len(set(users[k])), **attrs)

    regions = []
    for k, n in nodes.items():
        if n["op"] == "VARPACKED" and n["inputs"]:
            candidate = transpose_reduction(k, nodes, inputs, users)
            if candidate:
                regions.append(describe(k, **candidate))
        if n["op"] == "REDOR" and nodes[inputs[k][0]]["op"] == "AND":
            regions.append(describe(k, operation="masked_reduction",
                                    operand_bits=nodes[inputs[k][0]].get("bits")))
        if n["op"] != "CONCAT" or not 2 <= n["bits"] <= 512:
            continue
        if n["bits"] != 8 and users[k] and all(
                nodes[p]["op"] == "CONCAT" and nodes[p]["bits"] <= 512 for p in users[k]):
            continue
        # Visit LSB first. Never traverse variable drivers: a variable may
        # be shared, have partial drivers, or participate in a combinational SCC.
        stack, leaves = [k], []
        shared = False
        budget = 2 * n["bits"] - 1
        while stack and budget:
            budget -= 1
            v = stack.pop()
            node = nodes[v]
            shared |= v != k and len(users[v]) > 1
            if node["op"] == "CONCAT":
                stack.extend((inputs[v][0], inputs[v][1]))
            elif node["op"] == "SEL" and node["bits"] == 1:
                leaves.append((inputs[v][0], node["lsb"]))
            else:
                break
        if len(leaves) != n["bits"] or len({src for src, _ in leaves}) != 1:
            continue
        src = leaves[0][0]
        ix = [i for _, i in leaves]
        if not all(0 <= i < nodes[src]["bits"] for i in ix):
            continue
        steps = {b-a for a, b in zip(ix, ix[1:])}
        probes = []
        if steps == {1}:
            probes.append("contiguous_slice")
        elif ix == sorted(set(ix)) and ix[0] // 64 == ix[-1] // 64:
            probes.append("one_word_pext")
        if steps == {8} and len(ix) in (32, 64):
            probes.append("byte_movemask")
        if len(steps) == 1 and min(steps) >= 32:
            probes.append("strided_column_tile")
        # Static opportunity only. The compiler rechecks the expression in
        # its acyclic component after X handling, independently of this file.
        pack = (len(ix) == 8 and steps == {8} and nodes[src]["op"] == "VARPACKED"
                and nodes[src]["bits"] == 64 and not shared and bool(users[k]))
        regions.append(describe(k, operation="bit_select_concat", source=src,
                                source_bits=nodes[src]["bits"], output_bits=len(ix),
                                first_bit=ix[0], stride=next(iter(steps)) if len(steps) == 1 else None,
                                bit_indices=ix, probe_candidates=probes, pack_byte_plane=pack))
    boundaries = [describe(k, name=n["name"], keep=n["keep"], module_refs=n["module_refs"],
                           external_refs=n["external_refs"], drivers=n["inputs"])
                  for k, n in nodes.items() if "name" in n]
    return dict(schema=1, kind="static-dataflow", module=raw["module"], phase=raw["phase"],
                operations=dict(Counter(n["op"] for n in nodes.values())),
                operand_edges=sum(map(len, inputs.values())), storage=boundaries, regions=regions)
