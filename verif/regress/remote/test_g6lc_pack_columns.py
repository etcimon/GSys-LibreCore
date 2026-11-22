#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Run the projected C++ against an independent oracle; CXXFLAGS=-mavx2 tests SIMD."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

from g6lc_pack_columns import lower_columns


def main():
    # Unaligned 29-byte stride exercises variable word indices and bit shifts.
    header = "VlWide<228>/*7295:0*/ src; VlWide<16>/*511:0*/ dst;"
    src = "#include <cstdint>\nstruct V { uint32_t src[228],dst[16]; };\nvoid eval(V* vlSelf) {\n"
    for half in range(2):
        if half:
            src += "    vlSelf->src[0U] ^= 0xff000000U;\n"
        for bit in range(8):
            terms = []
            for row in range(32):
                byte = 3 + 29 * row
                shift = byte % 4 * 8 + bit
                terms.append(f"(((vlSelf->src[{byte // 4}U] >> {shift}U) & 1U) << {row}U)")
            src += f"    vlSelf->dst[{half * 8 + bit}U] = " + " | ".join(terms) + ";\n"
    emitted, count = lower_columns(src + "}\n", header)
    assert count == 16 and emitted.count("::gather<") == 2
    # Leave an aliased source/destination alone; the first store can affect later reads.
    alias = src.replace("vlSelf->dst", "vlSelf->src")
    assert lower_columns(alias + "}\n", header)[1] == 0
    main_cpp = """
int main() {
    for (unsigned i = 0; i < 256; ++i) {
        V m{};
        unsigned byte = 3 + 29 * (i / 8);
        m.src[byte / 4] = 1U << (8 * (byte % 4) + i % 8);
        eval(&m);
        for (unsigned b = 0; b < 8; ++b) {
            uint32_t expect = b == i % 8 ? 1U << (i / 8) : 0;
            if (m.dst[b] != expect || m.dst[8+b] != (expect ^ 1U)) return 1;
        }
    }
}
"""
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp)
        (path / "check.cpp").write_text(emitted + main_cpp)
        subprocess.run([os.environ.get("CXX", "c++"), "-std=c++17", "-O2",
                        *shlex.split(os.environ.get("CXXFLAGS", "")),
                        "-I", str(Path(__file__).resolve().parent), "check.cpp", "-o", "check"],
                       cwd=path, check=True)
        subprocess.run([str(path / "check")], check=True)


if __name__ == "__main__":
    main()
