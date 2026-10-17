// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// `timings sta-rtl` study-mapping helpers: the elaborated CVA6Cfg snapshot
// probe, the delay-oriented ABC command, the streamed per-module mapping
// shell, and the manifest file substitution (tc_sram study stub).

import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  cfgProbeSource,
  cfgValuesFromYosysJson,
  cvaCfgIntFields,
} from "../src/tooling/cfgSnapshot.ts";
import { abcCommand, buildMapScript, freshWidthMap, portableSourceHash, streamedPhaseBShell } from "../src/tooling/rtlTiming.ts";

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
  expect(cmd).toContain("+&get,-n;&st;&syn2;&dch,-f;&nf,-D,250;&put");
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
  const b = streamedPhaseBShell({ runDir: "$RUN", liberty: "$LIB", yosysVar: "$YS", periodPs: 800, logVar: "$RUN/synth.log", pullTag: "sta-rtl-x", jobs: 6, abcTimeoutS: 900 }).join("\n");
  // One pass over the RTLIL: per-module files for phase B + the width map.
  expect(b).toContain('rtlil_width_map.py" "$RUN/wordlevel.il" --split-dir "$RUN/il" -o "/opt/testharness/runs/sta-rtl-x/output/width-map.json"');
  // One yosys process per module, in parallel, with ABC fallbacks on timeout;
  // the liberty travels as map_one.sh's own argument (quoted heredoc).
  expect(b).toContain("xargs -0 -n 2 -P 6");
  expect(b).toContain('"$RUN/map_one.sh" "$RUN" "$YS" "$LIB" 900');
  // Driver file: outer variables expand at creation, loop variables stay literal.
  expect(b).toContain('cat > "$RUN/map_all.sh" <<MAP_ALL');
  expect(b).toContain(String.raw`while IFS=\$'\t' read -r i f; do printf "%s\0%s\0" "\$i" "$RUN/il/\$f"; done`);
  expect(b).toContain('bash "$RUN/map_all.sh" > "$RUN/synth-map.log" 2>&1');
  expect(b).toContain('R="$1"; YS="$2"; LIB="$3"; tmo="$4"; idx="$5"; il="$6"');
  expect(b).toContain('timeout "$tmo" "$YS" -q -p "read_rtlil $il; booth; async2sync t:\\$aldff t:\\$aldffe; techmap; opt_clean; dfflibmap -liberty $LIB;');
  // Reruns keep mapped modules of the same RTLIL; an unmappable flop type
  // fails the step.
  expect(b).toContain("_ALDFF_");
  // Both RTLIL and recipe participate: a previously mapped module must be
  // rebuilt when arithmetic lowering or the ABC delay target changes.
  expect(b).toContain('sha=$( { cat "$il"; echo "${MAP_RECIPE_KEY:-}"; } | sha256sum | cut -c1-16)');
  expect(b).toContain('MAP_RECIPE_KEY="map-v2:booth:abc -liberty $LIB -D 800');
  expect(b).toContain('[ "$(cat "$out.sha" 2>/dev/null)" = "$sha" ]');
  expect(b).toContain('echo "$sha" > "$out.sha"; echo "$idx ok delay"');
  // The width map records the live-source hash the host computed.
  const withHash = streamedPhaseBShell({ runDir: "$RUN", liberty: "$LIB", yosysVar: "$YS", periodPs: 800, logVar: "$RUN/synth.log", pullTag: "sta-rtl-x", sourceSha256: "abc123" }).join("\n");
  expect(withHash).toContain('--source-sha256 "abc123" -o "/opt/testharness/runs/sta-rtl-x/output/width-map.json"');
  expect(b).toContain("&nf,-D,800");
  expect(b).toContain('if run "abc -liberty $LIB -D 800"; then echo "$sha" > "$out.sha"; echo "$idx ok plain"');
  expect(b).toContain('if run "abc -liberty $LIB -fast"; then echo "$sha" > "$out.sha"; echo "$idx ok fast"');
  expect(b).toContain("SYNTH_STREAM_FALLBACK");
  expect(b).toContain('cat "$RUN/mapped/"*.v > "$RUN/netlist.v"');
  // A missing module list or an unmapped module is a synth failure, never a
  // silent partial netlist.
  expect(b).toContain('echo "RESULT fail synth"');
  expect(b).toContain('if [ "$(ls "$RUN/mapped"/*.v | wc -l)" != "$(wc -l < "$RUN/il/modules.tsv")" ]');
});

test("a width map whose source hash differs from the portable sources is refused", () => {
  const dir = mkdtempSync(join(tmpdir(), "svt-wm-"));
  const src = join(dir, "a.sv");
  writeFileSync(src, "module a; endmodule\n");
  const portable = join(dir, "portable.f");
  writeFileSync(portable, `+define+SYNTHESIS\n${src.replace(/\\/g, "/")}\n`);
  const hash = portableSourceHash(portable)!;
  expect(hash).toMatch(/^[0-9a-f]{64}$/);
  const map = join(dir, "width-map.json");
  writeFileSync(map, JSON.stringify({ source_sha256: hash, modules: {} }));
  expect(freshWidthMap(map, portable)).toBeDefined();
  writeFileSync(src, "module a; logic x; endmodule\n");
  expect(freshWidthMap(map, portable)).toBeUndefined();
  // A map without the field (older run) cannot prove its tree: refused.
  writeFileSync(map, JSON.stringify({ modules: {} }));
  expect(freshWidthMap(map, portable)).toBeUndefined();
  rmSync(dir, { recursive: true, force: true });
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
