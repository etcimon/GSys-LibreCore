# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Extract the real PMP write banks into hash-pinned private leaf closures."""
import hashlib
import json
from pathlib import Path
import shutil
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
TARGET = ROOT / "build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/csr_regfile.sv"
START = b"  always_comb begin : csr_wr_pmp"
END = b"  always_comb begin : csr_wr_acc"
OLD_LOCK = b"!(pmpcfg_q[pmp_index+1].locked &&"
BOUND_LOCK = b"!(pmp_index < 12'd63 && pmpcfg_q[pmp_index+1].locked &&"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def split(data):
    assert data.count(START) == data.count(END) == 1
    a, b = data.index(START), data.index(END)
    return data[:a], data[a:b], data[b:], [a, b]


def wrapper(name, bank, notice, conversion):
    header = f"""module g6lc_hyp8_pmp_bank_{name} #(
    parameter int unsigned XLEN = 64,
    parameter int unsigned PLEN = 56
) (
    input logic csr_we,
    input logic vs_mode,
    input logic [11:0] addr,
    input logic [XLEN-1:0] csr_wdata,
    input riscv::pmpcfg_t [63:0] pmpcfg_q,
    input logic [63:0][PLEN-3:0] pmpaddr_q,
    output riscv::pmpcfg_t [63:0] pmpcfg_w,
    output logic [63:0][PLEN-3:0] pmpaddr_w,
    output logic bk_wr_pmp_uae,
    output logic bk_wr_pmp_vuae,
    output logic bk_wr_pmp_flush,
    output logic bk_wr_pmp_dfsc
);
  typedef struct packed {{
    int unsigned XLEN;
    int unsigned PLEN;
    bit IS_XLEN64;
    bit RVH;
  }} cfg_t;
  localparam cfg_t G6LCCfg =
      '{{XLEN: 32'(XLEN), PLEN: 32'(PLEN),
         IS_XLEN64: 1'(XLEN == 64), RVH: 1'b1}};
  riscv::csr_t csr_addr, conv_csr_addr;
  logic [11:0] req_addr;
  logic v_q;
  assign req_addr = addr;
  assign v_q = vs_mode;
"""
    return notice + header.encode() + conversion + bank + b"\nendmodule\n"


def main():
    out = Path(sys.argv[1]).resolve()
    assert out.is_relative_to(ROOT / "build-platform/workspace/build")
    assert not out.exists(), "use a fresh snapshot directory"
    before = (HERE / "pmp-scalar-v50.before.sv").read_bytes()
    after = TARGET.read_bytes()
    bp, bb, bs, br = split(before)
    ap, ab, ass, ar = split(after)
    # Only the bank and the explicit entry63 correction may differ.
    assert bp == ap
    assert bs.count(OLD_LOCK) == ass.count(BOUND_LOCK) == 1
    # The editor removes one blank line at EOF; all other outside-bank bytes
    # must match, including line endings and the complete owner/apply logic.
    assert bs.replace(OLD_LOCK, BOUND_LOCK).rstrip(b"\r\n") == ass.rstrip(b"\r\n")
    assert bb.count(OLD_LOCK) == 1
    ref = bb.replace(OLD_LOCK, BOUND_LOCK)
    negative = len(sys.argv) > 2 and sys.argv[2] == "--negative"
    assert len(sys.argv) == (3 if negative else 2)
    if negative:
        needle = b"pmpaddr_w[pmp_index] = csr_wdata[G6LCCfg.PLEN-3:0];"
        assert ref.count(needle) == 1
        ref = ref.replace(needle, b"pmpaddr_w[pmp_index] = '0;")
    notice = before[:before.index(b"module csr_regfile")]
    conv_start = b"  logic [11:0] csr_addr12;"
    conv_end = b"  // FP CSR write/read is legal"
    assert before.count(conv_start) == before.count(conv_end) == 1
    cr = [before.index(conv_start), before.index(conv_end)]
    conversion = before[cr[0]:cr[1]]
    out.mkdir(parents=True)
    inputs = {}
    for name, bank, raw, span in [
        ("reference", ref, before, br), ("candidate", ab, after, ar)
    ]:
        data = wrapper(name, bank, notice, conversion)
        path = out / f"g6lc_hyp8_pmp_bank_{name}.sv"
        path.write_bytes(data)
        inputs[name] = dict(source_sha256=sha(raw), span_bytes=span,
                            original_bank_sha256=sha(raw[span[0]:span[1]]),
                            extracted_bank_sha256=sha(bank), wrapper_sha256=sha(data),
                            conversion_span_bytes=cr, conversion_sha256=sha(conversion),
                            negative_mutation=(negative and name == "reference"))
    # Reuse immutable package/header inputs already qualified in c5, checking
    # their original source receipts. The new bench is copied from the workspace.
    base = ROOT / "remote-runs/hyp8-r98-lsq-credit-after-c5/output"
    hashes = json.loads((base / "sources.json").read_text())
    names = [
        "config_pkg.sv", "build_config_pkg.sv", "g6lc_hyp_pkg.sv",
        "g6lc64_hyp8_config_pkg.sv", "riscv_pkg.sv", "g6lc_core_pkg.sv",
        "g6lc_ooo_pkg.sv", "g6lc_core_types.svh", "rvfi_types.svh",
    ]
    for name in names:
        src = base / "source" / name
        data = src.read_bytes()
        if name in hashes:
            assert sha(data) == hashes[name], name
        shutil.copy2(src, out / name)
    shutil.copy2(ROOT / "verif/tb/core/tb_g6lc_hyp8_control.sv", out / "tb_g6lc_hyp8_control.sv")
    (out / "extraction.json").write_text(json.dumps(inputs, indent=2) + "\n")
    files = {p.name: sha(p.read_bytes()) for p in sorted(out.iterdir())}
    (out / "manifest.json").write_text(json.dumps({"files": files}, indent=2) + "\n")
    print(json.dumps(inputs, indent=2))


if __name__ == "__main__":
    main()
