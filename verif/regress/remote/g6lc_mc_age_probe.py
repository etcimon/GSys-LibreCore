# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Benchmark an unmodified contiguous slice of the task-27 age-column producer."""
import argparse
from pathlib import Path
import re
import subprocess

from g6lc_pack_generated_rows import ASSIGN
from g6lc_pack_wrapped_columns import lower_wrapped


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for k in ("model", "output"):
        ap.add_argument(k, type=Path)
    args = ap.parse_args()
    text = next(args.model.glob("*__pi37__DepSet_h53a8106c__113.cpp")).read_text()
    h = next(args.model.glob("*_core__pi37.h")).read_text()
    sites = [m for m in ASSIGN.finditer(text) if m[3].endswith("__age_col")][:10]
    first = sites[0]
    if [int(m[4][:-1], 0) for m in sites] != list(range(10)) or any(
            m[3] != first[3] for m in sites):
        raise ValueError("expected the first eight columns of the 40x40 projection")
    orig = "void control(Model* vlSelf) {\n" + text[first.start():sites[-1].end()] + "\n}\n"
    before = set(re.findall(r"vlSelf->(\w+)", orig))
    if len(before) != 2:
        raise ValueError("unexpected extra state")
    after, count = lower_wrapped(orig, h)
    if count != 10:
        raise ValueError(f"expected ten rewritten words, found {count}")
    out = args.output.resolve()
    out.mkdir()
    cpp = """#include <cstdint>
#include <chrono>
#include <cstdio>
using IData=uint32_t; using QData=uint64_t;
struct Model { uint32_t src[50], dst[50]; };
"""
    for body in (orig, after.replace("void control(", "void tile(")):
        for n in before:
            body = body.replace("vlSelf->"+n, "vlSelf->"+("dst" if n == first[3] else "src"))
        cpp += body.replace("void control(", "__attribute__((noinline)) void control(").replace(
            "void tile(", "__attribute__((noinline)) void tile(")
    cpp += """
int main(int argc,char**) {
    Model m{}; uint64_t h=0;
    for(unsigned b=0;b<1600;++b) {
        m.src[b/32] = 1U<<(b%32);
        for(auto f:{&control,&tile}) {
            f(&m);
            unsigned out=(b%40)*40+b/40;
            for(unsigned j=0;j<10;++j)
                if(m.dst[j]!=(out/32==j?1U<<(out%32):0U)) return 1;
        }
        m.src[b/32]=0;
    }
    auto f=argc>1?tile:control;
    auto start=std::chrono::steady_clock::now();
    for(unsigned i=0;i<2000000;++i) {
        m.src[i%50]+=0x9e3779b9U^i;
        f(&m); h+=m.dst[i%10];
    }
    double s=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
    std::printf("%.3f M batches/s checksum=%llu\\n",2/s,(unsigned long long)h);
}
"""
    (out/"age.cpp").write_text("#include <initializer_list>\n"+cpp)
    subprocess.run(["g++-13", "-std=c++17", "-O2", "-march=x86-64-v3",
                    "-I", str(Path(__file__).resolve().parent), str(out/"age.cpp"),
                    "-o", str(out/"age")], check=True)
    for i, side in enumerate("ABBAAB"):
        subprocess.run(["taskset", "-c", "2", "perf", "stat", "-x,", "-o", str(out/f"{i}.perf"),
                        "-e", "instructions:u,cycles:u", str(out/"age"),
                        *(["tile"] if side == "B" else [])], check=True)


if __name__ == "__main__":
    main()
