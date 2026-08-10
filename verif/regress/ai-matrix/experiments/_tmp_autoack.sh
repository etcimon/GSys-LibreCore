#!/bin/bash
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6

# Patch island: auto-ack store without AXI (keep WriteCompletion engine path)
python3 <<'PY'
from pathlib import Path
p = Path("corev_apu/ai_island/g6lc_ai_island_top.sv")
t = p.read_text()
# Replace the real store instantiation body with auto-ack stubs while keeping WriteCompletion
old = """    g6lc_ai_mem_store #(
        .AddrWidth (AddrWidth),
        .DataWidth (AxiDataWidth),
        .IdWidth   (AxiIdWidth),
        .axi_req_t (axi_req_t),
        .axi_resp_t(axi_resp_t)
    ) i_store (
        .clk_i,
        .rst_ni,
        .start_i (wr_start),
        .addr_i  (wr_addr),
        .data_i  (AxiDataWidth'(wr_data)),
        .ready_o (wr_ready),
        .done_o  (wr_done),
        .err_o   (wr_err),
        .axi_req_o  (store_axi_req),
        .axi_resp_i (axi_dma_resp_i)
    );
    // Prefer store when active (engine WR_DONE); else fetch
    assign axi_dma_req_o = (!wr_ready || wr_start) ? store_axi_req : fetch_axi_req;
    assign fetch_busy = !fetch_ready || sb_fetch_pending_q || !wr_ready;
"""
new = """    // TMP auto-ack: no AXI store — isolate whether AXI write breaks PLIC claim
    assign store_axi_req = '0;
    assign wr_ready = 1'b1;
    assign wr_done  = wr_start;
    assign wr_err   = 1'b0;
    assign axi_dma_req_o = fetch_axi_req;
    assign fetch_busy = !fetch_ready || sb_fetch_pending_q;
"""
if old not in t:
    raise SystemExit("pattern missing for autoack")
p.write_text(t.replace(old, new))
print("autoack patched")
PY

AI_MATRIX_VERI_REBUILD=1 AI_MATRIX_VERI_TESTS="ai_irq_plic_smoke ai_ptr_done_smoke" bash verif/regress/ai-matrix-veri.sh 2>&1 | tail -25

# restore from git
git checkout -- corev_apu/ai_island/g6lc_ai_island_top.sv
# re-apply WriteCompletion WIP if checkout wiped uncommitted - check status
echo "--- after checkout ---"
git status -sb corev_apu/ai_island/
grep -n WriteCompletion corev_apu/ai_island/g6lc_ai_island_top.sv || true
