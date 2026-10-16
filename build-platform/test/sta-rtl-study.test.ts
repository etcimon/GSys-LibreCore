// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// `timings sta-rtl` study-mapping helpers: the elaborated CVA6Cfg snapshot
// probe, the delay-oriented ABC command, the streamed per-module mapping
// shell, and the manifest file substitution (tc_sram study stub).

import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import {
  cfgProbeSource,
  cfgValuesFromYosysJson,
  cvaCfgIntFields,
} from "../src/tooling/cfgSnapshot.ts";
import { abcCommand, buildMapScript, streamedPhaseBShell } from "../src/tooling/rtlTiming.ts";

const repoRoot = join(import.meta.dir, "..", "..");

test("cfg snapshot: cva6_cfg_t int/bit fields are parsed from the real config package", () => {
  const text = readFileSync(join(repoRoot, "core", "include", "config_pkg.sv"), "utf8");
  const fields = cvaCfgIntFields(text);
  expect(fields.length).toBeGreaterThan(150);
  for (const f of ["XLEN", "NrHarts", "TRANS_ID_BITS", "INSTR_PER_FETCH", "NR_SB_ENTRIES", "NrCommitPorts"]) {
    expect(fields).toContain(f);
  }
  // Typed fields (enums, logic vectors) are not probed: their width is not a value.
  expect(fields).not.toContain("DCacheType");
  expect(fields).not.toContain("HaltAddress");
  expect(new Set(fields).size).toBe(fields.length);
});

test("cfg snapshot: probe ports encode value+1 and the JSON reader inverts it", () => {
  const src = cfgProbeSource(["XLEN", "NrHarts"], "cva6_config_pkg");
  expect(src).toContain("build_config_pkg::build_config(cva6_config_pkg::cva6_cfg)");
  expect(src).toContain("output logic [CVA6Cfg.XLEN:0] p_XLEN");
  expect(src).toContain("assign p_NrHarts = '0;");
  const json = JSON.stringify({
    modules: {
      g6lc_cfg_probe: {
        ports: {
          p_XLEN: { direction: "output", bits: Array.from({ length: 65 }, (_, i) => i + 2) },
          p_NrHarts: { direction: "output", bits: [67, 68] },
        },
      },
    },
  });
  expect(cfgValuesFromYosysJson(json, ["XLEN", "NrHarts", "Missing"])).toEqual({ XLEN: 64, NrHarts: 1 });
});

test("ABC mapping is delay-oriented and structure-preserving when a period is known", () => {
  expect(abcCommand("lib.lib")).toBe("abc -liberty lib.lib");
  const cmd = abcCommand("lib.lib", 250.4);
  expect(cmd).toContain("-D 250");
  // `&st; &dch -f; &nf -D` keeps the Brent-Kung carry tree; the default
  // liberty script (`dc2; dretime; …`) collapses it to ripple depth.
  expect(cmd).toContain("+&get,-n;&st;&dch,-f;&nf,-D,250;&put");
  expect(cmd.endsWith(";")).toBe(false);
});

test("streamed recipe: phase A dumps RTLIL + module list, phase B maps and evicts per module", () => {
  const a = buildMapScript({
    manifest: "x.f", top: "cva6", liberty: "L", netlist: "n.v", defines: ["SYNTHESIS"], slangArgs: [],
    recipe: "streamed", streamDir: "$RUN", periodPs: 800,
  });
  expect(a).toContain("--best-effort-hierarchy");
  expect(a).not.toContain("flatten");
  expect(a).toContain("opt_dff");
  // techmap is phase B's job: the whole-core gate level never exists at once.
  expect(a).not.toContain("techmap");
  expect(a).toContain("write_rtlil $RUN/wordlevel.il");
  expect(a).toContain("tee -q -o $RUN/modules.txt ls");
  expect(a).not.toContain("abc -liberty");
  const b = streamedPhaseBShell({ runDir: "$RUN", liberty: "$LIB", yosysVar: "$YS", periodPs: 800, logVar: "$RUN/synth.log", pullTag: "sta-rtl-x" }).join("\n");
  expect(b).toContain("rtlil_width_map.py");
  expect(b).toContain("/opt/testharness/runs/sta-rtl-x/output/width-map.json");
  expect(b).toContain("read_rtlil $RUN/wordlevel.il");
  for (const step of ["select %s", "techmap", "dfflibmap -liberty %s", "write_verilog -selected -noattr -noexpr", "select -clear", "delete %s"]) {
    expect(b).toContain(step);
  }
  expect(b).toContain("&nf,-D,800");
  expect(b).toContain('cat "$RUN/mapped/"*.v > "$RUN/netlist.v"');
  // A missing module list is a synth failure, never a silent empty netlist.
  expect(b).toContain('echo "RESULT fail synth"');
});

test("lean recipe keeps the single-process flat mapping", () => {
  const s = buildMapScript({
    manifest: "x.f", top: "cva6", liberty: "L", netlist: "n.v", defines: [], slangArgs: [], periodPs: 250,
  });
  expect(s).toContain("flatten");
  expect(s).toContain("dfflibmap -liberty L");
  expect(s).toContain("abc -liberty L -D 250");
  expect(s).toContain("write_verilog -noattr -noexpr n.v");
});
