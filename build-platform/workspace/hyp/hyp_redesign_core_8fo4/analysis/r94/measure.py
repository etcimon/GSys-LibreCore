# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""Pinned delay-v49 census/candidate boards for Hyp OoO, coherence, L2/L3 and AI."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
CORE = HERE.parent.parent
ROOT = HERE.parents[5]
APU = CORE.parent / "hyp_redesign_corev_apu_8fo4"
BIN = ROOT / "sv-timing/target/release/sv-timing.exe"
BOARD = HERE / "boards"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def names(paths):
    return sorted(set(n for p in paths for n in re.findall(
        r"^\s*module\s+([A-Za-z_]\w*)", p.read_text(encoding="utf-8"), re.M)))


def prepare():
    BOARD.mkdir(exist_ok=True)
    # Preserve the materialized closure, adding later AI helper extractions.
    lines = []
    sources = []
    for line in (APU / "Flist.hyp8_apu").read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        s = s.replace("${HYP_CORE_DIR}", CORE.as_posix()).replace(
            "${HYP_APU_DIR}", APU.as_posix())
        lines.append(s)
        if not s.startswith("+"):
            assert Path(s).is_file(), s
            sources.append(Path(s))
    for p in sorted((APU / "corev_apu/ai_island").glob("*.sv")):
        if p not in sources:
            sources.append(p)
            lines.append(p.as_posix())
    (HERE / "apu.f").write_text("\n".join(lines) + "\n", encoding="utf-8")
    base = json.loads((CORE / "analysis/r88-param-map.json").read_text())
    common = dict(AXI_ADDR_WIDTH=64, AXI_DATA_WIDTH=64, AXI_ID_WIDTH=4,
                  AXI_USER_WIDTH=1)
    cache = dict(common, Enable=1, LINE_WIDTH=512, DATA_BANKS=4, RR_EN=0,
                 FAIR_WRITES=1, TAG_SRAM=1, WRITE_UPDATE=1, POSTED_WRITES=1,
                 WTRK_DEPTH=4, RDTRK_DEPTH=4, PF_EN=0)
    ai = dict(AddrWidth=64, DataWidth=64, AxiDataWidth=64, IdWidth=4, AxiIdWidth=4,
              PeLanes=512, Lanes=512, OutCols=1, MaxDim=1024, MaxM=1024,
              MaxN=512, MaxK=512, MaxAROut=2, MaxElementBytes=4,
              DotPipeInt=1, DotPipeFloat=1, ReuseAEn=0, ReuseBEn=0,
              NrChannels=1, ChanShift=6)
    ai.update({"AiCfg.MatrixEn": 1, "AiCfg.IslandFpEn": 1,
               "AiCfg.VaTurboEn": 0, "AiCfg.DmaInvalEn": 1,
               "AiCfg.PolicyCodecEn": 0, "AiCfg.PolicyBenefitEn": 0,
               "AiCfg.PolicySubcodeEn": 0, "AiCfg.PolicySubcodeCacheEn": 0,
               "IslandCfg.Clusters": 1, "IslandCfg.MacsPerCycle": 512,
               "IslandCfg.AccTileM": 1024, "IslandCfg.AccTileN": 512,
               "IslandCfg.AccTileK": 512, "IslandCfg.DramChannels": 1,
               "IslandCfg.DramChanShift": 6, "IslandCfg.MaxAROut": 2})
    uncore = APU / "corev_apu"
    core_names = names(list((CORE / "core").glob("*.sv")) +
                       list((CORE / "core/ooo").glob("*.sv")))
    cache_names = names(list((uncore / "l2_cache").glob("*.sv")) +
                        list((uncore / "l3_cache").glob("*.sv")))
    cache_names = [n for n in cache_names if n not in {
        "g6lc_l2_pf", "g6lc_server_prefetcher", "g6lc_l3_inclusive_inv"}]
    ai_names = [n for n in names((uncore / "ai_island").glob("*.sv")) if n not in {
        "g6lc_ai_pe_dot", "g6lc_ai_pe_dot_float"}]  # Non-live arithmetic oracles.
    jobs = {
        "core": (CORE / "analysis/timing/hyp8-core.f", base, core_names),
        "coh": (HERE / "apu.f", dict(common, NR_CORES=4, NR_ENTRIES=128,
                 SNOOP_FILTER_EN=1, SNOOP_FILTER_ENTRIES=128, INVAL_DEPTH=4,
                 LINE_BYTES=64, AXI_STARVE_LIMIT=16, MAX_OUTSTANDING=4,
                 POLICY=2, ACK_AFTER_INVAL=1, INV_APPLY_LATENCY=1),
                names((uncore / "coherence").glob("*.sv"))),
        "l2": (HERE / "apu.f", dict(cache, BYTE_SIZE=262144, SET_ASSOC=8,
                                   MSHR_DEPTH=2), cache_names),
        "l3": (HERE / "apu.f", dict(cache, BYTE_SIZE=1048576, SET_ASSOC=16,
                                   MSHR_DEPTH=4), cache_names),
        "ai": (HERE / "apu.f", ai, ai_names),
    }
    return jobs


def measure(group, spec, phase, only):
    flist, params, modules = spec
    if only:
        modules = [n for n in modules if n in only]
        if not modules:
            return None
    stem = BOARD / f"{phase}-{group}"
    assert not stem.with_suffix(".json").exists(), "Do not overwrite evidence"
    pmap = HERE / f"params-{group}.json"
    pmap.write_text(json.dumps(params, indent=2) + "\n", encoding="utf-8")
    sources = []
    for line in flist.read_text(encoding="utf-8").splitlines():
        if line.strip() and not line.lstrip().startswith(("#", "+")):
            sources.append((flist.parent / line.strip()).resolve())
    hashes = {p.as_posix(): sha(p) for p in set(sources + [BIN, flist, pmap])}
    command = [
        str(BIN), "analyze", "--files-from", str(flist),
        "--modules", ",".join(modules), "--param-map", str(pmap),
        "--assume-xlen", "64", "--package-mode", "packages", "--stages",
        "--target-mhz", "5000", "--fo4-ps", "20", "--budget-margin", "0.2",
        "--json-out", str(stem.with_suffix(".json")),
        "--ir-out", str(stem.with_suffix(".ir.json")),
    ]
    with stem.with_suffix(".log").open("w", encoding="utf-8") as log:
        log.write(json.dumps(command) + "\n")
        log.flush()
        run = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                             env=dict(os.environ, RUST_MIN_STACK="16777216"))
    assert all(sha(Path(p)) == h for p, h in hashes.items()), "Input changed"
    manifest = dict(group=group, phase=phase, argv=command,
                    returncode=run.returncode, sha256=hashes)
    stem.with_suffix(".manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    if run.returncode:
        raise RuntimeError(f"{stem.name}: exit {run.returncode}; see log")
    report = json.loads(stem.with_suffix(".json").read_text())
    assert report["versions"]["measurement"] == "delay-v49", report["versions"]
    assert not report["skipped_files"], report["skipped_files"]
    mods = {m["id"]: m["name"] for m in report["modules"]}
    peaks = {}
    for path in report["paths"]:
        n = mods[path["module_id"]]
        if n not in peaks or path["total_fo4"] > peaks[n]["total_fo4"]:
            peaks[n] = path
    stem.with_suffix(".peaks.json").write_text(
        json.dumps(dict(sorted(peaks.items(), key=lambda x: -x[1]["total_fo4"])),
                   indent=2) + "\n", encoding="utf-8")
    print(stem.name, [(n, round(p["total_fo4"], 2)) for n, p in
                     sorted(peaks.items(), key=lambda x: -x[1]["total_fo4"])[:8]],
          flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase")
    parser.add_argument("--groups", default="core,coh,l2,l3,ai")
    parser.add_argument("--modules", default="")
    args = parser.parse_args()
    assert re.fullmatch(r"[a-zA-Z0-9-]+", args.phase)
    jobs = prepare()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        pending = [pool.submit(measure, group, jobs[group], args.phase,
                               set(args.modules.split(",")) if args.modules else set())
                   for group in args.groups.split(",")]
        for future in pending:
            future.result()
