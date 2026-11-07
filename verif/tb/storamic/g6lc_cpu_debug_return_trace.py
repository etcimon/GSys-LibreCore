# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Read-only debug-write ownership across actual DRET; not native qualification."""
from g6lc_cpu_debug_queue_trace import snapshots, TRACKED, require

TARGET = 0x5000001c


def analyze_states(states, enabled, privilege=3, *, wrong_live_origin=False):
    require(privilege in (0, 1, 3), "invalid return privilege")
    live_tag = {0: 2, 1: 3, 3: 1}[privilege] if enabled else 0
    previous = None
    entry = exit_cycle = aw = w = b = resumed = None
    held_edges, exit_pending, request_seen = 0, False, False
    bound = None
    for current in states:
        if previous is None or not (previous.get("clk") == 0 and current.get("clk") == 1):
            previous = current
            continue
        pre, previous = previous, current
        if pre.get("rst_n") != 1:
            continue
        require(TRACKED <= pre.keys() and TRACKED <= current.keys(), "missing return observation")
        cycle = pre["cycles"]
        if entry is None and pre["q_debug_req"] == 1:
            request_seen = True
        if pre["q_debug_active"] == 0 and current["q_debug_active"] == 1 and entry is None:
            entry = cycle
        held = pre["hold_started"] == 1 and pre["hold_finished"] == 0
        held_edges += int(held)
        pending = held and pre["q_b_pending"] == 1 and pre["q_b_valid"] == 0 and pre["q_write_addr"] == TARGET
        if pre["q_aw_valid"] == 1 and pre["q_aw_addr"] == TARGET:
            require(pre["q_aw_prot"] == 0, "debug write was relabeled trusted")
            if pre["q_aw_ready"] == 1 and aw is None:
                require(pre["q_debug_active"] == 1, "target write not issued in debug")
                aw, bound = cycle, pre["q_aw_prot"]
        if pre["q_w_valid"] == pre["q_w_ready"] == 1 and pre["q_write_addr"] == TARGET and w is None:
            require(pre["q_w_strb"] == 0xf0 and pre["q_w_last"] == 1 and
                    (pre["q_w_data"] >> 32) & 0xffffffff == 0x66, "wrong return write payload")
            w = cycle
        if pre["q_b_valid"] == pre["q_b_ready"] == 1 and pre["q_write_addr"] == TARGET and b is None:
            b = cycle
        if pre["q_debug_active"] == 1 and current["q_debug_active"] == 0:
            exit_cycle = cycle
            exit_pending = pending
        if pending and current["q_debug_active"] == 0 and wrong_live_origin:
            require(bound == live_tag, "live-return oracle rejects debug transaction relabeling")
        if pre["q_aw_valid"] == pre["q_aw_ready"] == 1 and pre["q_aw_addr"] == 0x50000020:
            require(pre["q_debug_active"] == 0 and pre["q_aw_prot"] == live_tag, "wrong resumed origin")
            resumed = cycle
    require(request_seen and all(v is not None for v in (entry, exit_cycle, aw, w, b, resumed)),
            "missing real debug return transaction")
    require(entry < aw <= w <= b and entry < exit_cycle < resumed, "invalid debug return ordering")
    require(held_edges == 384, "wrong return hold interval")
    classification = "crossed" if exit_pending and w < exit_cycle < b else "not-crossed"
    return {"classification": classification, "entry_cycle": entry, "exit_cycle": exit_cycle,
            "aw_cycle": aw, "w_cycle": w, "b_cycle": b, "resumed_cycle": resumed,
            "held_edges": held_edges, "bound_debug_origin": bound, "resumed_origin": live_tag,
            "qualification": False}


def analyze(path, enabled, privilege=3, **kwargs):
    return analyze_states(snapshots(path), enabled, privilege, **kwargs)
