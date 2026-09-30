# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import sys
import zipfile


SOURCES = (
    "axi_pkg.sv", "axi_intf.sv", "config_pkg.sv", "g6lc_ai_island_cfg_pkg.sv",
    "g6lc_ai_desc_pkg.sv", "g6lc_ai_fp_pkg.sv", "g6lc_ai_policy_pkg.sv",
    "g6lc_ai_addr_check.sv", "g6lc_ai_cap_window.sv", "g6lc_ai_desc_engine.sv",
    "g6lc_ai_cpl_fifo.sv", "g6lc_ai_policy_codec.sv", "g6lc_ai_policy_subcode.sv",
    "g6lc_ai_policy_steer.sv", "spill_register_flushable.sv", "spill_register.sv",
    "g6lc_ai_axi_cut.sv", "g6lc_ai_inval_queue.sv", "g6lc_ai_island_top.sv", "sim_main.cpp",
)
HEADER_SHA = "dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log, timeout, env=None):
    log.with_suffix(".command.json").write_text(json.dumps(command, indent=2) + "\n")
    with log.open("w") as output:
        try:
            result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT,
                                    timeout=timeout, env=env)
            rc = result.returncode
        except subprocess.TimeoutExpired:
            output.write(f"\nINCOMPLETE: command timed out after {timeout} seconds\n")
            rc = 124
    text = log.read_text(errors="replace")
    print(text[-5000:], flush=True)
    return rc, text


def prepare_dma(destination, backend=False, stripe=False, fifo=False, cmd_fifo=False):
    root = Path(__file__).resolve().parents[3]
    name = "run-dram-stripe.sh" if stripe else ("run-gemm-backend.sh" if backend else "run-desc-island.sh")
    runner = root / "verif/tb/ai_island" / name
    substitutions = {
        "$ROOT": str(root),
        "$CCELLS": str(root / "vendor/pulp-platform/common_cells"),
        "$AXI": str(root / "vendor/pulp-platform/axi"),
    }
    files = {}
    sources = []
    raw_sources = [str(root / "corev_apu/ai_island/g6lc_ai_cpl_fifo.sv"),
                   str(root / "verif/tb/ai_island/tb_g6lc_ai_cpl_fifo.sv")] if fifo else re.findall(r'"([^"\n]+\.sv)"', runner.read_text())
    if cmd_fifo:
        raw_sources = [str(root / path) for path in (
            "vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv",
            "corev_apu/ai_island/g6lc_ai_cmd_fifo.sv", "verif/tb/ai_island/tb_g6lc_ai_cmd_fifo.sv")]
    if cmd_fifo == "enq":
        raw_sources = [str(root / path) for path in (
            "core/include/config_pkg.sv", "core/cvxif_g6lc_ai/include/g6lc_ai_instr_pkg.sv",
            "vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv",
            "core/cvxif_g6lc_ai/g6lc_ai_acc_bank.sv", "core/cvxif_g6lc_ai/g6lc_ai_exec.sv",
            "verif/tb/ai_island/tb_g6lc_ai_enq_ready.sv")]
    for raw in raw_sources:
        for variable, prefix in substitutions.items():
            raw = raw.replace(variable, prefix)
        path = Path(raw)
        if path.name in files or not path.is_file():
            raise RuntimeError("missing or duplicate source: " + raw)
        files[path.name] = path
        sources.append(path.name)
    for name in ("typedef.svh", "assign.svh"):
        files["axi/" + name] = root / "vendor/pulp-platform/axi/include/axi" / name
    for name in ("registers.svh", "assertions.svh"):
        files["common_cells/" + name] = root / "vendor/pulp-platform/common_cells/include/common_cells" / name
    files["run_runtime_repair.py"] = Path(__file__).with_name("run_runtime_repair.py")
    if not (fifo or cmd_fifo):
        files[runner.name] = runner
    manifest = {"sources": sources, "sha256": {name: sha(path) for name, path in files.items()},
                "paths": {name: path.relative_to(root).as_posix() for name, path in files.items()}}
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest, indent=2) + "\n")
        for name, path in files.items():
            archive.write(path, name)
    print(f"SNAPSHOT {destination} files={len(files)} sha256={sha(Path(destination))}")
    return 0


def synthesize_dma(source, out, sources):
    wrapper = out / "dma-synth-top.sv"
    wrapper.write_text('''`include "axi/typedef.svh"
package ai_review_types;
  import g6lc_ai_island_cfg_pkg::*;
  typedef logic [63:0] addr_t;
  typedef logic [63:0] data_t;
  typedef logic [3:0] id_t;
  typedef logic [7:0] strb_t;
  typedef logic [0:0] user_t;
  `AXI_TYPEDEF_ALL(bus, addr_t, id_t, data_t, strb_t, user_t)
  function automatic ai_island_cfg_t make_cfg();
    ai_island_cfg_t c = AiIslandSimChans2;
    c.MacsPerCycle = 8;
    c.AccTileM = 16;
    c.AccTileN = 16;
    c.AccTileK = 64;
    c.CommandDepth = QUEUED_DEPTH;
    return c;
  endfunction
  localparam ai_island_cfg_t Cfg = make_cfg();
endpackage
module g6lc_ai_dma_review (
    input logic clk, rst_n, testmode, req, we,
    input logic [15:0] addr,
    input logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic rvalid, rerror, irq, sb_ready,
    input logic sb_valid,
    input logic [7:0] sb_qid,
    input logic [31:0] sb_ticket,
    input logic [63:0] sb_ptr,
    output logic [31:0] sb_last_ticket,
    output logic [15:0] sb_last_status,
    output logic sb_done,
    input logic dram_init_done,
    output ai_review_types::bus_req_t dma_req,
    input ai_review_types::bus_resp_t dma_resp
);
  g6lc_ai_island_top #(.IslandCfg(AI_REVIEW_ISLAND_CFG), .EnableDmaFetch(1),
      .AxiDataWidth(64), .AxiIdWidth(4),AI_REVIEW_VA_PARAMS
      .axi_req_t(ai_review_types::bus_req_t), .axi_resp_t(ai_review_types::bus_resp_t)) dut (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(testmode),
      .req_i(req), .we_i(we), .addr_i(addr), .wdata_i(wdata),
      .rdata_o(rdata), .rvalid_o(rvalid), .rerror_o(rerror), .irq_o(irq),
      .sb_enq_ready_o(sb_ready), .sb_enq_valid_i(sb_valid), .sb_qid_i(sb_qid), .sb_ticket_i(sb_ticket), .sb_desc_ptr_i(sb_ptr),
      .sb_last_ticket_o(sb_last_ticket), .sb_last_status_o(sb_last_status), .sb_has_completion_o(sb_done),
      .axi_dma_req_o(dma_req), .axi_dma_resp_i(dma_resp), .dram_init_done_i(dram_init_done),
      .dma_inval_valid_o(), .dma_inval_addr_o(), .dma_inval_ready_i(1'b0), .dma_inval_done_i(1'b0),
      .ch_r_beats_i('0), .ch_w_beats_i('0)
  );
endmodule
'''.replace("QUEUED_DEPTH", "2" if os.environ.get("REVIEW_AI_QUEUED") == "1" else "0")
   # REVIEW_AI_VA=1 synthesises the VA-Turbo (reuse) island; REVIEW_AI_SLOTS sets the
   # resident-B directory depth so its area can be compared (1 = single key).
   .replace("AI_REVIEW_VA_PARAMS",
            (" .AiCfg(config_pkg::AiCfgVaTurboTest)," if os.environ.get("REVIEW_AI_VA") == "1" else
             (" .AiCfg(config_pkg::%s)," % os.environ["REVIEW_AI_AICFG"] if os.environ.get("REVIEW_AI_AICFG") else ""))
            + (" .ReuseBSlots(%s)," % os.environ["REVIEW_AI_SLOTS"] if os.environ.get("REVIEW_AI_SLOTS") else ""))
   # REVIEW_AI_ISLAND_CFG names a g6lc_ai_island_cfg_pkg constant for the geometry; the
   # default is the reduced review fixture. AiIslandLatencyDefault + AiCfgIslandFpTest is
   # the live 512-lane FP island (area anchor; synthesis only -- the directed cases assume
   # the reduced geometry).
   .replace("AI_REVIEW_ISLAND_CFG",
            ("g6lc_ai_island_cfg_pkg::" + os.environ["REVIEW_AI_ISLAND_CFG"]) if os.environ.get("REVIEW_AI_ISLAND_CFG")
            else "ai_review_types::Cfg"))
    inputs = " ".join(str(source / name) for name in sources if name.endswith(".sv") and not name.startswith("tb_"))
    script = out / "dma-synth.ys"
    script.write_text("read_slang -I" + str(source) + " --top g6lc_ai_dma_review " + inputs + " " + str(wrapper)
                      + "\nproc\nflatten\nopt -fast\ncheck -assert\nscc -expect 0\nstat\n"
                      + "write_json " + str(out / "dma-synth.json") + "\n")
    rc, _ = run(["/opt/testharness/toolchains/formal/bin/yosys", "-s", str(script)], out / "dma-synth.log", 600)
    if rc:
        return {"status": "FAIL", "rc": rc, "wrapper_sha256": sha(wrapper)}
    cells = json.loads((out / "dma-synth.json").read_text())["modules"]["g6lc_ai_dma_review"]["cells"]
    if not cells or any("latch" in cell["type"].lower() for cell in cells.values()):
        raise RuntimeError("DMA synthesis produced an empty cone or a latch")
    rate_script = out / "rate-synth.ys"
    rate_script.write_text("read_slang -I" + str(source) + " --top g6lc_ai_pmu_rate " + inputs
                           + "\nproc\nflatten\nopt -fast\ncheck -assert\nscc -expect 0\n"
                           + "select -assert-none t:$div t:$mod t:$mul\nstat\nwrite_json " + str(out / "rate-synth.json") + "\n")
    rate_rc, _ = run(["/opt/testharness/toolchains/formal/bin/yosys", "-s", str(rate_script)], out / "rate-synth.log", 120)
    if rate_rc:
        return {"status": "FAIL", "phase": "iterative-rate-structure", "rc": rate_rc}
    rate_cells = json.loads((out / "rate-synth.json").read_text())["modules"]["g6lc_ai_pmu_rate"]["cells"]
    if not rate_cells or any("latch" in cell["type"].lower() for cell in rate_cells.values()):
        raise RuntimeError("rate synthesis produced an empty cone or a latch")
    return {"status": "PASS", "generic_cells": len(cells), "latches": 0, "scc": 0,
            "register_bits": sum(len(cell["connections"].get("Q", [])) for cell in cells.values() if "dff" in cell["type"].lower()),
            "rate_unit": {"generic_cells": len(rate_cells), "div_mod_mul_cells": 0, "latches": 0, "scc": 0},
            "physical_area": False, "wrapper_sha256": sha(wrapper)}


def synthesize_command_fifo(source, out, depth):
    wrapper = out / "command-fifo-synth.sv"
    wrapper.write_text(f'''module command_fifo_review (
    input logic clk_i, rst_ni, testmode_i, push_valid_i, pop_ready_i,
    input logic [127:0] push_data_i,
    output logic push_ready_o, pop_valid_o,
    output logic [127:0] pop_data_o,
    output logic [{max(1, depth.bit_length()) - 1}:0] count_o
);
  g6lc_ai_cmd_fifo #(.Depth({depth})) dut (.*);
endmodule
''')
    script = out / "command-fifo-synth.ys"
    netlist = out / "command-fifo-synth.json"
    script.write_text("read_slang --top command_fifo_review " + str(source / "tc_sram.sv") + " "
                      + str(source / "g6lc_ai_cmd_fifo.sv") + " " + str(wrapper)
                      + "\nproc\nflatten\nopt -fast\ncheck -assert\nscc -expect 0\nstat\nwrite_json " + str(netlist) + "\n")
    rc, _ = run(["/opt/testharness/toolchains/formal/bin/yosys", "-s", str(script)], out / "command-fifo-synth.log", 120)
    if rc:
        return {"status": "FAIL", "rc": rc}
    cells = json.loads(netlist.read_text())["modules"]["command_fifo_review"]["cells"]
    if not cells or any("latch" in cell["type"].lower() for cell in cells.values()):
        raise RuntimeError("command FIFO synthesis produced an empty cone or a latch")
    return {"status": "PASS", "generic_cells": len(cells), "latches": 0, "scc": 0,
            "storage_bits": depth * 128, "sram_latency": 1, "physical_area": False,
            "wrapper_sha256": sha(wrapper)}


def verify_fifo(source, out, depth):
    wrapper = out / "fifo-proof.sv"
    wrapper.write_text(f'''module fifo_proof (
    input logic clk_i, rst_ni, push_i, pop_i, mutant_i,
    input logic [31:0] ticket_i,
    input logic [15:0] status_i,
    input logic irq_i,
    output logic full_swap_seen
);
  localparam int Depth = {depth};
  localparam int CntW = Depth <= 1 ? 1 : $clog2(Depth + 1);
  logic empty_o, full_o, head_irq_o;
  logic [31:0] ticket_o;
  logic [15:0] status_o;
  logic [CntW-1:0] count_o, reference_count;
  logic [48:0] reference_data[Depth];
  logic take_pop, take_push;
  g6lc_ai_cpl_fifo #(.Depth(Depth)) dut (.*);
  assign take_pop = pop_i && reference_count != 0;
  assign take_push = push_i && (32'(reference_count) < Depth || take_pop);
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      reference_count <= '0;
      full_swap_seen <= 1'b0;
      for (int i = 0; i < Depth; i++) reference_data[i] <= '0;
    end else begin
      reference_count <= reference_count + CntW'(take_push) - CntW'(take_pop);
      if (take_pop)
        for (int i = 0; i < Depth - 1; i++) reference_data[i] <= reference_data[i + 1];
      if (take_push) reference_data[reference_count - CntW'(take_pop)] <= {{ticket_i, status_i, irq_i}};
      if (full_o && push_i && pop_i) full_swap_seen <= 1'b1;
    end
  end
  always_comb begin
    if (rst_ni) begin
      assert (count_o == reference_count);
      assert (empty_o == (reference_count == 0));
      assert (full_o == (32'(reference_count) == Depth));
      assert (32'(reference_count) <= Depth);
      assert (32'(dut.wr_q) < Depth && 32'(dut.rd_q) < Depth);
      assert (32'(dut.wr_q) == (32'(dut.rd_q) + 32'(reference_count)) % Depth);
      for (int i = 0; i < Depth; i++)
        if (32'(reference_count) > i)
          assert (49'(dut.mem_q[(32'(dut.rd_q) + i) % Depth]) == reference_data[i]);
      if (reference_count != 0)
        assert ({{ticket_o ^ 32'(mutant_i), status_o, head_irq_o}} == reference_data[0]);
    end
  end
endmodule
''')
    yosys = "/opt/testharness/toolchains/formal/bin/yosys"
    build = out / "fifo-proof-build.ys"
    lowered = out / "fifo-proof.il"
    netlist = out / "fifo-proof.json"
    build.write_text("read_slang --std 1800-2017 --top fifo_proof -DFORMAL " + str(source / "g6lc_ai_cpl_fifo.sv") + " " + str(wrapper)
                     + "\nprep -top fifo_proof\nasync2sync\nchformal -lower\nflatten\nmemory_map\nopt -full\ndffunmap\nopt_clean -purge\ncheck -assert\nscc -expect 0\n"
                     + "write_json " + str(netlist) + "\nwrite_rtlil " + str(lowered) + "\n")
    rc, _ = run([yosys, "-s", str(build)], out / "fifo-proof-build.log", 120)
    if rc:
        return {"status": "FAIL", "phase": "lowering", "rc": rc}
    cells = json.loads(netlist.read_text())["modules"]["fifo_proof"]["cells"]
    assertions = sum(cell["type"] == "$assert" for cell in cells.values())
    if assertions == 0 or any("latch" in cell["type"].lower() for cell in cells.values()):
        raise RuntimeError("FIFO proof lost assertions or inferred a latch")
    steps = depth + 4
    outcomes = {}
    for case, constraints, goal, expect_failure in [
        ("base", "-seq 6 -set rst_ni 1 -set-at 1 rst_ni 0 -set mutant_i 0", "-prove-asserts", False),
        ("induction", "-seq 1 -tempinduct-inductonly -maxsteps 4 -set mutant_i 0", "-prove-asserts", False),
        ("negative", "-seq 4 -set rst_ni 1 -set-at 1 rst_ni 0 -set mutant_i 1", "-prove-asserts", True),
        ("cover", f"-seq {steps} -set rst_ni 1 -set-at 1 rst_ni 0 -set mutant_i 0", "-prove full_swap_seen 0", True),
    ]:
        script = out / ("fifo-" + case + ".ys")
        script.write_text("read_rtlil " + str(lowered) + "\nsat -set-def-inputs " + constraints
                          + " " + goal + " -show-ports -dump_vcd " + str(out / ("fifo-" + case + ".vcd")) + " -verify\n")
        rc, text = run([yosys, "-s", str(script)], out / ("fifo-" + case + ".log"), 600)
        outcomes[case] = {"rc": rc, "passed": (rc != 0 and "proof did fail" in text) if expect_failure
                           else (rc == 0 and "SUCCESS" in text)}
    return {"status": "PASS" if all(item["passed"] for item in outcomes.values()) else "FAIL",
            "depth": depth, "cover_steps": steps, "kind": "base/inductive safety and reached full-swap cover",
            "assertions": assertions, "outcomes": outcomes, "latches": 0, "scc": 0,
            "wrapper_sha256": sha(wrapper), "lowered_sha256": sha(lowered), "physical_area": False}


def main():
    data = Path(os.environ["TH_DATA_DIR"])
    out = Path(os.environ["TH_OUT_DIR"])
    processes = subprocess.check_output(["ps", "-eo", "comm="], text=True).splitlines()
    workers = sum(p.strip() in {"cc1plus", "cc1", "yosys", "verilator_bin"} for p in processes)
    cpus = len(os.sched_getaffinity(0))
    meminfo = dict(line.split(":", 1) for line in Path("/proc/meminfo").read_text().splitlines())
    available_memory = int(meminfo["MemAvailable"].split()[0]) * 1024
    capacity = {"cpus": cpus, "active_build_workers": workers,
                "load": os.getloadavg(), "free_disk": shutil.disk_usage(out).free,
                "available_memory": available_memory}
    (out / "capacity.json").write_text(json.dumps(capacity, indent=2) + "\n")
    if workers >= cpus or available_memory < 4 * 1024**3 or capacity["free_disk"] < 2 * 1024**3:
        (out / "results.json").write_text(json.dumps({"status": "BLOCKED", "capacity": capacity}))
        print("BLOCKED: remote compiler, memory or disk budget is unavailable", flush=True)
        return 75
    source = out / "source"
    source.mkdir()
    hashes = {}
    backend = os.environ.get("REVIEW_AI_BACKEND") == "1"
    stripe = os.environ.get("REVIEW_AI_STRIPE") == "1"
    fifo = os.environ.get("REVIEW_AI_FIFO") == "1"
    cmd_fifo = os.environ.get("REVIEW_AI_COMMAND_FIFO") == "1"
    enq = os.environ.get("REVIEW_AI_ENQ") == "1"
    if sum((backend, stripe, fifo, cmd_fifo, enq)) > 1:
        raise ValueError("select one leaf suite")
    dma = os.environ.get("REVIEW_AI_DMA") == "1" or backend or stripe or fifo or cmd_fifo or enq
    sources = SOURCES
    if dma:
        archives = list(data.glob("*.zip"))
        if len(archives) != 1:
            raise RuntimeError("one closed DMA source archive is required")
        with zipfile.ZipFile(archives[0]) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            sources = tuple(manifest["sources"])
            for name, expected in manifest["sha256"].items():
                relative = Path(name)
                if relative.is_absolute() or ".." in relative.parts or "\\" in name:
                    raise RuntimeError("unsafe archive member")
                destination = source / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(archive.read(name))
                hashes[name] = sha(destination)
                if hashes[name] != expected:
                    raise RuntimeError("source hash mismatch: " + name)
        (out / "input-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    else:
        for name in sources:
            matches = list(data.rglob(name))
            if len(matches) != 1:
                raise RuntimeError(f"expected one uploaded {name}, found {len(matches)}")
            destination = source / name
            shutil.copy2(matches[0], destination)
            hashes[name] = sha(destination)
        shutil.copytree(data / "axi", source / "axi")
        for header in (source / "axi").rglob("*.svh"):
            hashes[header.relative_to(source).as_posix()] = sha(header)
    (out / "sources.json").write_text(json.dumps(hashes, indent=2) + "\n")

    runtime_json = Path(os.environ["REVIEW_RUNTIME_JSON"])
    identity = json.loads(runtime_json.read_text())
    runtime = Path(identity["privateRoot"])
    original_runtime = Path(identity["originalRoot"])
    if sha(original_runtime / "include/verilated_funcs.h") != identity["originalHeaderSha256"]:
        raise RuntimeError("original runtime identity changed")
    if os.environ.get("REVIEW_RESTORE_RUNTIME") == "1" and not runtime.is_dir():
        runtime = out / "runtime"
        shutil.copytree(original_runtime, runtime)
        header = runtime / "include/verilated_funcs.h"
        text = header.read_text()
        for n in range(1, 9):
            old = f"    VL_C_END_(obits, VL_WORDS_I(lsb) + {n});"
            new = f"    for (int i = VL_WORDS_I(lsb) + {n}; i < VL_WORDS_I(obits); ++i) obase[i] = 0;\n    return o;"
            if text.count(old) != 1:
                raise RuntimeError("runtime repair input does not match")
            text = text.replace(old, new)
        header.write_text(text)
        identity["privateRoot"] = str(runtime)
    if identity["fixedHeaderSha256"] != HEADER_SHA or sha(runtime / "include/verilated_funcs.h") != HEADER_SHA:
        raise RuntimeError("unqualified Verilator runtime")
    canary_source = (source if dma else data) / "run_runtime_repair.py"
    canary = out / "constant_canary.cpp"
    canary.write_text(runpy.run_path(str(canary_source))["CANARY"])
    hashes[canary_source.name] = sha(canary_source)
    canaries = []
    for tag, prefix, expected in [("original", original_runtime, 1), ("fixed", runtime, 0)]:
        exe = out / ("canary-" + tag)
        rc, _ = run(["g++", "-std=c++17", "-O2", "-I" + str(prefix / "include"),
                     str(canary), "-o", str(exe)], out / (tag + "-canary-build.log"), 60)
        if rc:
            return rc
        rc, text = run([str(exe)], out / (tag + "-canary.log"), 30)
        canaries.append({"tag": tag, "rc": rc, "output": text})
        if rc != expected:
            raise RuntimeError("runtime canary verdict does not match: " + tag)
    (out / "runtime.json").write_text(json.dumps(identity, indent=2) + "\n")
    (out / "canaries.json").write_text(json.dumps(canaries, indent=2) + "\n")
    (out / "sources.json").write_text(json.dumps(hashes, indent=2) + "\n")
    verilator = shutil.which("verilator")
    if not verilator:
        raise RuntimeError("Verilator missing")
    version = subprocess.check_output([verilator, "--version"], text=True).strip()
    if "Verilator 5.008" not in version:
        raise RuntimeError("this runner requires the qualified 5.008 runtime pair")
    work = out / "model"
    top = "tb_g6lc_ai_desc_island" if dma else "g6lc_ai_island_top"
    mode = ["--main", "--timing", "-GSmallGeometry=1"] if dma else ["--no-timing"]
    if os.environ.get("REVIEW_AI_QUEUED") == "1":
        mode.append("-GQueuedTest=1")
    if backend:
        pipe = int(os.environ.get("REVIEW_AI_DOT_PIPE", "0"))
        channels = int(os.environ.get("REVIEW_AI_CHANNELS", "2"))
        if pipe not in (0, 1) or channels not in (1, 2, 4, 8):
            raise ValueError("unsupported backend test configuration")
        top = "tb_g6lc_ai_gemm_backend"
        mode = ["--main", "--timing", "-GPE_LANES=8", "-GMAX_DIM=64",
                "-GDOT_PIPE_FLOAT=" + str(pipe), "-GNCH=" + str(channels)]
        # Residency axis of the bench (+measure_reuse / +panel_reuse need the reuse blocks).
        if os.environ.get("REVIEW_AI_REUSE") == "1":
            mode.append("-GREUSE_EN=1")
        if os.environ.get("REVIEW_AI_OUT_COLS"):
            mode.append("-GOUT_COLS=" + os.environ["REVIEW_AI_OUT_COLS"])
    if stripe:
        top = "tb_g6lc_ai_dram_stripe"
        mode = ["--main", "--timing"]
    if fifo or cmd_fifo:
        depth = int(os.environ.get("REVIEW_AI_FIFO_DEPTH", "16"))
        if depth not in (1, 2, 3, 4, 16, 64):
            raise ValueError("unsupported FIFO qualification depth")
        top = "tb_g6lc_ai_cmd_fifo" if cmd_fifo else "tb_g6lc_ai_cpl_fifo"
        mode = ["--main", "--timing", "-GDepth=" + str(depth)]
    if enq:
        top = "tb_g6lc_ai_enq_ready"
        # The accumulator bank is one wide tc_sram word (AccElems x 32 b); its byte-enable
        # write loop exceeds Verilator's default unroll budget.
        mode = ["--main", "--timing", "--unroll-count", "4096", "--unroll-stmts", "200000"]
    # -fno-table: the table optimizer re-merges the isolated axi_demux valid blocks into one
    # lookup whose index would again include its own output; it is an optimisation, not a check.
    command = [verilator, "--cc", "--exe", *mode, "--assert", "--threads", "1", "-fno-table",
               "-Wno-fatal", "-Werror-UNOPTFLAT", "-Werror-USERERROR",
               "--top-module", top, "--Mdir", str(work),
               "-I" + str(source), "-CFLAGS", "-std=c++17", "-o", "ai-spine-test",
               *[str(source / name) for name in sources]]
    if dma and not (backend or stripe or fifo or cmd_fifo or enq):
        # The vendor demux wrapper carries whole-struct request/response copies. Splitting
        # them (no RTL edit) lets Verilator check the AXI ready/valid graph per bit; a real
        # bit-level cycle still fails, which the negative probe below re-proves each run.
        vendor_split = out / "axi-vendor-split.vlt"
        # Inside axi_demux, `aw_ready = aw_valid & downstream` feeds the AW control process
        # that also drives `aw_valid`; aw_valid itself never reads aw_ready (lines 193-224).
        # Isolating the valid assignments into their own block removes that process-level
        # false edge only; a genuine bit-level cycle still fails (probe below).
        vendor_split.write_text("`verilator_config\n" + "".join(
            f'split_var -module "axi_demux_intf" -var "{variable}"\n'
            for variable in ("slv_req", "slv_resp", "mst_req", "mst_resp")) +
            'isolate_assignments -module "axi_demux" -var "aw_valid"\n'
            'isolate_assignments -module "axi_demux" -var "ar_valid"\n')
        probe = out / "split-negative.sv"
        probe.write_text("module axi_demux_intf(input logic toggle, output logic seen);\n"
                         "  logic [1:0] slv_req /*verilator split_var*/;\n"
                         "  assign slv_req[0] = slv_req[1] ^ toggle;\n"
                         "  assign slv_req[1] = slv_req[0];\n"
                         "  assign seen = slv_req[0];\nendmodule\n")
        probe_rc, probe_log = run([verilator, "--lint-only", "-Wno-fatal", "-Werror-UNOPTFLAT",
                                   str(vendor_split), str(probe), "--top-module", "axi_demux_intf"],
                                  out / "split-negative.log", 60)
        if probe_rc == 0 or "%Error-UNOPTFLAT" not in probe_log:
            raise RuntimeError("split_var control failed to detect a real bit-level combinational loop")
        command.insert(1, str(vendor_split))
    raw_lint_rc, _ = run(command, out / "verilate.log", 300)
    lint_rc = raw_lint_rc
    split_control = None
    if dma and os.environ.get("REVIEW_AI_SPLIT_AXI") == "1":
        split_control = out / "axi-split.vlt"
        split_control.write_text("`verilator_config\n" + "".join(
            f'split_var -module "{module}" -var "{variable}"\nisolate_assignments -module "{module}" -var "{variable}"\n'
            for module, variables in {
                "g6lc_ai_desc_fetch": ("axi_req_o", "axi_resp_i"),
                "g6lc_ai_mem_store": ("axi_req_o", "axi_resp_i"),
                "g6lc_ai_gemm_seq": ("axi_req_o", "axi_resp_i"),
                "g6lc_ai_island_top": ("axi_dma_req_o", "axi_dma_resp_i", "fetch_axi_req", "store_axi_req", "gemm_axi_req"),
            }.items() for variable in variables) +
            'isolate_assignments -module "axi_demux" -var "*slv_w_ready"\n'
            'isolate_assignments -module "axi_demux" -var "*w_fifo_pop"\n')
        probe = out / "split-negative.sv"
        probe.write_text("module g6lc_ai_desc_fetch(input logic toggle, output logic [1:0] axi_req_o);\n"
                         "assign axi_req_o[0] = axi_req_o[1] ^ toggle;\n"
                         "assign axi_req_o[1] = axi_req_o[0];\nendmodule\n"
                         "module split_probe(input logic toggle, output logic seen);\n"
                         "logic [1:0] bits;\n"
                         "g6lc_ai_desc_fetch dut(.toggle(toggle), .axi_req_o(bits));\n"
                         "assign seen = bits[0] ^ toggle;\nendmodule\n")
        probe_rc, probe_log = run([verilator, "--lint-only", "-Wno-fatal", "-Werror-UNOPTFLAT",
                                   str(split_control), str(probe), "--top-module", "split_probe"],
                                  out / "split-negative.log", 60)
        if probe_rc == 0 or "%Error-UNOPTFLAT" not in probe_log or "%Warning-SPLITVAR" in probe_log:
            raise RuntimeError("type-splitting control failed to detect a real combinational loop")
        command.insert(1, str(split_control))
        lint_rc, _ = run(command, out / "split-verilate.log", 300)
    if os.environ.get("REVIEW_AI_LINT_ONLY") == "1":
        (out / "results.json").write_text(json.dumps({"status": "PASS" if lint_rc == 0 else "FAIL",
            "strict_lint_rc": lint_rc, "raw_lint_rc": raw_lint_rc,
            "split_control_sha256": sha(split_control) if split_control else None,
            "source_sha256": hashes, "scope": "elaboration only; no simulation or synthesis"}, indent=2))
        return lint_rc
    if lint_rc:
        if not dma or os.environ.get("REVIEW_AI_DIAGNOSTIC") != "1":
            return lint_rc
        diagnostic = [arg for arg in command if arg != "-Werror-UNOPTFLAT"]
        rc, _ = run(diagnostic, out / "diagnostic-verilate.log", 300)
        if rc:
            return rc
    env = dict(os.environ, VPATH=str(runtime / "include"))
    command = ["make", "-C", str(work), "-f", "V" + top + ".mk", "-j1",
               "VERILATOR_ROOT=" + str(runtime)]
    rc, _ = run(command, out / "build.log", 600, env)
    if rc:
        return rc
    dependencies = "".join(p.read_text(errors="replace") for p in work.glob("*.d"))
    private = str(runtime / "include/verilated_funcs.h")
    original = str(Path(identity["originalRoot"]) / "include/verilated_funcs.h")
    if private not in dependencies or original in dependencies:
        raise RuntimeError("generated model did not use the qualified runtime")
    binary = work / "ai-spine-test"
    arguments = [value for value in os.environ.get("REVIEW_AI_CASES", "").split(",") if value] if dma else []
    markers = {"review_qid": "PASS DMA_QID checks=4", "review_pmu": "PASS PMU_RATE",
               "review_iterative_pmu": "PASS ITERATIVE_PMU wait=",
               "review_rate_math": "PASS RATE_MATH checks=272",
               "review_queued": "PASS QUEUED checks=21",
               "review_refuse_capacity": "PASS REFUSE_CAPACITY checks=18",
               "review_fetch_capacity": "PASS FETCH_CAPACITY checks=18",
               "review_fetch_identity": "PASS FETCH_IDENTITY checks=2",
               "review_signed": "PASS SIGNED_BACKEND checks=56",
               "review_protocol": "PASS AXI_PROTOCOL stalls=", "review_accumulate": "PASS ACCUMULATE", "review_accumulate_island": "PASS ACCUMULATE_ISLAND checks=12", "review_tile_seq": "PASS TILE_SEQ checks=13",
               "measure": "MEASURE_END runs=", "measure_k": "MEASURE_END runs=",
               "measure_reuse": "MEASURE_END runs=21 formats=7",
               "review_flat": "PASS FLAT_PANEL checks=",
               "review_slots": "PASS SLOTS_BACKEND checks="}
    if any(value not in markers for value in arguments):
        raise ValueError("unknown directed case")
    marker = "PASS g6lc_ai_gemm_backend" if backend else ("PASS tb_g6lc_ai_desc_island" if dma else "*** SUCCESS *** ai-island")
    if stripe:
        marker = "PASS g6lc_ai_dram_stripe"
    if fifo or cmd_fifo:
        marker = ("PASS CMD_FIFO depth=" if cmd_fifo else "PASS CPL_FIFO depth=") + str(depth)
    if enq:
        marker = "PASS ENQ_READY results=21 held=12"
    cases = []
    for case in ["", *arguments]:
        suffix = "-" + case if case else ""
        rc, text = run([str(binary), *(["+" + case] if case else [])], out / ("simulation" + suffix + ".log"),
                       600 if case.startswith("measure") else 60)
        passed = rc == 0 and marker in text and "FAIL " not in text and (not case or markers[case] in text)
        cases.append({"case": case or "baseline", "rc": rc, "passed": passed})
    passed = all(case["passed"] for case in cases)
    rc = 0 if passed else 1
    neg_rc, neg_text = run([str(binary), "+oracle_negative"], out / "negative.log", 60)
    negative_marker = "golden C exp=16,16" if backend else "FAIL oracle negative control"
    negative = neg_rc != 0 and negative_marker in neg_text
    synthesis = None
    if passed and negative and not dma:
        yosys = Path("/opt/testharness/toolchains/formal/bin/yosys")
        if not yosys.is_file():
            raise RuntimeError("qualified synthesis tool is missing")
        script = out / "synth.ys"
        inputs = " ".join(str(source / name) for name in SOURCES if name.endswith(".sv"))
        script.write_text("read_slang -I" + str(source) + " --top g6lc_ai_island_top " + inputs
                          + "\nproc\nflatten\nopt -fast\ncheck -assert\nscc -expect 0\nstat\n"
                          + "write_json " + str(out / "synth.json") + "\n")
        synth_rc, _ = run([str(yosys), "-s", str(script)], out / "synth.log", 300)
        if synth_rc:
            return synth_rc
        cells = json.loads((out / "synth.json").read_text())["modules"]["g6lc_ai_island_top"]["cells"]
        if not cells or any("latch" in cell["type"].lower() for cell in cells.values()):
            raise RuntimeError("synthesis produced an empty cone or a latch")
        synthesis = {"generic_cells": len(cells), "latches": 0, "scc": 0,
                     "physical_area": False}
    if passed and negative and dma and not (backend or stripe or fifo or cmd_fifo or enq) and os.environ.get("REVIEW_AI_DMA_SYNTH") == "1":
        synthesis = synthesize_dma(source, out, sources)
    if passed and negative and cmd_fifo:
        synthesis = synthesize_command_fifo(source, out, depth)
    formal = verify_fifo(source, out, depth) if passed and negative and fifo and os.environ.get("REVIEW_AI_FIFO_FORMAL") == "1" else None
    proof_ok = not formal or formal["status"] == "PASS"
    synth_ok = not synthesis or synthesis.get("status", "PASS") == "PASS"
    record = {"status": "FAIL" if not (passed and negative and synth_ok and proof_ok) else ("INCOMPLETE" if lint_rc else "PASS"),
              "rc": rc, "strict_lint_rc": lint_rc, "raw_lint_rc": raw_lint_rc,
              "split_control_sha256": sha(split_control) if split_control else None,
              "functional_pass": passed and negative,
              "negative_detected": negative, "tool": version, "source_sha256": hashes,
              "synthesis": synthesis, "formal": formal, "runner_sha256": sha(Path(__file__)),
              "runtime_header_sha256": HEADER_SHA, "executable_sha256": sha(binary),
              "scope": ("EnableDmaFetch=1 reduced 8-MAC/16x16x64 descriptor/DMA test; not live throughput or SoC qualification"
                        if dma else "EnableDmaFetch=0 spine; not GEMM, DMA, PMU or full SoC qualification"),
              "arguments": arguments, "cases": cases}
    if stripe:
        record["scope"] = "configuration/stripe/nameplate helpers only; not measured bandwidth or physical qualification"
    if fifo:
        record["scope"] = "completion FIFO leaf depth=" + str(depth) + "; not island admission or physical qualification"
    if cmd_fifo:
        record["scope"] = "registered-SRAM command FIFO leaf depth=" + str(depth) + "; not integrated admission or physical qualification"
    if enq:
        record["scope"] = "core ai.enq/ai.poll producer contract leaf; not CVXIF/SoC integration or full-SoC qualification"
    if backend:
        record["scope"] = "8-lane GEMM backend arithmetic/traffic regression; not live grants or SoC throughput"
        record["dot_pipe"] = pipe
        record["channels"] = channels
    (out / "results.json").write_text(json.dumps(record, indent=2) + "\n")
    return 0 if passed and negative and synth_ok and proof_ok and not lint_rc else 1


if __name__ == "__main__":
    if "TH_DATA_DIR" in os.environ:
        sys.exit(main())
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepare-dma", required=True)
    parser.add_argument("--backend", action="store_true")
    parser.add_argument("--stripe", action="store_true")
    parser.add_argument("--fifo", action="store_true")
    parser.add_argument("--command-fifo", action="store_true")
    parser.add_argument("--enq", action="store_true")
    args = parser.parse_args()
    if sum((args.backend, args.stripe, args.fifo, args.command_fifo, args.enq)) > 1:
        parser.error("select one leaf suite")
    sys.exit(prepare_dma(args.prepare_dma, args.backend, args.stripe, args.fifo,
                         "enq" if args.enq else args.command_fifo))
