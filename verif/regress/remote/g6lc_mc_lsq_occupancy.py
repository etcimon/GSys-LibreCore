#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Instrument eight reviewed violation-reducer assignments on the frozen tiled Hyp8 build."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

from g6lc_mc_pack_replay import digest


TU = "Vg6lc_testharness_g6lc_core__pi37__DepSet_h7486aa93__852.cpp"
MODEL = "0a717957fba55e06a85cc8b6c51bec32f213023ffeb6817e05f61af311b7a727"
GUEST = "3e6fc73f5a09696cd8a38d10ed76555fff55333a9ea00bc5f847a21c8b495882"
PROBE = r"""
#include <atomic>
#include <cstdio>
namespace {
struct Occupancy {
    std::atomic<unsigned long long> count[8][41]{};
    ~Occupancy() {
        FILE* f = std::fopen("occupancy.tsv", "w");
        if (!f) return;
        for (unsigned i=0; i<8; ++i)
            for (unsigned j=0; j<=40; ++j)
                std::fprintf(f, "%u\t%u\t%llu\n", i, j, count[i][j].load());
        std::fclose(f);
    }
} lsqHistogram;
}
"""


def instrument(text, header, guard=False):
    seen = []
    pattern = (r"^    vlSelf->(\w+__gen_reduce__BRA__(\d+)__KET____DOT__i_vio_red__DOT__)"
               r"win_mask\s*=\s*([^;]+);")

    def site(m):
        i = int(m[2])
        cand = m[1] + "cand"
        age = m[1] + "age_col"
        if (set(re.findall(r"vlSelf->(\w+)", m[3])) != {cand, age}
                or not re.search(r"QData/\*39:0\*/\s+" + cand + ";", header)
                or not text[:m.start()].rstrip().endswith((";", "{", "// Body"))):
            raise ValueError("candidate layout, operands or control flow changed")
        seen.append(i)
        if guard:
            # Qualification of the reviewed emitted form, not a general-purpose
            # C++ matcher: only the eight sites in the pinned, reproduced object.
            return f"    vlSelf->{m[1]}win_mask = vlSelf->{cand} ? ({m[3]}) : 0ULL;"
        return (f"    lsqHistogram.count[{i}][__builtin_popcountll(vlSelf->{cand}"
                f" & 0xffffffffffULL)].fetch_add(1, std::memory_order_relaxed);\n" + m[0])

    result = re.sub(pattern, site, text, flags=re.M)
    if seen != list(range(8)):
        raise ValueError(f"unexpected consumer set: {seen}")
    return result if guard else PROBE + result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for arg in ("model", "tiled", "build_log", "guest", "reference", "new_dir"):
        ap.add_argument(arg, type=Path)
    ap.add_argument("--guard", action="store_true",
                    help="qualify a frozen-model empty-mask guard instead of counting occupancy")
    a = ap.parse_args()
    root, tiled, log, guest, ref, out = (p.resolve() for p in
                                         (a.model, a.tiled, a.build_log, a.guest,
                                          a.reference, a.new_dir))
    out.mkdir()
    binary = "Variane_testharness"
    if digest(tiled / binary) != MODEL or digest(guest) != GUEST:
        raise ValueError("wrong model or guest")
    ids = json.loads((ref.parent / "inputs.json").read_text())
    if ids.get("B") != MODEL or ids.get("elf") != GUEST or not ref.name.endswith("B"):
        raise ValueError("wrong reference run")
    lines = log.read_text().splitlines()
    compile_line, = [s for s in lines if s.startswith("ccache g++ ") and s.endswith(" " + TU)]
    link_line, = [s for s in lines if s.startswith("g++ ") and s.endswith(" -o " + binary)]
    cc = shlex.split(compile_line)[1:]
    link = shlex.split(link_line)
    link[0] = cc[0] = "/usr/bin/g++-13"
    arc, = [s for s in link if s.endswith("__ALL.a")]
    link[link.index(arc)] = str(tiled / arc)
    obj = Path(TU).with_suffix(".o").name
    # Reproduce both the exact linked executable and the selected archive member.
    at = link.index(str(tiled / arc))
    link[-1] = str(out / "control")
    subprocess.run(link, cwd=root, check=True)
    if digest(out / "control") != MODEL:
        raise ValueError("link companions do not reproduce the tiled control")
    member = subprocess.check_output(["ar", "p", str(tiled / arc), obj])
    if not member or hashlib.sha256(member).hexdigest() != digest(root / obj):
        raise ValueError("selected object differs from tiled control")
    # Reproduce the selected object from source before injecting observations.
    cc[cc.index("-o")+1] = str(out / obj)
    subprocess.run(cc, cwd=root, check=True)
    if digest(out / obj) != digest(root / obj):
        raise ValueError("source or compile flags do not reproduce the original object")
    cpp = out / TU
    cpp.write_text(instrument((root/TU).read_text(),
                              (root/"Vg6lc_testharness_g6lc_core__pi37.h").read_text(), a.guard))
    cc[-1] = str(cpp)
    subprocess.run(cc, cwd=root, check=True)
    link.insert(at, str(out / obj))
    link[-1] = str(out / binary)
    subprocess.run(link, cwd=root, check=True)
    with (out / "log").open("w") as stream:
        subprocess.run(["taskset", "-c", "2,4", str(out/binary), "+tohost_addr=0x80001000",
                        "+debug_disable", "+quiet_axi", "+rvfi_cycle_stamp", "+max-cycles=12000",
                        "+time_out=12000", str(guest)], cwd=out, stdout=stream,
                       stderr=subprocess.STDOUT, env=dict(os.environ,
                       G6LC_METRICS_SIDECAR=str(out/"metrics.json")), check=True, timeout=240)
    traces = sorted(p.name for p in ref.glob("trace*.dasm") if p.stat().st_size)
    if (len(traces) != 8 or sorted(p.name for p in out.glob("trace*.dasm")) != traces
            or "*** SUCCESS *** (tohost = 0) after 4649 cycles" not in (out/"log").read_text()
            or any(digest(ref/f) != digest(out/f) for f in [*traces, "metrics.json"])):
        raise ValueError("MC oracle mismatch; do not use these counts")
    result = dict(model=MODEL, candidate=digest(out/binary), guest=GUEST, tu=TU,
                  cycles=4649, reference=str(ref), guarded=a.guard)
    if a.guard:
        (out/"qualified.json").write_text(json.dumps(result, indent=2))
        print("qualified eight guarded consumers; no timing comparison")
        return
    rows = [list(map(int, l.split())) for l in (out/"occupancy.tsv").read_text().splitlines()]
    if [(i,k) for i,k,_ in rows] != [(i,k) for i in range(8) for k in range(41)]:
        raise ValueError("incomplete histogram")
    counts = [[n for site,k,n in rows if site == i] for i in range(8)]
    if not all(map(sum, counts)):
        raise ValueError("unexercised site")
    result.update(site_histograms=counts, loaded_bits=list(map(sum, zip(*counts))))
    (out/"qualified.json").write_text(json.dumps(result, indent=2))
    print("qualified occupancy", result["loaded_bits"], flush=True)


if __name__ == "__main__":
    main()
