// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
#include "Vtb_g6lc_ai_desc_formats.h"
#include "verilated.h"
#include <cstdio>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_g6lc_ai_desc_formats top;
    auto tick = [&]() {
        top.clk_i = 0; top.eval();
        top.clk_i = 1; top.eval();
        top.clk_i = 0; top.eval();
    };
    unsigned errors = 0, helpers = 0, engines = 0, starts = 0;
    auto check = [&](bool ok, const char* what) {
        if (!ok && errors++ < 16)
            std::fprintf(stderr, "FAIL %s flags=%08x mask=%04x status=%u gemm_fmt=%u\n",
                         what, top.flags_o, top.mask_i, top.status_o, top.gemm_fmt_o);
    };
    top.rst_ni = 0; tick(); top.rst_ni = 1; tick();
    check(top.enums_ok_o, "core config enum/production mask contract");
    for (unsigned fmt = 0; fmt < 8; ++fmt)
    for (unsigned dtype = 0; dtype < 4; ++dtype)
    for (unsigned acc = 0; acc < 4; ++acc)
    for (unsigned ew = 0; ew < 4; ++ew)
    for (unsigned sparse = 0; sparse < 2; ++sparse) {
        top.fmt_i = fmt; top.dtype_i = dtype; top.accmode_i = acc;
        top.ew_i = ew; top.sparse_i = sparse;
        const unsigned effective = fmt == 0 && ew == 1 ? 1 : fmt;
        const bool legal = !dtype && !acc && !sparse && fmt != 2 && ew < 2 && (fmt < 3 || !ew);
        for (unsigned mask : {1u, 3u, 0xfbu}) {
            top.mask_i = mask; top.eval();
            check(top.raw_fmt_o == fmt, "raw ingest accessor");
            check(bool(top.granted_o) == (legal && (mask & (1u << effective))), "grant helper");
            ++helpers;
        }
        // Full bitmap must not authorize sparse or unsupported arithmetic modes.
        top.mask_i = 0xff; top.eval();
        check(bool(top.granted_o) == legal, "wide-mask legality");
        const bool accepted = legal && (3u & (1u << effective));
        check(top.ready_o, "engine ready");
        top.submit_i = 1; tick(); top.submit_i = 0;
        unsigned kicks = 0, checks = 0;
        for (unsigned cycle = 0; cycle < 24 && !top.done_o; ++cycle) {
            top.eval();
            if (top.gemm_start_o) {
                ++kicks;
                check(top.gemm_fmt_o == effective, "effective GEMM handoff");
            }
            checks += bool(top.check_o);
            tick();
        }
        check(top.done_o, "bounded completion");
        check(top.status_o == (accepted ? 0 : 8), "ST_OK/ST_BAD_FMT");
        check(kicks == unsigned(accepted), "refusal cannot start compute");
        check(accepted || !checks, "refusal before pointer/operand request");
        starts += kicks; ++engines;
        tick();
    }
    top.final();
    if (errors) {
        std::fprintf(stderr, "FAIL desc_formats errors=%u helpers=%u engines=%u\n", errors, helpers, engines);
        return 1;
    }
    std::printf("PASS desc_formats helpers=%u wide_mask=1024 engines=%u starts=%u mask=3 enums=0..7\n",
                helpers, engines, starts);
    return 0;
}
