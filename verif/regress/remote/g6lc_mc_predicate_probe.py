#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Extract the measured task-25 wake word and benchmark both expressions independently."""
import argparse
from pathlib import Path
import re
import subprocess

from g6lc_pack_generated_rows import ASSIGN
from g6lc_pack_predicates import lower


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("model", type=Path)
    ap.add_argument("output", type=Path)
    args = ap.parse_args()
    tu, = args.model.glob("*__pi37__DepSet_h53a8106c__65.cpp")
    header, = args.model.glob("*_core__pi37.h")
    source = tu.read_text()
    site = next(m for m in ASSIGN.finditer(source) if m[3].endswith("__wk_ok") and m[4] == "0U")
    candidate, hits = lower(site[0], header.read_text())
    if hits != 1:
        raise ValueError("expected a match in the profiled assignment")
    rhs = [site[5], candidate.split(" = ", 1)[1][:-1]]
    names = re.findall(r"vlSelf->(\w+)", rhs[0])
    short = {n: ("lo" if n.endswith("__wk_lo") else "valid" if n.endswith("__xw_v")
                 else "gate" if "__VdfgTmp" in n else None) for n in names}
    if set(short.values()) != {"lo", "valid", "gate"} or len(short) != 3:
        raise ValueError("unexpected MC operands")
    out = args.output.resolve()
    out.mkdir()
    text = """#include <cstdint>
#include <cstdio>
#include <chrono>
using IData = uint32_t; using QData = uint64_t;
struct Input { uint32_t lo[2]; uint64_t valid; uint8_t gate; };
"""
    for fn, expr in zip(("control", "packed"), rhs):
        expr = re.sub(r"vlSelf->(\w+)", lambda m: "s." + short[m[1]], expr)
        text += f"__attribute__((noinline)) uint32_t {fn}(const Input& s) {{return {expr};}}\n"
    text += """
int main(int argc, char**) {
    uint64_t x = 123456789;
    auto next = [&]() { x ^= x << 13; x ^= x >> 7; x ^= x << 17; return x; };
    Input table[512];
    for (unsigned i=0; i<8192; ++i) {
        Input s{{uint32_t(next()),uint32_t(next())},next(),uint8_t(next())};
        uint32_t oracle = 0;
        for (unsigned k=8;k<32;++k) {
            if (((s.valid >> (k-8)) & 1) && !((s.gate & 1) && ((s.lo[0] >> k) & 1)))
                oracle |= uint32_t(1) << k;
        }
        if (control(s)!=oracle || packed(s)!=oracle) return 1;
        table[i%512] = s;
    }
    auto fn = argc > 1 ? packed : control;
    uint64_t h = 0; auto start = std::chrono::steady_clock::now();
    for (unsigned i=0;i<8000000;++i) h += fn(table[i%512]);
    double sec = std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
    std::printf("%.3f M words/s checksum=%llu\\n",8/sec,(unsigned long long)h);
}
"""
    cpp = out / "probe.cpp"
    cpp.write_text(text)
    subprocess.run(["g++-13", "-std=c++17", "-O2", "-march=x86-64-v3", str(cpp),
                    "-o", str(out / "probe")], check=True)
    for i, variant in enumerate("ABBAAB"):
        subprocess.run(["taskset", "-c", "2", "perf", "stat", "-x,", "-o", str(out / f"{i}.perf"),
                        "-e", "instructions:u,cycles:u", str(out / "probe"),
                        *(["packed"] if variant == "B" else [])], check=True)


if __name__ == "__main__":
    main()
