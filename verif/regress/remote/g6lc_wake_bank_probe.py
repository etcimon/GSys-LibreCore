#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Generate a deterministic differential driver from the isolated IQ bank's native port ABI."""
import argparse
from pathlib import Path
import re


def driver(header):
    drive, observe = [], []
    for line in header.splitlines():
        if not re.search(r"\bVL_(IN|OUT)", line):
            continue
        m = re.fullmatch(r"\s*VL_(IN|OUT)(8|16|64|W)?\(&(\w+),(-?\d+),(-?\d+)(?:,(\d+))?\);", line)
        if not m:
            raise ValueError("unsupported model port: " + line)
        direction, kind, name, left, right, words = m.groups()
        if name in ("clk_i", "rst_ni", "flush_i"):
            continue
        width = abs(int(left)-int(right))+1
        count = int(words or 1)
        for j in range(count):
            port = f"m.{name}" + (f"[{j}]" if kind == "W" else "")
            bits = min(32, width-32*j) if kind == "W" else width
            if not 0 < bits <= 64:
                raise ValueError("port width mismatch")
            if direction == "IN":
                drive.append(f"{port} = next() & 0x{(1<<bits)-1:x}ULL;")
            else:
                observe.append(f"hash = (hash ^ {port}) * 1099511628211ULL;")
    if not drive or not observe:
        raise ValueError("no ports to compare")
    return """#include "Vg6lc_iq_bank.h"
#include <chrono>
#include <cstdint>
#include <cstdio>
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vg6lc_iq_bank m;
    uint64_t x = 987654321, hash = 0;
    auto next = [&]() { x ^= x<<13; x ^= x>>7; x ^= x<<17; return x; };
    const unsigned cycles = 60000;
    const auto start = std::chrono::steady_clock::now();
    for (unsigned i=0; i<cycles; ++i) {
        m.rst_ni = i>2;
        m.flush_i = i%251==0;
        """ + "\n        ".join(drive) + """
        for (unsigned clk=0; clk<2; ++clk) {
            m.clk_i=clk; m.eval();
            """ + "\n            ".join(observe) + """
        }
    }
    const double sec=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
    std::printf("%.1f bank cycles/s checksum=%llx\\n",cycles/sec,(unsigned long long)hash);
    m.final();
}
"""


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("header", type=Path)
    ap.add_argument("new_driver", type=Path)
    args = ap.parse_args()
    text = driver(args.header.read_text())
    with args.new_driver.open("x") as out:
        out.write(text)
