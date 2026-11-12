# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""checkpoint-route / checkpoint-route-formal: remote route qualification.

Remote port of run_route.py (component sim over the pulp-platform AXI
interconnect/crossbar) and check_route.py (yosys-smtbmc formal). run_route.py
is local-only (PATH verilator, repo-root source copy); this leaf rebuilds the
same repo-relative source tree from the flat basename uploads in data/,
regenerates the route-*.svh/route-axi-setup.sv headers from
tb_g6lc_storamic_ctrl_bridge.sv exactly as run_route.py does, then builds and
runs the owned remote runtime through build_model().

Sim profiles mirror run_route.py: direct (UseMux=0,UseXbar=0), interconnect
(UseMux=1,UseXbar=0) and crossbar (UseMux=1,UseXbar=1) each with the
+oracle_negative case, plus the native-profile builds (NativeProfile=1,
NativeMstPorts=16, StoramicIdx=13, UseXbar=1) whose adversarial port-1/port-2
refusal is baked into the bench. checkpoint-route-formal runs the existing
formal_g6lc_storamic_checkpoint_route.sv through owned yosys-smtbmc/yices.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

VENDOR = "vendor/pulp-platform/"
LEGACY = "verif/tb/storamic/tb_g6lc_storamic_ctrl_bridge.sv"
# Repo-relative compile set; identical to run_route.py --crossbar + native.
FILES = [
    VENDOR + "axi/src/axi_pkg.sv",
    "g6lc_storamic/rtl/include/g6lc_storamic_pkg.sv",
    "g6lc_storamic/rtl/fabric/g6lc_storamic_checkpoint_service.sv",
    "corev_apu/storamic/g6lc_storamic_ctrl_bridge.sv",
    "corev_apu/storamic/g6lc_storamic_checkpoint_route.sv",
    LEGACY,
    "verif/tb/storamic/tb_g6lc_storamic_checkpoint_route.sv",
    "verif/tb/storamic/formal_g6lc_storamic_checkpoint_route.sv",
    "verif/tb/storamic/route_interconnect.vlt",
    VENDOR + "common_cells/src/cf_math_pkg.sv",
    VENDOR + "common_cells/src/lzc.sv",
    VENDOR + "common_cells/src/rr_arb_tree.sv",
    VENDOR + "common_cells/src/fifo_v3.sv",
    VENDOR + "common_cells/src/spill_register_flushable.sv",
    VENDOR + "common_cells/src/spill_register.sv",
    VENDOR + "axi/src/axi_intf.sv",
    VENDOR + "axi/src/axi_id_prepend.sv",
    VENDOR + "axi/src/axi_mux.sv",
    VENDOR + "common_cells/src/addr_decode.sv",
    VENDOR + "common_cells/src/delta_counter.sv",
    VENDOR + "common_cells/src/counter.sv",
    VENDOR + "common_cells/src/deprecated/fifo_v2.sv",
    VENDOR + "common_cells/src/stream_register.sv",
    VENDOR + "axi/src/axi_atop_filter.sv",
    VENDOR + "axi/src/axi_err_slv.sv",
    VENDOR + "axi/src/axi_demux.sv",
    VENDOR + "axi/src/axi_xbar.sv",
    VENDOR + "common_cells/include/common_cells/assertions.svh",
    VENDOR + "common_cells/include/common_cells/registers.svh",
    VENDOR + "axi/include/axi/assign.svh",
    VENDOR + "axi/include/axi/typedef.svh",
]
# (profile tag, enabled, masters, spill, mux, xbar, native)
PROFILES = [
    ("direct", 1, 3, 0, 0, 0, 0),
    ("direct-disabled", 0, 3, 0, 0, 0, 0),
    ("interconnect", 1, 3, 0, 1, 0, 0),
    ("crossbar", 1, 3, 0, 1, 1, 0),
    ("native", 1, 3, 0, 1, 1, 1),
    ("native-disabled", 0, 3, 0, 1, 1, 1),
    ("config-illegal", 1, 2, 0, 0, 0, 0),
]
FORMAL_INPUTS = [
    "axi_pkg.sv", "g6lc_storamic_pkg.sv",
    "g6lc_storamic_checkpoint_service.sv",
    "g6lc_storamic_checkpoint_route.sv",
    "formal_g6lc_storamic_checkpoint_route.sv",
]
WNO = ["-Wno-TIMESCALEMOD", "-Wno-UNUSED", "-Wno-WIDTHTRUNC", "-Wno-WIDTHEXPAND",
       "-Wno-PINCONNECTEMPTY", "-Wno-CASEINCOMPLETE", "-Wno-DECLFILENAME",
       "-Wno-MODDUP", "-Wno-LITENDIAN", "-Wno-EOFNEWLINE"]
# UNOPTFLAT loop identity extractor (same pattern as run_cpu_strict_pins.py).
UNOPT_IDENT = re.compile(
    r"UNOPTFLAT:.*?Circular combinational logic: '([^']+)'")
PINS_FILE = "route_native_unoptflat_pins.json"


def _unoptflat_pins(data):
    """Pinned known-false crossbar UNOPTFLAT identities, keyed by xbar flavour
    ('legacy' = g_legacy_xbar, 'native' = g_native_xbar). Returns the flavours
    dict, or None when the pins file is absent."""
    path = data / PINS_FILE
    if not path.is_file():
        return None
    return json.loads(path.read_text(encoding="utf-8")).get("flavors", {})


def _check_unoptflat_pins(data, out, tag, log_path, flavor):
    """Verify every UNOPTFLAT identity in a crossbar build log is pinned for the
    given xbar flavour. Crossbar profiles leave UNOPTFLAT a warning (production
    posture, never -Wno/-Werror) so verilation still yields a model; this proves
    the only combinational loops are the documented false crossbar ready/valid
    loops. `flavor` is 'native' for NativeProfile=1, else 'legacy'."""
    flavors = _unoptflat_pins(data)
    if flavors is None or flavor not in flavors:
        raise RuntimeError(
            f"checkpoint-route {tag}: missing {PINS_FILE} flavour {flavor!r}")
    pins = set(flavors[flavor]["identities"])
    text = Path(log_path).read_text(encoding="utf-8", errors="replace")
    ids = set(UNOPT_IDENT.findall(text))
    unpinned = sorted(ids - pins)
    stale = sorted(pins - ids)
    if unpinned:
        raise RuntimeError(
            f"checkpoint-route {tag}: unpinned UNOPTFLAT identities: "
            + "; ".join(unpinned))
    return {"flavor": flavor, "observed": len(ids), "pinned": len(pins),
            "observed_identities": sorted(ids), "stale_pins": stale}


def _sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _build_tree(data, out):
    """Rebuild the repo-relative source tree from flat basename uploads and
    regenerate the route headers exactly as run_route.py does."""
    tree = out / "route-src"
    hashes = {}
    for rel in FILES:
        dest = tree / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(data / Path(rel).name, dest)
        hashes[rel] = _sha(dest)
    original = (tree / LEGACY).read_text(encoding="utf-8")
    definitions = original[original.index("  typedef struct packed {"):
                             original.index("  logic clk")]
    header = tree / "route-axi-types.svh"
    header.write_text("// Copyright 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n" +
                      definitions, encoding="utf-8")
    hashes["generated:route-axi-types.svh"] = _sha(header)
    local = re.sub(r"\b(aw_t|ar_t|w_t|b_t|r_t|req_t|resp_t)\b",
                   lambda m: "local_" + m.group(0), definitions)
    local = re.sub(r"\bIdW\b", "4", local)
    local_header = tree / "route-local-types.svh"
    local_header.write_text("// Copyright 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n" +
                            local, encoding="utf-8")
    hashes["generated:route-local-types.svh"] = _sha(local_header)
    setup = tree / "route-axi-setup.sv"
    setup.write_text('// Copyright 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n'
                     '`include "axi/typedef.svh"\n`include "axi/assign.svh"\n',
                     encoding="utf-8")
    hashes["generated:route-axi-setup.sv"] = _sha(setup)
    return tree, hashes


def _sim(data, out, manifest, builds, outcomes, verilator, build_model):
    tree, hashes = _build_tree(data, out)
    manifest["checkpoint_route_sources"] = hashes
    env = dict(os.environ)
    for key in ("MAKEFLAGS", "MFLAGS", "CXX", "CC", "CXXFLAGS", "CFLAGS",
                "CPPFLAGS", "LDFLAGS", "OBJCACHE", "VERILATOR_ROOT", "VPATH"):
        env.pop(key, None)
    if manifest["runtime"].get("kind") == "g6lc-fork-native":
        env["VERILATOR_ROOT"] = manifest["runtime"]["root"]
    # Exclude LEGACY (typedef source only, not a compile unit) and the formal
    # top, matching run_route.py's `n != legacy and not formal_` filter.
    sv = [str(tree / rel) for rel in FILES
          if rel.endswith(".sv") and rel != LEGACY
          and not Path(rel).name.startswith("formal_")]
    results = []
    for tag, enabled, masters, spill, mux, xbar, native in PROFILES:
        model = out / ("route-" + tag)
        model.mkdir()
        command = [str(verilator), "--binary", "--timing", "--assert",
                   "-Wno-fatal", "-Werror-LATCH", "-Werror-UNOPTFLAT",
                   "-Werror-PINMISSING",
                   "--top-module", "tb_g6lc_storamic_checkpoint_route",
                   "-I" + str(tree),
                   "-I" + str(tree / (VENDOR + "common_cells/include")),
                   "-I" + str(tree / (VENDOR + "axi/include")),
                   "--Mdir", str(model), "-o", "test",
                   f"-GEnabled={enabled}", f"-GMasterCount={masters}",
                   f"-GUseMux={mux}", f"-GSpillRequests={spill}",
                   f"-GUseXbar={xbar}", f"-GNativeProfile={native}",
                   "-GNativeMstPorts=16", "-GStoramicIdx=13",
                   str(tree / "verif/tb/storamic/route_interconnect.vlt"),
                   str(tree / "route-axi-setup.sv"), *sv]
        command += manifest["runtime"].get("verilator_options", [])
        if xbar:
            # Every UseXbar=1 profile instantiates pulp-platform axi_xbar, whose
            # false ready/valid UNOPTFLAT loops run through 1-bit / generate-
            # scoped signals that split_var cannot break (route_interconnect.vlt
            # already splits every 'can split_var' aggregate). Leave UNOPTFLAT a
            # WARNING — never -Wno, never suppressed — so verilation still yields
            # a model, then pin-check below that only documented false loops are
            # reported (same posture as cpu-strict-pins, but here we also sim).
            # The flavour key follows NativeProfile: g_native_xbar vs g_legacy_xbar.
            command = [c for c in command if c != "-Werror-UNOPTFLAT"]
        (out / ("route-" + tag + "-command.json")).write_text(
            json.dumps(command))
        identity = build_model(command, model,
                               out / ("route-" + tag + "-build.log"), manifest)
        entry = identity | {"route_profile": tag}
        if xbar:
            pin = _check_unoptflat_pins(
                data, out, tag, out / ("route-" + tag + "-build.log"),
                "native" if native else "legacy")
            entry["unoptflat_pins"] = pin
            (out / ("route-" + tag + "-unoptflat.json")).write_text(
                json.dumps({"profile": tag, "pins_file": PINS_FILE, **pin},
                           indent=2))
        builds.append(entry)
        exe = model / "test"
        # masters!=3 is the config-illegal oracle: the bench must reject the
        # illegal master count with STORAMIC_CHECKPOINT_ROUTE_CONFIG (rc!=0).
        # masters==3 non-native runs pos + oracle_negative; native bakes its
        # adversarial port-1/2 refusal into the bench (pos only).
        if masters != 3:
            cases = [("config", ())]
        elif native:
            cases = [("pos", ())]
        else:
            cases = [("pos", ()), ("neg", ("+oracle_negative",))]
        for case, args in cases:
            label = f"{tag}-{case}"
            try:
                r = subprocess.run([str(exe), *args], env=env, cwd=exe.parent,
                                   capture_output=True, text=True, timeout=120)
                text, rc = r.stdout + r.stderr, r.returncode
            except subprocess.TimeoutExpired:
                text, rc = "TIMEOUT", None
            (out / ("route-" + label + ".log")).write_text(text)
            if masters != 3:
                ok = (rc != 0 and "STORAMIC_CHECKPOINT_ROUTE_CONFIG" in text)
            elif native or case == "pos":
                ok = (rc == 0 and "CHECKPOINT_ROUTE_PASS" in text
                      and "%Error" not in text)
            else:
                ok = (rc != 0 and "CHECKPOINT_ROUTE_FAIL negative-oracle" in text)
            results.append({"case": "checkpoint-route-" + label,
                            "profile": tag, "pass": bool(ok), "rc": rc})
            outcomes.append({"checkpoint_route": label, "pass": bool(ok)})
            if not ok:
                raise RuntimeError(f"checkpoint-route {label} failed rc={rc}")
    # Prefix-mutant oracle: rebuild the route from a patched copy with the
    # trusted-master ID-prefix term dropped under ifdef G6LC_MUT_ROUTE_PREFIX
    # (production RTL is never edited). The bench's wrong-prefix masters
    # (id[7:4]!=0) then satisfy every remaining candidate term, so source_ok
    # reports 1 where 0 is expected and the run must FAIL. A clean PASS would
    # mean the prefix check is unexercised -> the stage itself fails.
    mut_rel = "corev_apu/storamic/g6lc_storamic_checkpoint_route.sv"
    route_src = (tree / mut_rel).read_text()
    cand = (
        "  assign aw_candidate = CtrlPageEn &&\n"
        "      (64'(req_i.aw.id) >> LocalIdWidth) == 64'(TrustedMaster) &&\n"
        "      req_i.aw.prot == 3'b001 && req_i.aw.cache == DataCache && !req_i.aw.lock &&\n"
        "      req_i.aw.len == 0 && req_i.aw.size == 2 && req_i.aw.atop == 0 &&\n"
        "      req_i.aw.burst <= 1 && req_i.aw.addr[1:0] == 0 &&\n"
        "      req_i.aw.addr >= Base && req_i.aw.addr - Base < 64'h1000;\n"
        "  assign ar_candidate = CtrlPageEn &&\n"
        "      (64'(req_i.ar.id) >> LocalIdWidth) == 64'(TrustedMaster) &&\n"
        "      req_i.ar.prot == 3'b001 && req_i.ar.cache == DataCache && !req_i.ar.lock &&\n"
        "      req_i.ar.len == 0 && req_i.ar.size == 2 && req_i.ar.burst <= 1 &&\n"
        "      req_i.ar.addr[1:0] == 0 &&\n"
        "      req_i.ar.addr >= Base && req_i.ar.addr - Base < 64'h1000;\n")
    mut = (
        "`ifdef G6LC_MUT_ROUTE_PREFIX\n"
        "  // BENCH MUTANT: trusted-master ID-prefix term dropped; masters are no\n"
        "  // longer restricted to prefix==TrustedMaster.\n"
        "  assign aw_candidate = CtrlPageEn &&\n"
        "      req_i.aw.prot == 3'b001 && req_i.aw.cache == DataCache &&\n"
        "      !req_i.aw.lock && req_i.aw.len == 0 && req_i.aw.size == 2 &&\n"
        "      req_i.aw.atop == 0 && req_i.aw.burst <= 1 && req_i.aw.addr[1:0] == 0 &&\n"
        "      req_i.aw.addr >= Base && req_i.aw.addr - Base < 64'h1000;\n"
        "  assign ar_candidate = CtrlPageEn &&\n"
        "      req_i.ar.prot == 3'b001 && req_i.ar.cache == DataCache &&\n"
        "      !req_i.ar.lock && req_i.ar.len == 0 && req_i.ar.size == 2 &&\n"
        "      req_i.ar.burst <= 1 && req_i.ar.addr[1:0] == 0 &&\n"
        "      req_i.ar.addr >= Base && req_i.ar.addr - Base < 64'h1000;\n"
        "`else\n" + cand + "`endif\n")
    patched = route_src.replace(cand, mut)
    if patched == route_src:
        raise RuntimeError("route prefix-mutant patch did not apply")
    mut_dir = out / "route-mut-src"
    mut_dir.mkdir(exist_ok=True)
    mut_file = mut_dir / "g6lc_storamic_checkpoint_route.sv"
    mut_file.write_text(patched)
    mut_model = out / "route-prefix-mutant"
    mut_model.mkdir()
    mut_sv = [str(mut_file) if rel == mut_rel else str(tree / rel)
              for rel in FILES
              if rel.endswith(".sv") and rel != LEGACY
              and not Path(rel).name.startswith("formal_")]
    command = [str(verilator), "--binary", "--timing", "--assert",
               "-Wno-fatal", "-Werror-LATCH", "-Werror-UNOPTFLAT",
               "-Werror-PINMISSING",
               "--top-module", "tb_g6lc_storamic_checkpoint_route",
               "-I" + str(tree),
               "-I" + str(tree / (VENDOR + "common_cells/include")),
               "-I" + str(tree / (VENDOR + "axi/include")),
               "--Mdir", str(mut_model), "-o", "test",
               "-DG6LC_MUT_ROUTE_PREFIX",
               "-GEnabled=1", "-GMasterCount=3",
               "-GUseMux=0", "-GSpillRequests=0",
               "-GUseXbar=0", "-GNativeProfile=0",
               "-GNativeMstPorts=16", "-GStoramicIdx=13",
               str(tree / "verif/tb/storamic/route_interconnect.vlt"),
               str(tree / "route-axi-setup.sv"), *mut_sv]
    command += manifest["runtime"].get("verilator_options", [])
    (out / "route-prefix-mutant-command.json").write_text(json.dumps(command))
    identity = build_model(command, mut_model,
                           out / "route-prefix-mutant-build.log", manifest)
    builds.append(identity | {"route_profile": "prefix-mutant"})
    exe = mut_model / "test"
    try:
        r = subprocess.run([str(exe)], env=env, cwd=exe.parent,
                           capture_output=True, text=True, timeout=120)
        mtext, mrc = r.stdout + r.stderr, r.returncode
    except subprocess.TimeoutExpired:
        mtext, mrc = "TIMEOUT", None
    (out / "route-prefix-mutant.log").write_text(mtext)
    ok = (mrc != 0 and "CHECKPOINT_ROUTE_FAIL" in mtext)
    results.append({"case": "checkpoint-route-prefix-mutant",
                    "profile": "prefix-mutant", "pass": bool(ok), "rc": mrc})
    outcomes.append({"checkpoint_route": "prefix-mutant", "pass": bool(ok)})
    if not ok:
        raise RuntimeError(
            f"checkpoint-route prefix-mutant not rejected rc={mrc}")
    manifest["checkpoint_route"] = {"profiles": PROFILES and [p[0] for p in PROFILES],
                                    "results": results}
    (out / "checkpoint-route-result.json").write_text(
        json.dumps({"stage": "checkpoint-route", "results": results}, indent=2))


FORMAL_INPUTS = [
    VENDOR + "axi/src/axi_pkg.sv",
    "g6lc_storamic/rtl/include/g6lc_storamic_pkg.sv",
    "corev_apu/storamic/g6lc_storamic_ctrl_bridge.sv",
    "corev_apu/storamic/g6lc_storamic_checkpoint_route.sv",
]
FORMAL_TOP = "formal_g6lc_storamic_checkpoint_route"
FORMAL_WRAPPER = "verif/tb/storamic/formal_g6lc_storamic_checkpoint_route.sv"


def _formal(data, out, manifest, builds, outcomes, verilator, build_model):
    """Replicate check_route.py's bounded formal: read_slang frontend with
    -DSYNTHESIS -DFORMAL -G Enabled -G BadOracle, prep/flatten/async2sync/
    dffunmap/write_smt2, then yosys-smtbmc -s yices -t 16. Matrix:
    (enabled0,bad0)->PASS, (enabled1,bad0)->PASS+cover, (enabled1,bad1)->FAIL."""
    tree, _ = _build_tree(data, out)
    from yosys_bin import yosys_bin
    tools = [Path(shutil.which(n) or "")
             for n in ("yosys-smtbmc", "yices-smt2")]
    if not all(t.is_file() for t in tools):
        raise FileNotFoundError("checkpoint-route-formal requires "
                                "yosys-smtbmc and yices-smt2")
    smtbmc, solver = tools
    deps = list((smtbmc.resolve().parent.parent / "share/yosys/python3")
                .glob("*.py"))
    files = {str(p.resolve()): _sha(p)
             for p in sorted([smtbmc, solver, *deps, Path(sys.executable)])}
    if "formal_tools" in manifest and files != manifest["formal_tools"]["files"]:
        raise RuntimeError("STORAMIC_FORMAL_TOOL_IDENTITY")
    manifest["formal_tools"] = {
        "files": files, "engine": "yosys-smtbmc/yices",
        "solver_version": subprocess.check_output(
            [str(solver), "--version"], text=True).strip(),
        "smtbmc_sha256": _sha(smtbmc), "yices_sha256": _sha(solver)}
    yosys = Path(yosys_bin())
    env = dict(os.environ)
    env["PATH"] = str(solver.parent) + os.pathsep + env.get("PATH", "")

    def frontend(enabled, bad):
        inputs = " ".join(str(tree / rel) for rel in FORMAL_INPUTS)
        return (f"read_slang --top {FORMAL_TOP} -DSYNTHESIS -DFORMAL "
                f"-G Enabled={enabled} -G BadOracle={bad} -I{tree} "
                + inputs + " " + str(tree / FORMAL_WRAPPER))

    def smt_for(enabled, bad, tag):
        smt = out / f"checkpoint-route-formal-{tag}.smt2"
        command = (frontend(enabled, bad) +
                   f"; prep -top {FORMAL_TOP}; flatten; async2sync; "
                   f"dffunmap; write_smt2 -wires {smt}")
        (out / f"checkpoint-route-formal-{tag}.ys").write_text(command)
        log = out / f"checkpoint-route-formal-{tag}-frontend.log"
        with log.open("w") as fh:
            subprocess.run([str(yosys), "-p", command], stdout=fh,
                           stderr=subprocess.STDOUT, check=True, timeout=300)
        return smt

    def solve(smt, tag, cover=False):
        command = [str(smtbmc), "-s", "yices", "-t", "16", "--noprogress"]
        if cover:
            command.append("-c")
        command.append(str(smt))
        result = subprocess.run(command, env=env, capture_output=True,
                                text=True, timeout=600)
        (out / f"checkpoint-route-formal-{tag}-smtbmc.log").write_text(
            result.stdout + result.stderr)
        return result.returncode, result.stdout + result.stderr

    results = []
    for enabled, bad in ((0, 0), (1, 0), (1, 1)):
        tag = f"e{enabled}-bad{bad}"
        smt = smt_for(enabled, bad, tag)
        rc, text = solve(smt, tag)
        expected = "Status: FAILED" if bad else "Status: PASSED"
        ok = ((rc != 0) if bad else (rc == 0)) and expected in text
        results.append({"case": f"checkpoint-route-formal-{tag}",
                        "pass": bool(ok), "rc": rc})
        outcomes.append({"checkpoint_route_formal": tag, "pass": bool(ok)})
        if not ok:
            raise RuntimeError(f"checkpoint-route-formal {tag} rc={rc}")
        if enabled and not bad:
            rc, text = solve(smt, tag + "-cover", cover=True)
            ok = rc == 0 and "Status: PASSED" in text
            results.append({"case": f"checkpoint-route-formal-{tag}-cover",
                            "pass": bool(ok), "rc": rc})
            outcomes.append({"checkpoint_route_formal": tag + "-cover",
                             "pass": bool(ok)})
            if not ok:
                raise RuntimeError(f"checkpoint-route-formal {tag}-cover rc={rc}")
    manifest["checkpoint_route_formal"] = {
        "depth": 16, "engine": "yosys-smtbmc/yices",
        "yosys": str(yosys), "yosys_sha256": _sha(yosys),
        "results": results}
    (out / "checkpoint-route-formal-result.json").write_text(json.dumps(
        {"stage": "checkpoint-route-formal", "results": results}, indent=2))


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    want_sim = "checkpoint-route" in stages
    want_formal = "checkpoint-route-formal" in stages
    if not (want_sim or want_formal):
        return
    if want_sim:
        _sim(data, out, manifest, builds, outcomes, verilator, build_model)
    if want_formal:
        _formal(data, out, manifest, builds, outcomes, verilator, build_model)
