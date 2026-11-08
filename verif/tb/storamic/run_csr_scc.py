# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""csr-scc regression: gate-level combinational-loop check on csr_regfile.

Promoted from storamic-cpu41-9d4ea06e (0 SCCs after the csr_update
defaulting fix). Synthesizes csr_regfile alone under the cpu-origin bench
configuration (cv64a6_imafdc_sv39 via cva6_config_pkg) with a thin wrapper
that exposes every port, using the CPU41 no-opt flow
(proc; flatten; techmap; scc). Requires 0 SCCs and 0 latches.

Admission oracle mirrors the queue mutation oracle: a copy of
csr_regfile.sv with the fix textually reverted (drop the `mask = '0;`
default, `automatic logic DirVecOnly;` -> `logic DirVecOnly;`) must show
SCCs > 0."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

CSR_REL = "core/csr_regfile.sv"
SOURCES = [
    "core/csr_regfile.sv", "core/trigger_module.sv",
    "core/include/config_pkg.sv", "core/include/riscv_pkg.sv",
    "core/include/ariane_pkg.sv", "core/include/build_config_pkg.sv",
    "core/include/cv64a6_imafdc_sv39_config_pkg.sv",
    "core/include/triggers_pkg.sv", "core/include/rvfi_types.svh",
]
INC_DIRS = ["core/include"]
DEFINES = ["G6LC_FETCH_B"]

# cva6.sv localparam/parameter type bindings for the cpu-origin bench
# configuration (cva6_config_pkg::cva6_cfg through build_config_pkg).
TYPE_PACKAGE = """\
`include "rvfi_types.svh"
package g6lc_csr_types;
  import ariane_pkg::*;
  localparam config_pkg::cva6_cfg_t C =
      build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
  localparam int unsigned HART_ID_BITS =
      (C.NrHarts <= 1) ? 1 : $clog2(C.NrHarts);
  localparam type exception_t = struct packed {
    logic [C.XLEN-1:0] cause;
    logic [C.XLEN-1:0] tval;
    logic [C.GPLEN-1:0] tval2;
    logic [31:0] tinst;
    logic gva;
    logic valid;
  };
  localparam type branchpredict_sbe_t = struct packed {
    cf_t cf;
    logic [C.VLEN-1:0] predict_address;
    logic ckpt_v;
    logic [7:0] ckpt_idx;
    logic is_call;
    logic is_ret;
  };
  localparam type jvt_t = struct packed {
    logic [C.XLEN-7:0] base;
    logic [5:0] mode;
  };
  localparam type scoreboard_entry_t = struct packed {
    logic [C.VLEN-1:0] pc;
    logic [C.TRANS_ID_BITS-1:0] trans_id;
    fu_t fu;
    fu_op op;
    logic [REG_ADDR_SIZE-1:0] rs1;
    logic [REG_ADDR_SIZE-1:0] rs2;
    logic [REG_ADDR_SIZE-1:0] rd;
    logic [C.XLEN-1:0] result;
    logic valid;
    logic use_imm;
    logic use_zimm;
    logic use_pc;
    exception_t ex;
    branchpredict_sbe_t bp;
    logic is_compressed;
    logic is_macro_instr;
    logic is_last_macro_instr;
    logic is_double_rd_macro_instr;
    logic vfp;
    logic is_zcmt;
    logic [HART_ID_BITS-1:0] hart_id;
    logic [7:0] p_rs1;
    logic [7:0] p_rs2;
    logic [7:0] p_rd;
    logic [7:0] p_frs1;
    logic [7:0] p_frs2;
    logic [7:0] p_frs3;
    logic [7:0] p_frd;
    logic ooo_renamed;
  };
  localparam type irq_ctrl_t = struct packed {
    logic [C.XLEN-1:0] mie;
    logic [C.XLEN-1:0] mip;
    logic [C.XLEN-1:0] mideleg;
    logic [C.XLEN-1:0] hideleg;
    logic sie;
    logic global_enable;
  };
  localparam type rvfi_probes_csr_t = `RVFI_PROBES_CSR_T(C);
endpackage
"""


def _mutate(src, dest):
    """Textually revert the csr_update defaulting fix (old SCC form)."""
    text = src.read_text()
    # The promoted default sits at defaults-block indent (4); the arm-local
    # `mask = '0;` clear inside the MTVEC/MSTATUS cases is pre-existing.
    mask_lines = [l for l in text.splitlines()
                  if re.fullmatch(r"    mask\s*=\s*'0;\s*", l)]
    if len(mask_lines) != 1:
        raise RuntimeError("CSR_SCC_MUTATION_INVENTORY")
    text = text.replace(mask_lines[0] + "\n", "", 1)
    old = "automatic logic DirVecOnly;"
    if text.count(old) != 1:
        raise RuntimeError("CSR_SCC_MUTATION_INVENTORY")
    dest.write_text(text.replace(old, "logic DirVecOnly;", 1))


def _wrapper(csr_text, path):
    head = csr_text.split("module csr_regfile", 1)[1]
    params_at = head.index("#(")
    open_at = head.index(") (", params_at)
    ports = head[open_at + 3:].split("\n);", 1)[0]
    ports = ports.replace("CVA6Cfg", "C")
    path.write_text(
        "// Copyright 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n"
        + TYPE_PACKAGE +
        "module g6lc_csr_scc import ariane_pkg::*; "
        "import g6lc_csr_types::*; (\n" + ports + "\n);\n"
        "csr_regfile #(.CVA6Cfg(C), .exception_t(exception_t), "
        ".jvt_t(jvt_t), .irq_ctrl_t(irq_ctrl_t), "
        ".scoreboard_entry_t(scoreboard_entry_t), "
        ".rvfi_probes_csr_t(rvfi_probes_csr_t)) dut(.*);\nendmodule\n")


def _scc_run(yosys, script, log_path, timeout):
    started = time.monotonic()
    with log_path.open("w") as log:
        result = subprocess.run([str(yosys), "-s", str(script)],
                                stdout=log, stderr=subprocess.STDOUT,
                                timeout=timeout)
    text = log_path.read_text()
    found = re.search(r"Found (\d+) SCCs", text)
    latches = re.findall(r"t:\$dlatch|t:\$_DLATCH_", text)
    return result.returncode, int(found.group(1)) if found else None, \
        text, round(time.monotonic() - started, 1)


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    if "csr-scc" not in stages:
        return
    from yosys_bin import yosys_bin
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    yosys = Path(yosys_bin())
    manifest["yosys"], manifest["yosys_sha256"] = str(yosys), sha(yosys)
    # Rebuild the repo-relative tree (flat data/ uploads by basename).
    tree = out / "csr-src"
    for rel in SOURCES:
        dst = tree / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(data / Path(rel).name, dst)
    csr = tree / CSR_REL
    wrapper = out / "g6lc_csr_scc.sv"
    _wrapper(csr.read_text(), wrapper)
    mutant = out / "csr_regfile_mutant.sv"
    _mutate(csr, mutant)
    tree_mut = out / "csr-src-mutant"
    shutil.copytree(tree, tree_mut)
    shutil.copyfile(mutant, tree_mut / CSR_REL)
    incs = " ".join("-I" + str(tree / d) for d in INC_DIRS)
    defs = " ".join("-D" + d for d in DEFINES)
    prelude = ("read_slang --std 1800-2017 --threads 4 --top g6lc_csr_scc " +
               incs + " " + defs + " ")
    tail = ("\nhierarchy -check -top g6lc_csr_scc\nproc\nflatten\ntechmap\n"
            "check -assert\n"
            "select -assert-none t:$dlatch t:$_DLATCH_*\n")
    # The admission oracle reintroduces latch-like feedback; check -assert
    # legitimately reports the resulting loop artifacts there, so the mutant
    # flow keeps plain `check` (report-only) and relies on `scc` for the count.
    tail_mut = tail.replace("check -assert", "check")
    # (a) production: require 0 SCCs
    script = out / "csr-scc.ys"
    script.write_text(prelude + " ".join(
        [str(tree / rel) for rel in SOURCES if not rel.endswith(".svh")]
        + [str(wrapper)]) + tail + "scc -expect 0\n")
    rc, sccs, text, seconds = _scc_run(yosys, script,
                                     out / "csr-scc.log", 900)
    if rc != 0 or sccs != 0:
        raise RuntimeError(f"CSR_SCC_PRODUCTION sccs={sccs} rc={rc}")
    outcomes.append({"csr_scc": "production", "sccs": 0, "latches": 0,
                     "seconds": seconds, "pass": True})
    # (b) admission oracle: reverted fix must show SCCs > 0
    script_mut = out / "csr-scc-mutant.ys"
    script_mut.write_text(prelude + " ".join(
        [str(tree_mut / rel) for rel in SOURCES if not rel.endswith(".svh")]
        + [str(wrapper)]) + tail_mut + "scc\n")
    rc, sccs, text, seconds = _scc_run(yosys, script_mut,
                                     out / "csr-scc-mutant.log", 900)
    if rc != 0 or not sccs:
        raise RuntimeError(f"CSR_SCC_MUTATION_ORACLE sccs={sccs} rc={rc}")
    outcomes.append({"csr_scc": "admission-mutant", "sccs": sccs,
                     "seconds": seconds, "pass": True})
    manifest["csr_scc_generated"] = {
        str(p): sha(p) for p in (wrapper, mutant, script, script_mut)}
