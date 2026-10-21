#!/usr/bin/env python3
# MIT — build-platform tooling
# Generate hyp_redesign_core_8fo4/core/csr_regfile.sv from the sv-timing emit
# base: wrap the state/read-mux/update logic around the C1..C3 staged CSR
# request pipeline (csr_decode/csr_read/csr_write/csr_trap/csr_irq/
# csr_counters) per the group-10 T1 decision.
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
# upstream identity tokens built from fragments — see rename.py
from rename import L as _L, U as _U, AL as _AL  # noqa: E402

_WS = Path(os.environ.get("HYP_WS") or Path(__file__).resolve().parents[3])
SRC = _WS / "build/sv-timing/hyp8-src/emit/core-8fo4/corrected/core/csr_regfile__svt.sv"
DST = _WS / "hyp/hyp_redesign_core_8fo4/core/csr_regfile.sv"

lines = SRC.read_text(encoding="utf-8").splitlines(keepends=True)

# --- 1-indexed delete/replace ranges in the emit (back-to-front so the
# emit line numbers stay valid) -------------------------------------------
# priv_output comment+block: lines 3460-3502 (through trailing blank)
lines[3459:3502] = []
# exception_ctrl header+block: lines 3413-3442 (through trailing blank)
lines[3412:3442] = []
# csr_op_logic + irq_ctrl_o assigns: lines 3242-3303 (contiguous)
lines[3241:3303] = []
# counter section inside csr_update: lines 1624-1640
lines[1623:1640] = [
    "    // --------------------\n",
    "    // Counters (hyp8: value path split into csr_counters --\n",
    "    // low-half increment + registered carry)\n",
    "    // --------------------\n",
    "    cycle_d         = cycle_incr;\n",
    "    instret_d       = instret_incr;\n",
]

text = "".join(lines)

# --- renames --------------------------------------------------------------
text = text.replace(_AL + "_pkg::", "g6lc_core_pkg::")
text = text.replace("import " + _AL + "_pkg::*", "import g6lc_core_pkg::*")
text = text.replace("config_pkg::" + _L + "_cfg_t", "config_pkg::g6lc_cfg_t")
text = text.replace("config_pkg::" + _L + "_cfg_empty",
                    "config_pkg::g6lc_cfg_empty")
text = re.sub(r"\b" + _U + "Cfg\b", "G6LCCfg", text)
# architectural IDs: new core must not claim the upstream registered
# vendor id (values are 32'd0 in g6lc_core_pkg).
text = text.replace("OPENHWGROUP_MVENDORID", "G6LC_MVENDORID")

# final pass: shared rename map for every residual token in the emit
# (comments, `ifdef names) so regeneration stays idempotent.
from rename import apply_rename  # noqa: E402
text = apply_rename(text)

# port list ends at the first standalone ');' after the header
port_end = text.index("\n);\n")
body = text[port_end:]

# request-context signals now come from the C1-registered record
body = re.sub(r"\bcsr_op_i\b", "req_op", body)
body = re.sub(r"\bcsr_addr_i\b", "req_addr", body)
body = re.sub(r"\bcsr_wdata_i\b", "req_wdata", body)
body = re.sub(r"\bv_i\b", "req_v", body)
body = re.sub(r"\bcsr_read\b", "csr_rd_en", body)
# flush_o decided by csr_update -> flush_req (csr_write registers it +1);
# skip the '.flush_o(' instance-port connection of trigger_module
body = re.sub(r"(?<!\.)flush_o", "flush_req", body)
# the commit-side fflags channel (csr_write_fflags_i) is live: its data
# arrives on csr_wdata_i in the fire cycle, not through the C1 request
body = body.replace(
    "fcsr_d.fflags = req_wdata[4:0] | fcsr_q.fflags;",
    "fcsr_d.fflags = csr_wdata_i[4:0] | fcsr_q.fflags;",
)

text = text[:port_end] + body

# --- port addition: csr_rdata_valid_o (before the closing ');') -----------
text = text.replace(
    "    output logic break_from_trigger_o\n);",
    "    output logic break_from_trigger_o,\n"
    "    // Read-data valid: one cycle after the CSR request presentation - CSR_REGFILE\n"
    "    output logic csr_rdata_valid_o\n);",
)

# --- HypCfg parameter -----------------------------------------------------
text = text.replace(
    "    parameter config_pkg::g6lc_cfg_t G6LCCfg            = config_pkg::g6lc_cfg_empty,\n",
    "    parameter config_pkg::g6lc_cfg_t G6LCCfg            = config_pkg::g6lc_cfg_empty,\n"
    "    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg       = g6lc_hyp_pkg::Hyp8,\n",
)

# --- hyp8 note under the description ---------------------------------------
text = text.replace(
    "// Description: CSR Register File as specified by RISC-V\n",
    "// Description: CSR Register File as specified by RISC-V\n"
    "// hyp8: REWRITTEN wrapper -- C1 request register (csr_decode) -> C2 read\n"
    "// (csr_read RMW) -> C3 registered side-effect request (csr_write);\n"
    "// csr_trap/csr_irq/csr_counters partitions. csr_rdata_o/csr_exception_o\n"
    "// are live on the commit fire cycle; csr_rdata_valid_o is the handshake.\n",
)

# --- wire decls + instance block after the port list ----------------------
inst = """
  // ------------------------------------------------------------------
  // hyp8: C1..C3 staged CSR request pipeline (group-10 split)
  // ------------------------------------------------------------------
  fu_op                                req_op;
  logic [11:0]                         req_addr;
  logic [G6LCCfg.XLEN-1:0]             req_wdata;
  logic [G6LCCfg.TRANS_ID_BITS-1:0]    req_tid;
  logic                                req_v;
  logic                                req_valid;
  logic                                req_rd_valid;
  logic [11:0]                         req_bank;
  logic                                flush_req;
  logic [63:0]                         cycle_incr;
  logic [63:0]                         instret_incr;

  csr_decode #(
      .G6LCCfg(G6LCCfg),
      .HypCfg  (HypCfg)
  ) i_csr_decode (
      .clk_i          (clk_i),
      .rst_ni         (rst_ni),
      .flush_i        (flush_i),
      .csr_op_i       (csr_op_i),
      .csr_addr_i     (csr_addr_i),
      .csr_wdata_i    (csr_wdata_i),
      .commit_tid_i   (commit_instr_i.trans_id),
      .v_i            (v_i),
      .req_op_o       (req_op),
      .req_addr_o     (req_addr),
      .req_wdata_o    (req_wdata),
      .req_tid_o      (req_tid),
      .req_v_o        (req_v),
      .req_valid_o    (req_valid),
      .req_rd_valid_o (req_rd_valid),
      .req_bank_o     (req_bank)
  );

  csr_read #(
      .G6LCCfg(G6LCCfg)
  ) i_csr_read (
      .req_op_i               (req_op),
      .req_wdata_i            (req_wdata),
      .req_valid_i            (req_valid),
      .req_rd_valid_i         (req_rd_valid),
      .rdata_i                (csr_rdata),
      .privilege_violation_i  (privilege_violation),
      .csr_wdata_o            (csr_wdata),
      .csr_we_o               (csr_we),
      .csr_rd_en_o            (csr_rd_en),
      .mret_o                 (mret),
      .sret_o                 (sret),
      .dret_o                 (dret),
      .rdata_valid_o          (csr_rdata_valid_o)
  );

  csr_write #(
      .G6LCCfg(G6LCCfg)
  ) i_csr_write (
      .clk_i       (clk_i),
      .rst_ni      (rst_ni),
      .flush_req_i (flush_req),
      .flush_o     (flush_o)
  );

  csr_trap #(
      .G6LCCfg     (G6LCCfg),
      .exception_t (exception_t)
  ) i_csr_trap (
      .update_access_exception_i         (update_access_exception),
      .read_access_exception_i           (read_access_exception),
      .privilege_violation_i             (privilege_violation),
      .virtual_update_access_exception_i (virtual_update_access_exception),
      .virtual_read_access_exception_i   (virtual_read_access_exception),
      .virtual_privilege_violation_i     (virtual_privilege_violation),
      .mtvec_i            (mtvec_q),
      .stvec_i            (stvec_q),
      .vstvec_i           (vstvec_q),
      .mepc_i             (mepc_q),
      .sepc_i             (sepc_q),
      .vsepc_i            (vsepc_q),
      .dpc_i              (dpc_q),
      .debug_mode_i       (debug_mode_q),
      .v_i                (v_q),
      .trap_to_priv_lvl_i (trap_to_priv_lvl),
      .trap_to_v_i        (trap_to_v),
      .ex_cause_i         (ex_i.cause),
      .sret_i             (sret),
      .dret_i             (dret),
      .csr_exception_o    (csr_exception_o),
      .trap_vector_base_o (trap_vector_base_o),
      .epc_o              (epc_o)
  );

  csr_irq #(
      .G6LCCfg    (G6LCCfg),
      .irq_ctrl_t (irq_ctrl_t)
  ) i_csr_irq (
      .clk_i            (clk_i),
      .rst_ni           (rst_ni),
      .mie_i            (mie_q),
      .mip_i            (mip_q),
      .vsstatus_sie_i   (vsstatus_q.sie),
      .mstatus_sie_i    (mstatus_q.sie),
      .mstatus_mie_i    (mstatus_q.mie),
      .mideleg_i        (mideleg_q),
      .hideleg_i        (hideleg_q),
      .debug_mode_i     (debug_mode_q),
      .dcsr_step_i      (dcsr_q.step),
      .dcsr_stepie_i    (dcsr_q.stepie),
      .priv_lvl_i       (priv_lvl_o),
      .v_i              (v_q),
      .irq_ctrl_o       (irq_ctrl_o)
  );

  csr_counters #(
      .G6LCCfg(G6LCCfg)
  ) i_csr_counters (
      .clk_i            (clk_i),
      .rst_ni           (rst_ni),
      .cycle_i          (cycle_q),
      .instret_i        (instret_q),
      .commit_ack_i     (commit_ack_i),
      .ex_valid_i       (ex_i.valid),
      .debug_mode_i     (debug_mode_q),
      .mcountinhibit_i  (mcountinhibit_q),
      .cycle_o          (cycle_incr),
      .instret_o        (instret_incr)
  );
"""

text = text.replace(
    "    output logic csr_rdata_valid_o\n);",
    "    output logic csr_rdata_valid_o\n);\n" + inst,
)

DST.write_text(text, encoding="utf-8")
print(f"wrote {DST} ({text.count(chr(10))} lines)")

# sanity: no stale request-signal references outside intended sites
for pat in [r"\bcsr_op_i\b", r"\bcsr_addr_i\b", r"\bcsr_wdata_i\b", r"\bv_i\b"]:
    hits = [i + 1 for i, l in enumerate(text.splitlines()) if re.search(pat, l)]
    print(pat, "->", hits[:20])


# keep tools/ free of compiled bytecode (the identity grep covers every
# file type — *.pyc embeds the original source tokens)
def _cleanup_pycache():
    import pathlib as _pl
    import shutil as _sh
    _d = _pl.Path(__file__).resolve().parent
    _sh.rmtree(_d / "__pycache__", ignore_errors=True)
    for _f in _d.glob("*.pyc"):
        try:
            _f.unlink()
        except OSError:
            pass


_cleanup_pycache()
