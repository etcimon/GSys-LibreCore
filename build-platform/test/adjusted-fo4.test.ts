// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// adjusted-fo4.test.ts — platform FO4 probe inputs, platform auto-detection
// from the fork's test/<p>/<p>.vars, and the fork mirror of the study scripts.

import { expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

import { buildProbe, findInverters, parseProbeOutput, probeNetlist, resolveLibertyLink } from "../src/tooling/fo4Probe.ts";
import { detectOpenroadPlatforms, findOpenroadPlatform, parseTclVars } from "../src/tooling/openroadPlatforms.ts";
import { fo4ProbeShell, platformLiberties, platformLiberty } from "../src/tooling/rtlTiming.ts";

const repoRoot = resolve(import.meta.dir, "..", "..");
const forkRoot = join(repoRoot, "tools", "openroad");
const forkPopulated = existsSync(join(forkRoot, "test", "Nangate45", "Nangate45.vars"));

const LIB = `
library (toy) {
  cell (BUF_X1) {
    area : 0.8;
    pin (A) { direction : input; }
    pin (Z) { direction : output; function : "A"; }
  }
  cell (INV_X2) {
    area : 0.9;
    pin (A) { direction : input; }
    pin (ZN) { direction : output; function : "!A"; }
  }
  cell (CLKINV_X1) {
    area : 0.5;
    pin (A) { direction : input; }
    pin (ZN) { direction : output; function : "(!A)"; }
  }
  cell (INV_X1) {
    area : 0.5
    pin (A) { direction : input; }
    pin (ZN) { direction : output; function : "!A"; }
  }
  cell (DFF_X1) {
    area : 4.0;
    ff (IQ, IQN) { next_state : "D"; clocked_on : "CK"; }
    pin (D) { direction : input; }
    pin (Q) { direction : output; function : "IQ"; }
  }
  cell (NAND2_X1) {
    area : 0.5;
    pin (A1) { direction : input; }
    pin (A2) { direction : input; }
    pin (ZN) { direction : output; function : "!(A1 & A2)"; }
  }
}
`;

test("the liberty scan picks the smallest plain inverter, ignoring flops, buffers and multi-input cells", () => {
  const inv = findInverters(LIB);
  expect(inv.map((i) => i.cell)).toEqual(["INV_X1", "CLKINV_X1", "INV_X2"]);
  expect(inv[0]).toEqual({ cell: "INV_X1", inputPin: "A", outputPin: "ZN", area: 0.5 });
});

test("the probe netlist is two chains with four identical loads on every measured stage", () => {
  const v = probeNetlist({ cell: "INV_X1", inputPin: "A", outputPin: "ZN", area: 0.5 });
  expect(v).toContain("module fo4_probe(a8, y8, a4, y4);");
  // 8 chain stages + 7×3 loads, 4 chain stages + 3×3 loads
  expect((v.match(/INV_X1 c8_u/g) ?? []).length).toBe(8);
  expect((v.match(/INV_X1 c8_l/g) ?? []).length).toBe(21);
  expect((v.match(/INV_X1 c4_u/g) ?? []).length).toBe(4);
  expect((v.match(/INV_X1 c4_l/g) ?? []).length).toBe(9);
  // every internal chain net drives exactly 4 inverter inputs
  for (let i = 1; i < 8; i++) {
    expect((v.match(new RegExp(`\\.A\\(c8_n${i}\\)`, "g")) ?? []).length).toBe(4);
  }
  expect(v).toContain(".A(a8), .ZN(c8_n1)");
  expect(v).toContain(".ZN(y8)");
  const shell = fo4ProbeShell({ runDir: "$RUN", liberty: "$LIB", netlist: v, cell: "INV_X1" });
  expect(shell[0]).toContain("fo4-probe.v");
  expect(shell.join("\n")).toContain("openroad-fo4-probe.tcl");
});

test("the probe line parses and a failure line does not", () => {
  expect(parseProbeOutput("x\nFO4_PROBE ps=23.125 cell=INV_X1 chain8_ns=0.2310 chain4_ns=0.1385\n")).toEqual({
    fo4Ps: 23.125, cell: "INV_X1", chain8Ns: 0.231, chain4Ns: 0.1385,
  });
  expect(parseProbeOutput("FO4_PROBE fail link")).toBeNull();
});

test("tcl vars parse strings, braces and continuations", () => {
  const vars = parseTclVars('set platform "nangate45"\nset extra_lef {}\nset extra_liberty {"a/b.lib" "c/d.lib.gz"}\nset tapcell_args "-distance 120 \\\n  -tapcell_master TAPCELL_X1"\nset site FreePDK45\n');
  expect(vars.get("platform")).toEqual(["nangate45"]);
  expect(vars.get("extra_lef")).toEqual([]);
  expect(vars.get("extra_liberty")).toEqual(["a/b.lib", "c/d.lib.gz"]);
  expect(vars.get("site")).toEqual(["FreePDK45"]);
  expect(vars.get("tapcell_args")?.[0]).toContain("-tapcell_master TAPCELL_X1");
});

test.if(forkPopulated)("the fork's test platforms are auto-detected with their liberty, LEF and probe inverter", () => {
  const platforms = detectOpenroadPlatforms(forkRoot);
  const ids = platforms.map((p) => p.id);
  expect(ids).toContain("nangate45");
  expect(ids).toContain("sky130hd");
  expect(ids).toContain("asap7");
  const n45 = findOpenroadPlatform(forkRoot, "Nangate45")!;
  expect(n45.liberty).toBe("test/Nangate45/Nangate45_typ.lib");
  expect(n45.lefs).toEqual(["test/Nangate45/Nangate45_tech.lef", "test/Nangate45/Nangate45_stdcell.lef"]);
  expect(n45.yosysMappable).toBe(true);
  expect(n45.missing).toEqual([]);
  const asap7 = findOpenroadPlatform(forkRoot, "asap7")!;
  expect(asap7.yosysMappable).toBe(false);
  expect(asap7.staReadable).toBe(true);
  expect(asap7.extraLiberty.length).toBeGreaterThan(0);
  // detection feeds the liberty resolution used by sta-rtl
  expect(platformLiberty("nangate45", forkRoot)).toBe("test/Nangate45/Nangate45_typ.lib");
  expect(platformLiberties("asap7", forkRoot).length).toBe(1 + asap7.extraLiberty.length);
  // the unpopulated fallback table still answers for the mappable three
  expect(platformLiberty("sky130hd")).toBe("test/sky130hd/sky130hd_tt.lib");
  // every sta-readable platform yields a probe inverter (gzip'd asap7 included)
  for (const p of platforms.filter((x) => x.staReadable)) {
    const probe = buildProbe([p.liberty, ...p.extraLiberty].map((l) => join(forkRoot, l)));
    expect("error" in probe ? probe.error : probe.inverter.cell).toMatch(/INV|inv/);
  }
  // the symlink-as-file of a Windows checkout resolves to its target
  const link = join(forkRoot, "test", "sky130hd", "sky130hd_tt.lib");
  expect(resolveLibertyLink(link).endsWith("sky130_fd_sc_hd__tt_025C_1v80.lib")).toBe(true);
});

test.if(forkPopulated)("the fork's g6lc/ mirror of the study scripts is byte-identical to build-platform/scripts", () => {
  for (const name of ["openroad-timing.tcl", "openroad-module-board.tcl", "openroad-module-place-study.tcl", "openroad-fo4-probe.tcl"]) {
    const canonical = readFileSync(join(repoRoot, "build-platform", "scripts", name), "utf8");
    const mirror = join(forkRoot, "g6lc", name);
    expect(existsSync(mirror)).toBe(true);
    expect(readFileSync(mirror, "utf8")).toBe(canonical);
  }
});
