# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Read-only queued-debug timing evidence; never native authorization or signoff."""
from pathlib import Path

PROBES = {
    "cpu.cpu.debug_mode": "q_debug_active", "debug_req": "q_debug_req",
    "awv": "q_aw_valid", "awr": "q_aw_ready", "awa": "q_aw_addr", "awprot": "q_aw_prot",
    "wv": "q_w_valid", "wr": "q_w_ready", "wd": "q_w_data", "ws": "q_w_strb", "wl": "q_w_last",
    "bv": "q_b_valid", "br": "q_b_ready", "write_addr": "q_write_addr",
    "write_owned": "q_write_owned", "b_pending": "q_b_pending",
}
TRACKED = set(PROBES.values()) | {"clk", "rst_n", "cycles", "hold_started", "hold_finished"}
PROBE = 0x50000000


def require(condition, message):
    if not condition:
        raise ValueError(message)


def snapshots(path):
    """Yield complete timestamp states, retaining only top-level named probes."""
    scopes, symbols, state = [], {}, {}
    started = False
    with Path(path).open(encoding="ascii") as source:
        for line in source:
            fields = line.split()
            if fields[:1] == ["$scope"]:
                scopes.append(fields[2])
            elif fields[:1] == ["$upscope"]:
                scopes.pop()
            elif fields[:1] == ["$var"] and len(scopes) == 1 and fields[4] in TRACKED:
                symbols[fields[3]] = fields[4]
            elif line.startswith("#"):
                if started:
                    yield dict(state)
                started = True
            elif started:
                value, symbol = None, None
                if line.startswith("b") and len(fields) == 2:
                    value, symbol = fields[0][1:], fields[1]
                elif line[:1] in "01xz" and len(line) > 1:
                    value, symbol = line[0], line[1:].strip()
                if symbol in symbols:
                    state[symbols[symbol]] = int(value, 2) if set(value) <= {"0", "1"} else None
    if started:
        yield dict(state)


def analyze_states(states, stage, enabled, privilege=3, *, wrong_live_origin=False):
    require(stage in (1, 2, 3) and privilege in (0, 1, 3), "unsupported queued-debug profile")
    normal_tag = {0: 2, 1: 3, 3: 1}[privilege] if enabled else 0
    previous = None
    offer = aw = w = b = entry = exit_cycle = bound_origin = None
    crossings, hold_edges, request_seen = 0, 0, False
    for current in states:
        if previous is None or not (previous.get("clk") == 0 and current.get("clk") == 1):
            previous = current
            continue
        pre, previous = previous, current
        if pre.get("rst_n") != 1:
            continue
        require(TRACKED <= pre.keys() and TRACKED <= current.keys(), "missing queued-debug observation")
        cycle = pre["cycles"]
        require(cycle is not None, "unknown observation cycle")
        if entry is None and pre["q_debug_req"] == 1:
            request_seen = True
        held = pre["hold_started"] == 1 and pre["hold_finished"] == 0
        if held:
            hold_edges += 1
        if pre["q_aw_valid"] == 1 and pre["q_aw_addr"] == PROBE:
            if offer is None:
                offer = cycle
                bound_origin = pre["q_aw_prot"]
            require(pre["q_aw_prot"] == normal_tag, "firmware AW origin changed")
            if pre["q_aw_ready"] == 1 and aw is None:
                aw = cycle
        if pre["q_w_valid"] == 1 and pre["q_w_ready"] == 1 and pre["q_write_addr"] == PROBE and w is None:
            require(pre["q_w_data"] & 0xffffffff == 0x11 and
                    pre["q_w_strb"] == 0x0f and pre["q_w_last"] == 1, "wrong firmware W payload")
            w = cycle
        if pre["q_b_valid"] == 1 and pre["q_b_ready"] == 1 and pre["q_write_addr"] == PROBE and b is None:
            b = cycle
        pending = held and (
            (stage == 1 and pre["q_aw_valid"] == 1 and pre["q_aw_ready"] == 0 and pre["q_aw_addr"] == PROBE) or
            (stage == 2 and pre["q_w_valid"] == 1 and pre["q_w_ready"] == 0 and pre["q_write_addr"] == PROBE) or
            (stage == 3 and pre["q_b_pending"] == 1 and pre["q_b_valid"] == 0 and pre["q_write_addr"] == PROBE))
        if pre["q_debug_active"] == 0 and current["q_debug_active"] == 1 and entry is None:
            entry = cycle
            if pending:
                crossings += 1
        if current["q_debug_active"] == 1 and pending and wrong_live_origin:
            # Deliberately false oracle: already-issued firmware is not relabeled debug.
            require(bound_origin == 0, "live-origin oracle rejects retained firmware origin")
        if pre["q_debug_active"] == 1 and current["q_debug_active"] == 0:
            exit_cycle = cycle
    require(all(value is not None for value in (offer, aw, w, b, entry, exit_cycle)),
            "missing firmware transaction or debug round trip")
    require(request_seen, "missing external debug request")
    require(offer <= aw <= w <= b and entry < exit_cycle, "invalid transaction/debug ordering")
    require(hold_edges >= 192, "hold interval too short")
    before, after = {1: (offer, aw), 2: (aw, w), 3: (w, b)}[stage]
    classification = "crossed" if crossings == 1 and before < entry < after else "not-crossed"
    return {"classification": classification, "stage": stage, "hold_edges": hold_edges,
            "offer_cycle": offer, "aw_cycle": aw, "w_cycle": w, "b_cycle": b,
            "debug_entry_cycle": entry, "debug_exit_cycle": exit_cycle,
            "normal_origin": normal_tag, "qualification": False}


def analyze(path, stage, enabled, privilege=3, **kwargs):
    return analyze_states(snapshots(path), stage, enabled, privilege, **kwargs)
