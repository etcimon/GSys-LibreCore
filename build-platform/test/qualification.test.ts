// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import { expect, test } from "bun:test";
import { DEFAULT_CONFIG } from "../src/config/defaults.ts";
import { validateConfig } from "../src/config/load.ts";
import { selectQualification, validateSuiteEvidence, evidenceIdentityFromManifest } from "../src/tests/runner.ts";
import { createHash } from "node:crypto";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs, type FlagValue } from "../src/cli/args.ts";
import { gateVerdict, verifyCommand } from "../src/cli/commands/verify.ts";
import type { PlatformContext } from "../src/context.ts";
import { Logger } from "../src/util/log.ts";
import { hasBinary } from "../src/platform/exec.ts";

const expected = {
  suite: "stream8-smoke",
  target: "g6lc64_stream8",
  top: "ariane_testharness",
  kind: "rtl-cluster" as const,
  runId: "run-current",
  sourceSha256: "1".repeat(64),
  configSha256: "2".repeat(64),
  executableSha256: "3".repeat(64),
};

function output(delta: Record<string, unknown> = {}): string {
  return `G6LC_EVIDENCE ${JSON.stringify({ schemaVersion: 1, ...expected, execution: "remote-proxy", status: "pass", checks: 12, ...delta })}\n`;
}

function config() {
  return {
    ...DEFAULT_CONFIG,
    tests: {
      ...DEFAULT_CONFIG.tests,
      suites: DEFAULT_CONFIG.tests.suites.map((suite) => ({ ...suite, execution: "remote-proxy" as const })),
    },
    verify: {
      ...DEFAULT_CONFIG.verify,
      qualifications: {
        "perf-foundation": {
          targets: {
            g6lc64_stream8: [{ suite: "stream8-smoke", kind: "rtl-cluster" as const, top: "ariane_testharness", buildManifest: "remote-runs/stream8/build-manifest.json" }],
            g6lc64_smt2: [{ suite: "soft-ladder-osbi", kind: "rtl-core" as const, top: "ariane_testharness", buildManifest: "remote-runs/smt2/build-manifest.json" }],
          },
        },
      },
    },
  };
}

test("qualification option consumes its profile argument", () => {
  const args = parseArgs(["verify", "--sim", "--qualification", "perf-foundation", "--target", "g6lc64_stream8"]);
  expect(args.flags.qualification).toBe("perf-foundation");
  expect(args.positionals).toEqual([]);
});

test("a skipped stage cannot report a passed gate", () => {
  const step = (status: "pass" | "skip" | "fail") =>
    ({ stage: "sim" as const, target: "t", status, detail: "", durationMs: 0 });
  const opts = { dryRun: false, allowSkips: false, qualified: false };
  expect(gateVerdict([step("pass"), step("pass")], opts).code).toBe(0);
  expect(gateVerdict([step("pass"), step("fail")], opts).code).toBe(1);
  // A failure outranks a skip, and a skip outranks a pass.
  expect(gateVerdict([step("skip"), step("fail")], opts).code).toBe(1);
  const incomplete = gateVerdict([step("pass"), step("skip")], opts);
  expect(incomplete.code).toBe(4);
  expect(incomplete.message).not.toContain("Gate passed");
  expect(gateVerdict([step("pass"), step("skip")], { ...opts, allowSkips: true }).code).toBe(0);
  // A dry run executes nothing, so it never claims a gate result.
  const dry = gateVerdict([step("skip")], { ...opts, dryRun: true });
  expect(dry.code).toBe(0);
  expect(dry.message).toContain("not a gate result");
  expect(gateVerdict([step("pass")], { ...opts, qualified: true }).message).toContain("qualified");
});

test("qualification refuses unsafe CLI combinations before tool provisioning", async () => {
  const logger = new Logger({ level: "silent" });
  const ctx = { config: config(), logger, dryRun: false } as unknown as PlatformContext;
  const flagSets: Record<string, FlagValue>[] = [
    { qualification: "missing", sim: true },
    { qualification: "perf-foundation" },
    { qualification: "perf-foundation", sim: true, lint: true },
    { qualification: true, sim: true },
    { qualification: "perf-foundation", sim: true, target: "unknown" },
  ];
  for (const flags of flagSets) {
    expect(await verifyCommand.run({ ctx, logger, positionals: [], flags })).toBe(2);
  }
});

test("qualification selects the requested target, not default simulation suites", () => {
  const selected = selectQualification(config(), "perf-foundation", "g6lc64_stream8");
  expect(selected.map((s) => [s.target, s.suite.id])).toEqual([["g6lc64_stream8", "stream8-smoke"]]);
});

test("qualification refuses suites without a declared remote execution path", () => {
  const cfg = config();
  cfg.tests.suites = DEFAULT_CONFIG.tests.suites as typeof cfg.tests.suites;
  expect(() => selectQualification(cfg, "perf-foundation")).toThrow();
});

test("qualification covers all profile targets when no target is requested", () => {
  expect(selectQualification(config(), "perf-foundation").map((s) => s.target)).toEqual(["g6lc64_stream8", "g6lc64_smt2"]);
});

test("qualification refuses unknown profiles, targets and suites", () => {
  expect(() => selectQualification(config(), "missing")).toThrow();
  expect(() => selectQualification(config(), "perf-foundation", "g6lc64_ooo")).toThrow();
  const cfg = config();
  cfg.verify.qualifications["perf-foundation"].targets.g6lc64_stream8[0]!.suite = "missing";
  expect(() => selectQualification(cfg, "perf-foundation")).toThrow();
  expect(() => validateConfig(cfg)).toThrow();
});

test("qualification rejects empty coverage and invalid manifest paths", () => {
  const cfg = config();
  cfg.verify.qualifications["perf-foundation"].targets.g6lc64_stream8 = [];
  expect(() => selectQualification(cfg, "perf-foundation")).toThrow();
  expect(() => validateConfig(cfg)).toThrow();
  for (const path of ["../build.json", "C:\\outside.json", "/tmp/build.json", ""]) {
    const next = config();
    next.verify.qualifications["perf-foundation"].targets.g6lc64_stream8[0]!.buildManifest = path;
    expect(() => validateConfig(next)).toThrow();
  }
});

test("evidence accepts a complete matching terminal record", () => {
  const result = validateSuiteEvidence("build diagnostics\n" + output(), "", expected);
  expect(result.ok).toBe(true);
  expect(result.evidence?.checks).toBe(12);
});

test("evidence refuses missing, malformed and nonterminal records", () => {
  for (const text of ["PASS (lint fallback)\n", "", "G6LC_EVIDENCE {", output() + "FAIL later\n", output() + output(), "G6LC_EVIDENCE null\n"]) {
    expect(validateSuiteEvidence(text, "", expected).ok).toBe(false);
  }
});

test("evidence matches suite, actual DUT, fidelity, invocation and build identity", () => {
  for (const [field, value] of Object.entries({
    suite: "smoke-cv64a6", target: "cv64a6_imafdc_sv39", top: "lint_top", kind: "iss",
    runId: "run-old", sourceSha256: "4".repeat(64), configSha256: "5".repeat(64), executableSha256: "6".repeat(64),
  })) {
    expect(validateSuiteEvidence(output({ [field]: value }), "", expected).ok).toBe(false);
  }
});

test("evidence cannot qualify skipped, failed, timed out or zero-work runs", () => {
  for (const delta of [{ execution: "local" }, { status: "skip" }, { status: "fail" }, { status: "timeout" }, { checks: 0 }, { checks: -1 }, { checks: 1.5 }, { checks: "12" }, { schemaVersion: 2 }]) {
    expect(validateSuiteEvidence(output(delta), "", expected).ok).toBe(false);
  }
});

test("evidence rejects invalid digests even if the expected record agrees", () => {
  expect(validateSuiteEvidence(output({ sourceSha256: "unknown" }), "", { ...expected, sourceSha256: "unknown" }).ok).toBe(false);
});

test("evidence never overrides failure diagnostics", () => {
  for (const error of ["%Error: assertion failed", "make: *** Error 2", "FAIL test_case", "Assertion failed: lost invalidation"]) {
    expect(validateSuiteEvidence(output(), error, expected).ok).toBe(false);
  }
});

test("build evidence validates source contents and configuration digest", () => {
  const root = mkdtempSync(join(tmpdir(), "g6lc-evidence-"));
  const hash = (s: string) => createHash("sha256").update(s).digest("hex");
  const source = "module test; endmodule\n";
  const sources = { "test.sv": hash(source) };
  const configuration = { NrCores: 2, NrHarts: 1 };
  const manifest = {
    schemaVersion: 1, target: expected.target, top: expected.top,
    execution: "remote-proxy", sources, configuration,
    sourceSha256: hash(JSON.stringify(Object.entries(sources))),
    configSha256: hash(JSON.stringify(configuration)),
    executableSha256: expected.executableSha256,
  };
  const selection = selectQualification(config(), "perf-foundation", expected.target)[0]!;
  try {
    writeFileSync(join(root, "test.sv"), source);
    const identity = evidenceIdentityFromManifest(root, manifest, selection, "new-run");
    expect(identity.target).toBe(expected.target);
    expect(identity.runId).toBe("new-run");
    expect(identity.sourceSha256).toBe(manifest.sourceSha256);
    for (const delta of [{ target: "other" }, { top: "other" }, { execution: "local" }, { sourceSha256: "0".repeat(64) }, { configSha256: "0".repeat(64) }, { sources: {} }]) {
      expect(() => evidenceIdentityFromManifest(root, { ...manifest, ...delta }, selection, "new-run")).toThrow();
    }
    writeFileSync(join(root, "test.sv"), source + "\n");
    expect(() => evidenceIdentityFromManifest(root, manifest, selection, "new-run")).toThrow();
  } finally {
    rmSync(root, { recursive: true });
  }
});

test("manifest digests interop with the Python proxy canonical form", () => {
  // The proxy writes sourceSha256/configSha256 with
  // json.dumps(..., sort_keys=True, separators=(",", ":")) — this must equal
  // digestJson's JSON.stringify-with-sorted-keys output byte for byte.
  if (!hasBinary("python3")) return; // no python3 on this host — contract covered on proxy side
  const root = mkdtempSync(join(tmpdir(), "g6lc-evidence-py-"));
  try {
    writeFileSync(join(root, "a.sv"), "module a; endmodule\n");
    writeFileSync(join(root, "b.sv"), "module b; endmodule\n");
    const gen = `
import hashlib, json, sys
root = sys.argv[1]
def sha(b): return hashlib.sha256(b).hexdigest()
sources = {p: sha(open(root + "/" + p, "rb").read()) for p in ("a.sv", "b.sv")}
cfg = {"flavour": "B", "target": "g6lc64_smt2", "verlib": "work-ver-smt2-fw64-B", "defines": "", "jobs": "nproc", "vthreads": "harness"}
canon = lambda v: hashlib.sha256(json.dumps(v, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
print(json.dumps({
  "schemaVersion": 1, "target": "g6lc64_smt2", "top": "ariane_testharness",
  "execution": "remote-proxy", "sources": sources,
  "sourceSha256": canon([[k, v] for k, v in sorted(sources.items())]),
  "configuration": cfg, "configSha256": canon(cfg),
  "executableSha256": "3" * 64,
}))
`;
    const made = Bun.spawnSync(["python3", "-c", gen, root]);
    expect(made.exitCode).toBe(0);
    const selection = selectQualification(config(), "perf-foundation", "g6lc64_smt2")[0]!;
    const identity = evidenceIdentityFromManifest(root, JSON.parse(made.stdout.toString()), { ...selection, kind: "rtl-core" }, "run-x");
    expect(identity.sourceSha256).toMatch(/^[a-f0-9]{64}$/);
    expect(identity.configSha256).toMatch(/^[a-f0-9]{64}$/);
  } finally {
    rmSync(root, { recursive: true });
  }
});

test.skipIf(!hasBinary("python3") && !hasBinary("python"))("isolated L2 proxy rejects incomplete snapshots and hashes the exact input set", () => {
  const python = hasBinary("python3") ? "python3" : "python";
  const script = `
import hashlib, importlib.util, pathlib, sys, tempfile
spec = importlib.util.spec_from_file_location("th_proxy", sys.argv[1])
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)
paths = ["vendor/pulp-platform/axi/src/axi_pkg.sv", "vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv"]
paths += [f"corev_apu/l2_cache/g6lc_l2_{name}.sv" for name in ("pkg", "tag", "data", "mshr", "top")]
paths += ["verif/tb/l2/tb_g6lc_l2.sv", "verif/tb/l2/tb_g6lc_l2.vlt", "verif/tb/l2/run-l2-tb.sh"]
with tempfile.TemporaryDirectory() as d:
    root = pathlib.Path(d)
    try:
        proxy.l2_leaf_sources(root)
        raise AssertionError("missing inputs accepted")
    except FileNotFoundError:
        pass
    for path in paths:
        dest = root / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b"fixture input")
    (root / "unrelated.txt").write_bytes(b"not part of the build")
    sources = proxy.l2_leaf_sources(root)
    assert set(sources) == set(paths)
    assert set(sources.values()) == {hashlib.sha256(b"fixture input").hexdigest()}
    (root / paths[0]).write_bytes(b"changed")
    changed = proxy.l2_leaf_sources(root)
    assert [p for p in sources if sources[p] != changed[p]] == [paths[0]]
    args = proxy.build_parser().parse_args(["l2-leaf", str(root), "--rr-en", "1"])
    assert args.fn is proxy.cmd_l2_leaf and args.rr_en == 1
    unit_args = proxy.build_parser().parse_args(["l2-leaf", str(root), "--mode", "units"])
    assert unit_args.mode == "units"
    synth_args = proxy.build_parser().parse_args(["l2-leaf", str(root), "--mode", "synth", "--rr-en", "1"])
    assert synth_args.mode == "synth" and synth_args.rr_en == 1
    eq = proxy.build_parser().parse_args(["l2-equiv", str(root), "--byte-size", "4096", "--mem", "collect"])
    assert eq.fn is proxy.cmd_l2_equiv and eq.byte_size == 4096 and eq.mem == "collect"
    bbox = proxy.build_parser().parse_args(["l2-equiv", str(root), "--byte-size", "262144", "--ways", "8", "--mem", "bbox"])
    assert bbox.mem == "bbox" and bbox.byte_size == 262144 and bbox.ways == 8
text = chr(10).join([
    "[L2TB] policy checks lookups=12 installs=8 evictions=4 victim_mask=f",
    *[f"[L2TB] ATOP mode={mode} forwarded=1" for mode in range(3)],
    "[L2TB] AMO arith add=1 swap=1 cas_hit=1 cas_miss=1 lrsc_ok=1 lrsc_fail=1",
    "phase=replacement_hole", "phase=bypass_backpressure", "phase=short_last_fill_guard",
    # l2_leaf_passed also requires the fill-error phase: a run whose error-fill
    # coverage silently disappeared must not be accepted as a pass.
    "phase=fill_error_no_install",
    "[L2TB] RESULT pass",
])
assert proxy.l2_leaf_passed(text, 0, 4, 1)
assert proxy.l2_leaf_passed(text.replace("victim_mask=f", "victim_mask=1"), 0, 4, 0)
for changed in (
    text.replace("lookups=12", "lookups=0"), text.replace("installs=8", "installs=2"),
    text.replace("victim_mask=f", "victim_mask=1"), text.replace("evictions=4", "evictions=1"),
    text.replace("phase=replacement_hole", "missing hole"), text.replace("ATOP mode=2", "missing ATOP"),
    text.replace("AMO arith add=1", "AMO missing"),
    text + chr(10) + "FAIL later", text + chr(10) + "[L2TB] RESULT pass", "[L2TB] RESULT pass",
):
    assert not proxy.l2_leaf_passed(changed, 0, 4, 1)
assert not proxy.l2_leaf_passed(text, 1, 4, 1)
assert not proxy.l2_leaf_passed(text, 0, 3, 1)
eq_ok = "[l2-tb] EQUIVALENCE PASS mem=collect bytes=4096"
assert proxy.l2_equiv_passed(eq_ok, 0, False)
assert proxy.l2_equiv_passed("[l2-tb] EQUIVALENCE PASS mem=bbox bytes=262144", 0, False)
assert not proxy.l2_equiv_passed(eq_ok, 1, False)
assert not proxy.l2_equiv_passed("LADDER FAIL", 0, False)
assert proxy.l2_equiv_passed("unproven points remain", 1, True)
unit = chr(10).join([
    "[L2UNIT] mshr_full=1 merge=1 merge_full=1 waiter=1 bank_conflict=1 bank_ok=1",
    "[L2UNIT] RESULT pass",
])
assert proxy.l2_units_passed(unit, 0)
assert not proxy.l2_units_passed(unit.replace("mshr_full=1", "mshr_full=0"), 0)
assert not proxy.l2_units_passed(unit, 1)
assert proxy.l2_synth_passed("[l2-tb] SYNTH PASS rr=0 tagsram=0 wu=0 mem=2", 0, 0)
assert proxy.l2_synth_passed("[l2-tb] SYNTH PASS rr=1 tagsram=0 wu=0 mem=3", 0, 1)
assert proxy.l2_synth_passed("[l2-tb] SYNTH PASS rr=1 tagsram=1 wu=1 mem=4", 0, 1, 1, 1)
assert not proxy.l2_synth_passed("[l2-tb] SYNTH PASS rr=1 tagsram=0 wu=0 mem=3", 0, 0)
assert not proxy.l2_synth_passed("[l2-tb] SYNTH PASS rr=1 tagsram=0 wu=0 mem=3", 0, 1, 1)
assert not proxy.l2_synth_passed("[l2-tb] SYNTH PASS rr=1 tagsram=0 wu=0 mem=3", 1, 1)
assert not proxy.l2_synth_passed("[l2-tb] SYNTH PASS rr=1 mem=3", 0, 1)
print("L2 snapshot checks passed")
`;
  const result = Bun.spawnSync([python, "-c", script, join(import.meta.dir, "../../verif/regress/remote/testharness_proxy.py")]);
  expect(result.exitCode).toBe(0);
  expect(result.stdout.toString().trim()).toBe("L2 snapshot checks passed");
});

test.skipIf(!hasBinary("python3") && !hasBinary("python"))("isolated config overlay rewrites only allowlisted fields", () => {
  const python = hasBinary("python3") ? "python3" : "python";
  const script = `
import json, pathlib, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
overlay = root / "verif/regress/isolated-config-overlay.py"
pkg = (root / "core/include/g6lc64_stream8_config_pkg.sv").read_text(encoding="utf-8")
assert "L2RoundRobinEn: bit'(0)" in pkg
with tempfile.TemporaryDirectory() as d:
    out = pathlib.Path(d) / "iso"
    r = subprocess.run([sys.executable, str(overlay), "--root", str(root), "--target", "g6lc64_stream8",
                        "--out", str(out), "--field", "L2RoundRobinEn=1"], check=True, capture_output=True, text=True)
    meta = json.loads((out / "overlay.json").read_text())
    assert meta["isolated"] and meta["notALinuxSku"]
    assert meta["fields"]["L2RoundRobinEn"] == {"from": "0", "to": "1"}
    text = (out / "core/include/g6lc64_stream8_config_pkg.sv").read_text(encoding="utf-8")
    assert "L2RoundRobinEn: bit'(1)" in text
    assert (out / "Flist.cva6.overlay").is_file()
    bad = subprocess.run([sys.executable, str(overlay), "--root", str(root), "--target", "g6lc64_stream8",
                          "--out", str(out), "--field", "NrCores=4"], capture_output=True, text=True)
    assert bad.returncode != 0
qw = (root / "verif/regress/remote/qualify-checked-work.sh").read_text(encoding="utf-8")
assert "*work-ver-stream8*" not in qw
assert "work-ver-stream8.manifest.json" in qw
assert "iso-stream8-rr1" not in qw.split("work-ver-stream8.manifest.json")[0]
bh = (root / "verif/regress/soft-ladder-build-harness.sh").read_text(encoding="utf-8")
assert 'verlib_base="$(basename "$VERLIB_DIR")"' in bh
print("overlay checks passed")
`;
  const result = Bun.spawnSync([python, "-c", script, join(import.meta.dir, "../..")]);
  expect(result.exitCode).toBe(0);
  expect(result.stdout.toString().trim()).toBe("overlay checks passed");
});

test("build evidence refuses paths outside the source root", () => {
  const selection = selectQualification(config(), "perf-foundation", expected.target)[0]!;
  for (const path of ["../secret.sv", "C:/outside.sv", "/tmp/outside.sv", "a/../../outside.sv"]) {
    expect(() => evidenceIdentityFromManifest(".", {
      schemaVersion: 1, target: expected.target, top: expected.top, execution: "remote-proxy",
      sources: { [path]: "1".repeat(64) }, configuration: {},
      sourceSha256: "1".repeat(64), configSha256: "2".repeat(64), executableSha256: "3".repeat(64),
    }, selection, "new-run")).toThrow();
  }
});
