#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Diagnostic worker rebuild for the two qualified native62 schedules."""
import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess

from g6lc_mc_pack_ab import sha
from g6lc_sentinel_index import compile_plan, decompose, read_rounds, scenario


ELFS = {"A": "2cfd9c67937b8f3e56872a0550c9418283929dd224b1ce8115c203bcaf250f36",
        "B": "0bca7d503ab7504a760ec91663e24ba2a2716a27b6682318560911c17c226daa"}
WORKER = re.compile(r"\nvoid \w+__Vthread__nba__(\d+)\(void\* voidSelf, bool even_cycle\) \{.*?\n\}", re.S)
HEADER = r"""#include <cstdio>
#include <cstdlib>
#include <ctime>
struct TaskClock {
    unsigned seq = 0, slot = 0, lane, offset;
    bool on = false;
    unsigned tags[512]{};
    unsigned long long ns[512][32][3]{};
    explicit TaskClock(unsigned l) : lane(l), offset(13) {
        if (const char* phase = std::getenv("G6LC_PHASE")) offset = std::atoi(phase);
        if (offset >= 113) std::abort();
    }
    void enter() {
        on = (++seq % 113 == offset);
        if (on) { if (slot == 512) std::abort(); tags[slot] = seq; }
    }
    void mark(unsigned id, unsigned point) {
        if (on) {
            timespec t;
            if (clock_gettime(CLOCK_MONOTONIC_RAW, &t)) std::abort();
            ns[slot][id][point] = 1000000000ULL*t.tv_sec + t.tv_nsec;
        }
    }
    void leave() { if (on) ++slot; }
    ~TaskClock() {
        char name[32]; std::snprintf(name,sizeof(name),"stamp-%u.txt",lane);
        FILE* f = std::fopen(name,"w"); if (!f) std::abort();
        for (unsigned j=0;j<slot;++j) for (unsigned id=1;id<32;++id) {
            const auto* v=ns[j][id];
            if (v[0]) std::fprintf(f,"%u %u %llu %llu %llu\n",tags[j],id,v[0],v[1],v[2]);
        }
        std::fclose(f);
    }
};
"""


def build(src, out, side):
    if sha(src/"Variane_testharness") != ELFS[side]:
        raise ValueError("unexpected executable")
    out.mkdir()
    (out/"task_clock.h").write_text(HEADER)
    seq, pred, objs = {}, {}, []
    log = (src/"build.log").read_text().splitlines()

    def instrument(m):
        lane, body = m[1], m[0]
        ids = list(map(int, re.findall(r"Verilated::mtaskId\((\d+)\);", body)))
        if lane in seq or len(set(ids)) != len(ids) or not all(0 < i < 32 for i in ids):
            raise ValueError("unexpected lane/task numbering")
        seq[lane] = ids
        k, arrived, active = 0, False, False
        lines = []
        for line in body.splitlines():
            if wait := re.search(r"__nba\.wait\(even_cycle, (0x[0-9a-f]+)ULL\);", line):
                if arrived or active: raise ValueError("noncanonical wait")
                mask = int(wait[1], 16)
                pred[ids[k]] = [t for t in range(mask.bit_length()) if mask >> t & 1]
                lines.append(f"    tc.mark({ids[k]},0);")
                arrived = True
            if "Verilated::mtaskId(" in line:
                if active: raise ValueError("missing end of task")
                if not arrived:
                    pred[ids[k]] = []
                    lines.append(f"    tc.mark({ids[k]},0);")
                lines.append(f"    tc.mark({ids[k]},1);")
                active = True
            if line == "}": lines.append("    tc.leave();")
            lines.append(line)
            if line.endswith("bool even_cycle) {"):
                lines.append(f"    static TaskClock tc({lane}); tc.enter();")
            if "Verilated::endOfThreadMTask(" in line:
                if not active: raise ValueError("unexpected end of task")
                lines.append(f"    tc.mark({ids[k]},2);")
                k += 1
                arrived = active = False
        if k != len(ids): raise ValueError("incomplete worker")
        return "\n".join(lines)

    for f in sorted(src.glob("*024root*cpp")):
        text, n = WORKER.subn(instrument, f.read_text())
        if not n: continue
        dst, obj = out/f.name, out/f.with_suffix(".o").name
        dst.write_text('#include "task_clock.h"\n' + text)
        cmd, = [shlex.split(l)[1:] for l in log if l.startswith("ccache ") and l.endswith(" "+f.name)]
        cmd[-1], cmd[cmd.index("-o")+1] = str(dst), str(obj)
        subprocess.run(cmd, cwd=src, check=True)
        objs.append(obj)
    if set(seq) != {"0", "1"} or len(pred) != 30: raise ValueError("unexpected schedule")
    compile_plan(seq, pred)
    archive = "Vg6lc_testharness__ALL.a"
    shutil.copyfile(src/archive, out/archive)
    subprocess.run(["ar", "rs", out/archive, *objs], check=True)
    cmd, = [shlex.split(l) for l in log if l.startswith("/usr/bin/g++-13 ") and
            l.endswith(" -o Variane_testharness")]
    cmd[cmd.index(archive)], cmd[-1] = str(out/archive), str(out/"Variane_testharness")
    subprocess.run(cmd, cwd=src, check=True)
    return dict(seq=seq, pred=pred)


def analyze(run, schedule, side):
    p, t = (30, 29) if side == "A" else (4, 23)
    deps, lanes = schedule["pred"], schedule["seq"]
    if deps[t] != [p]: raise ValueError("edge mismatch")
    plan = compile_plan(lanes, deps)
    rounds = read_rounds(run, lanes)
    totals, earlier = defaultdict(int), defaultdict(int)
    if not rounds: raise ValueError("empty capture")
    for stamps in rounds.values():
        decompose(stamps, deps, plan)
        a, b, _ = stamps[t]
        _, start, end = stamps[p]
        overlap = lambda l, h: max(0, min(b, h)-max(a, l))
        totals["wait"] += b-a
        totals["before"] += max(0, min(b, start)-a)
        totals["body"] += overlap(start, end)
        totals["tail"] += max(0, b-max(a, end))
        for q in lanes["1"]:
            arrival, begin, finish = stamps[q]
            earlier[f"{q}:wait"] += overlap(arrival, begin)
            if q == p: break
            earlier[f"{q}:body"] += overlap(begin, finish)
    if totals["wait"] != sum(totals[k] for k in ("before", "body", "tail")):
        raise ValueError("wait partition mismatch")
    return dict(rounds=len(rounds), first=min(rounds), last=max(rounds), ns=totals,
                earlier_ns=earlier, halve_producer=scenario(schedule, rounds, {p: 0.5}))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for k in ("native", "guest", "output"): ap.add_argument(k, type=Path)
    a = ap.parse_args()
    native, guest, out = (p.resolve() for p in (a.native, a.guest, a.output))
    oracle = json.loads((native/"inputs.json").read_text())
    if sha(guest) != oracle["guest"] or oracle["builds"] != ELFS: ap.error("input mismatch")
    out.mkdir()
    schedules = {s: build(native/s, out/s, s) for s in "AB"}
    (out/"schedules.json").write_text(json.dumps(schedules))
    for i, side in enumerate("ABBA"):
        d = out/f"{i}{side}"
        d.mkdir()
        phase = 13 if i < 2 else 71
        cmd = ["taskset", "-c", "2,4", str(out/side/"Variane_testharness"), "+tohost_addr=0x80001000",
               "+debug_disable", "+quiet_axi", "+rvfi_cycle_stamp", "+max-cycles=80000",
               "+time_out=80000", str(guest)]
        with (d/"log").open("w") as f:
            subprocess.run(cmd, cwd=d, env=dict(os.environ, G6LC_PHASE=str(phase),
                G6LC_METRICS_SIDECAR=str(d/"metrics.json")), stdout=f, stderr=subprocess.STDOUT,
                timeout=900, check=True)
        if (sha(d/"metrics.json") != oracle["metrics"] or
                {f.name: sha(f) for f in d.glob("trace*.dasm")} != oracle["traces"] or
                "*** SUCCESS *** (tohost = 0) after 13431 cycles" not in (d/"log").read_text()):
            raise ValueError("diagnostic trace mismatch")
        result = analyze(d, schedules[side], side)
        expected = range(phase, 39790, 113)
        if (result["first"], result["last"], result["rounds"]) != (
                expected[0], expected[-1], len(expected)):
            raise ValueError("incomplete sample window on pinned guest")
        (d/"qualified.json").write_text(json.dumps(result, indent=2))
        print(i, side, result["rounds"], result["ns"], flush=True)


if __name__ == "__main__":
    main()
