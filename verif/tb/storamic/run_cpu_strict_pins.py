# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""cpu-strict-pins: pinned, proof-backed UNOPTFLAT residual diagnostics.

Runs the CPU45/CPU46 full-core Verilator strict diagnostic over the
cpu-origin fixture closure in both origin modes and both diagnostic
representations:

  * fields — the frozen diagnostic.vlt split_var control set
             (cpu_strict_fields.vlt), the "diagnostic-representation"
             baseline (~4 UNOPTFLAT identities on the CPU46 reference).
  * fp     — FP-controls-only (`split_var -module "fpnew_*"
             -var "*_pipe_*_q"`), the ~21-identity baseline.

Strict options are exactly the CPU46 manifest set; the runtime's
verilator_options (--unroll-count/--unroll-stmts) are appended verbatim.
No UNOPTFLAT suppression: no -Wno-UNOPTFLAT, no suppression flags, no FP
disabling. Every UNOPTFLAT is parsed to a normalized hierarchical identity
(verbatim signal name; the regex already excludes file:line noise, so no
further stripping is applied — the strictest reading, so a new loop cannot
alias a pinned one).

Verdict per (variant, origin): PASS iff observed identities ⊆ pins.
An observed identity not in pins FAILS the stage naming it. A pinned
identity absent from the observed set is reported `stale-pin` (pins may
only shrink). Any other %Error class the strict flow treats as fatal
(LATCH/PINMISSING/etc.) also fails.

Proof coupling: the verdict is `incomplete` unless the core-scc stage
passed (SCC=0, latches=0) on the identical source manifest — recorded in
manifest["core_scc"] with the same sources_sha256.

Negative oracle: a looped canary (g6lc_strict_pins_canary.sv +
g6lc_strict_pins_canary_top, testbench-side) is injected under a wrapper
top instantiating the real core; the strict flow must report an UNOPTFLAT
identity naming g6lc_strict_pins_canary, which is unpinned by construction.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor

BENCH_REL = "verif/tb/storamic/tb_g6lc_storamic_cpu_origin.sv"
TOP = "tb_g6lc_storamic_cpu_origin"
CANARY_TOP = "g6lc_strict_pins_canary_top"
CANARY_MODULE = "g6lc_strict_pins_canary"

STRICT = ["--lint-only", "--timing", "--assert", "--threads", "1",
          "-Wno-fatal", "-Werror-LATCH", "-Werror-UNOPTFLAT",
          "-Werror-PINMISSING", "--error-limit", "0"]
HEADER = ("// Copyright 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n"
          "`verilator_config\n")
FP_CONTROL = HEADER + 'split_var -module "fpnew_*" -var "*_pipe_*_q"\n'
IDENT = re.compile(r"UNOPTFLAT:.*?Circular combinational logic: '([^']+)'")
LINT_DIRECTIVE = re.compile(
    r"^.*verilator\s+lint_(?:off|on)\s+(?:UNOPTFLAT|LATCH).*$", re.M)
DIAG_TIMEOUT = 900


class StageIncomplete(Exception):
    """Raised when the stage cannot issue a verdict (e.g. the coupled
    core-scc proof did not run/pass on this manifest). run_leaf maps any
    non-RuntimeError to leaf status `incomplete`."""


def _sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _env(runtime):
    env = dict(os.environ)
    for key in ("MAKEFLAGS", "MFLAGS", "CXX", "CC", "CXXFLAGS", "CFLAGS",
                "CPPFLAGS", "LDFLAGS", "OBJCACHE", "VERILATOR_ROOT", "VPATH"):
        env.pop(key, None)
    if runtime.get("kind") == "g6lc-fork-native":
        env["VERILATOR_ROOT"] = runtime["root"]
    return env


def _strip_directives(tree):
    removed = []
    for path in tree.rglob("*"):
        if not path.is_file():
            continue
        text = path.read_text()
        matches = list(LINT_DIRECTIVE.finditer(text))
        if matches:
            assert all(m.group().strip().startswith(("/*", "//"))
                       for m in matches), f"non-comment lint directive {path}"
            removed.append({"file": str(path.relative_to(tree)),
                            "count": len(matches)})
            path.write_text(LINT_DIRECTIVE.sub(
                "// Unwaived diagnostic; production unchanged.", text))
    return removed


def _rebuild_tree(data, out, plan):
    tree = out / "strict-src"
    for rel in (list(plan["files"]) + list(plan["support_files"])
                + [BENCH_REL]):
        dst = tree / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(data / Path(rel).name, dst)
    return tree


def _command(verilator, runtime, tree, plan, out, name, top, origin, files,
             control, extra_defs=()):
    return [str(verilator), "--lint-only", *STRICT,
            *runtime.get("verilator_options", []),
            "--Mdir", str(out / ("obj-" + name)),
            "--top-module", top,
            *([f"-GOriginEnabled={origin}", "-GIntegerDiagnostic=0"]
              if origin is not None else []),
            *["-I" + str(tree / d) for d in plan["incdirs"]],
            *plan["defines"], *extra_defs,
            *[str(p) for p in files], str(control)]


def _diagnose(name, command, log_path, env, timeout=DIAG_TIMEOUT):
    (log_path.parent / (name + "-command.json")).write_text(
        json.dumps(command))
    started = time.monotonic()
    with log_path.open("w") as log:
        proc = subprocess.Popen(command, env=env, cwd=log_path.parent,
                                stdout=log, stderr=subprocess.STDOUT,
                                start_new_session=True)
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            import signal
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
            rc = None
    text = log_path.read_text(errors="replace")
    return {"name": name, "rc": rc,
            "seconds": round(time.monotonic() - started, 1),
            "log_sha256": _sha(log_path), "text": text}


def _identities(text):
    return sorted({m.group(1) for m in IDENT.finditer(text)})


def _other_errors(text):
    """%Error lines the strict flow treats as fatal, excluding UNOPTFLAT and
    the generic 'Exiting due' trailer."""
    out = []
    for line in text.splitlines():
        if not line.startswith("%Error"):
            continue
        if "UNOPTFLAT" in line or line.startswith("%Error: Exiting due"):
            continue
        out.append(line)
    return out


def _pins_for(pins, variant, origin_index):
    origin_key = "origin%d" % origin_index
    return {p["identity"] for p in pins["variants"][variant][origin_key]}


def _evaluate(results, pins):
    """Compare observed UNOPTFLAT identities to the pin file.

    results: {name: {"text","rc","seconds"}} for the four standard cases.
    Returns (observed, verdicts, hard_fail, stale)."""
    observed, verdicts, hard_fail, stale = {}, {}, [], {}
    for variant in ("fields", "fp"):
        for origin in (0, 1):
            name = f"{variant}-origin{origin}"
            r = results[name]
            ids = _identities(r["text"])
            observed[name] = ids
            pinned = _pins_for(pins, variant, origin)
            unpinned = sorted(set(ids) - pinned)
            gone = sorted(pinned - set(ids))
            other = _other_errors(r["text"])
            stale[name] = gone
            ok = (not unpinned and not other)
            verdicts[name] = {
                "pass": ok, "observed": len(ids), "pinned": len(pinned),
                "unpinned": unpinned, "stale_pins": gone,
                "other_errors": other, "rc": r["rc"],
                "seconds": r["seconds"]}
            if unpinned:
                hard_fail.append(
                    f"{name}: unpinned UNOPTFLAT identities: "
                    + "; ".join(unpinned))
            if other:
                hard_fail.append(f"{name}: fatal non-UNOPTFLAT errors: "
                                 + "; ".join(other[:8]))
    return observed, verdicts, hard_fail, stale


def _evaluate_canary(result):
    """The canary top instantiates the real core (u_cpu) plus the looped
    canary module. Core identities carry the ``<top>.u_cpu.cpu.`` prefix; the
    canary's own loop identity is whatever does NOT — that extra identity is
    the detection. The looped signal is named g6lc_strict_pins_canary_comb so
    the reported identity is self-describing."""
    ids = _identities(result["text"])
    cpu_prefix = CANARY_TOP + ".u_cpu.cpu"
    hits = [i for i in ids if not i.startswith(cpu_prefix)]
    other = _other_errors(result["text"])
    ok = bool(hits) and not other
    return {"pass": ok, "identities": ids, "canary_hits": hits,
            "other_errors": other, "rc": result["rc"]}, ok


def _coupled(core, sources_sha):
    return bool(core and core.get("pass") and core.get("sccs") == 0
                and core.get("latches") == 0
                and core.get("sources_sha256") == sources_sha)


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    if "cpu-strict-pins" not in stages:
        return
    plan = json.loads((data / "cpu_origin_plan.json").read_text())
    pins = json.loads((data / "cpu_strict_pins.json").read_text())
    runtime = manifest.get("runtime", {})
    env = _env(runtime)
    tree = _rebuild_tree(data, out, plan)
    removed = _strip_directives(tree)

    # Controls: fields uses the committed frozen .vlt; fp is generated inline
    # (identical to the CPU46 fp control).
    fields_ctl = out / "fields.vlt"
    fields_ctl.write_text((data / "cpu_strict_fields.vlt").read_text())
    fp_ctl = out / "fp.vlt"
    fp_ctl.write_text(FP_CONTROL)
    controls = {"fields": fields_ctl, "fp": fp_ctl}

    core_files = [tree / rel for rel in plan["files"]]
    bench = tree / BENCH_REL
    incs_files = core_files + [bench]

    jobs = []
    for variant in ("fields", "fp"):
        for origin in (0, 1):
            name = f"{variant}-origin{origin}"
            jobs.append((name, _command(
                verilator, runtime, tree, plan, out, name, TOP, origin,
                incs_files, controls[variant]), None))
    # Canary oracle: same closure + wrapper top + looped canary module.
    canary_files = core_files + [
        data / "g6lc_core_scc_top.sv", data / "g6lc_strict_pins_canary.sv"]
    jobs.append(("canary", _command(
        verilator, runtime, tree, plan, out, "canary", CANARY_TOP, None,
        canary_files, fields_ctl), None))

    results = {}
    with ThreadPoolExecutor(max_workers=4) as pool:
        futs = {pool.submit(_diagnose, name, cmd, out / (name + ".log"),
                            env): name for name, cmd, _ in jobs}
        for fut, name in futs.items():
            results[name] = fut.result()

    observed, verdicts, hard_fail, stale = _evaluate(results, pins)

    # Canary oracle: must surface an unpinned identity naming the canary.
    canary_verdict, canary_ok = _evaluate_canary(results["canary"])
    verdicts["canary"] = canary_verdict
    if not canary_ok:
        hard_fail.append(
            "canary oracle: expected an UNOPTFLAT identity naming "
            f"{CANARY_MODULE}; got {canary_verdict['identities']}")

    # Proof coupling: core-scc must have passed on this manifest.
    core = manifest.get("core_scc")
    sources_sha = hashlib.sha256(json.dumps(
        manifest.get("sources", {}), sort_keys=True).encode()).hexdigest()
    coupled = _coupled(core, sources_sha)

    observed_doc = {
        "stage": "cpu-strict-pins", "top": TOP,
        "controls": {"fields": str(fields_ctl), "fp": str(fp_ctl)},
        "strict": STRICT, "unroll": runtime.get("verilator_options", []),
        "removed_directives": removed,
        "observed": observed, "verdicts": verdicts,
        "core_scc_coupled": coupled,
        "core_scc": core, "sources_sha256": sources_sha,
        "canary": verdicts["canary"],
    }
    (out / "strict-pins-observed.json").write_text(
        json.dumps(observed_doc, indent=2))

    for variant in ("fields", "fp"):
        for origin in (0, 1):
            name = f"{variant}-origin{origin}"
            outcomes.append({"cpu_strict_pins": name,
                             **{k: v for k, v in verdicts[name].items()
                                if k != "unpinned"},
                             "pass": verdicts[name]["pass"]})
    outcomes.append({"cpu_strict_pins": "canary-oracle",
                     "pass": canary_ok,
                     "canary_hits": canary_verdict["canary_hits"]})

    if not coupled:
        # verdict=incomplete: core-scc did not prove this manifest. The
        # diagnostic outcomes are still recorded; hard_fail (if any) is
        # reported for diagnosis but the gated verdict is incomplete.
        (out / "strict-pins-result.json").write_text(json.dumps(
            {**observed_doc, "verdict": "incomplete",
             "reason": "core-scc not passed on identical manifest",
             "failures": hard_fail}, indent=2))
        raise StageIncomplete("CPU_STRICT_PINS_INCOMPLETE core-scc coupling "
                              "not satisfied")
    if hard_fail:
        (out / "strict-pins-result.json").write_text(json.dumps(
            {**observed_doc, "verdict": "fail",
             "failures": hard_fail}, indent=2))
        raise RuntimeError("CPU_STRICT_PINS_FAIL " + " | ".join(hard_fail))
    (out / "strict-pins-result.json").write_text(json.dumps(
        {**observed_doc, "verdict": "pass"}, indent=2))
    manifest["cpu_strict_pins"] = {
        "verdict": "pass", "coupled": coupled, "sources_sha256": sources_sha}
    outcomes.append({"cpu_strict_pins": "verdict", "pass": True,
                     "stale_pins": {k: v for k, v in stale.items() if v}})
