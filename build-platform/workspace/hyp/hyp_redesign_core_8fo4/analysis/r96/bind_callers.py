# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Measure selected child instances with caller-derived parameters, without RTL edits."""
import concurrent.futures
import json
from pathlib import Path

from reboard import HERE, ROOT, replay, sha


def binding(group, name, module, derive, source):
    baseline = HERE / f"boards/current-{group}.manifest.json"
    original = json.loads(baseline.read_text(encoding="utf-8"))
    command = original["argv"].copy()
    oldmap = Path(command[command.index("--param-map") + 1])
    params = json.loads(oldmap.read_text(encoding="utf-8"))
    overrides = derive(params)
    params.update(overrides)
    pmap = HERE / f"params-{name}.json"
    with pmap.open("x", encoding="utf-8") as out:
        json.dump(params, out, indent=2)
    command[command.index("--param-map") + 1] = str(pmap)
    command[command.index("--modules") + 1] = module
    hashes = {n: h for n, h in original["sha256"].items()
              if Path(n).resolve() != oldmap.resolve()}
    hashes[pmap.as_posix()] = sha(pmap)
    spec = HERE / f"binding-{name}.manifest.json"
    with spec.open("x", encoding="utf-8") as out:
        json.dump(dict(group=name, argv=command, sha256=hashes,
                       source_manifest_sha256=sha(baseline),
                       binding_source=source, overrides=overrides), out, indent=2)
    board = json.loads((HERE / f"boards/current-{group}.json").read_text(encoding="utf-8"))
    return dict(manifest=spec.relative_to(ROOT).as_posix(), versions=board["versions"])


def tag_params(p):
    line_bytes = p["LINE_WIDTH"] // 8
    sets = p["BYTE_SIZE"] // (line_bytes * p["SET_ASSOC"])
    assert line_bytes > 0 and line_bytes & (line_bytes - 1) == 0
    assert sets > 0 and sets & (sets - 1) == 0
    index = max(1, (sets - 1).bit_length())
    offset = (line_bytes - 1).bit_length()
    return dict(NUM_SETS=sets, IDX_WIDTH=index,
                TAG_WIDTH=p["AXI_ADDR_WIDTH"] - index - offset,
                PF_TAG=p["PF_EN"])


def rename_params(p):
    assert p["G6LCCfg.OoOEn"] == 1 and p["G6LCCfg.FpPresent"] == 1
    assert p["G6LCCfg.NrIssuePorts"] == 2 and p["G6LCCfg.NrHarts"] == 1
    assert p["G6LCCfg.NR_SB_ENTRIES"] == 32
    # User package: RobEntries=PrfEntries=0 and BPCkptDepth=32.
    # build_config_pkg: automatic ROB/PRF sizing; dispatch supplies FP sizing.
    np = p["G6LCCfg.NrIssuePorts"]
    nh = p["G6LCCfg.NrHarts"]
    rob = max(p["G6LCCfg.NrScoreboardEntries"], np * 16)
    prf = 32 + rob + np * 4
    fprf = 32 * nh + rob + 8
    return dict(PRF_ENTRIES=prf, PRF_W=max(1, (prf - 1).bit_length()),
                NR_PORTS=np, NR_HARTS=nh, CKPT_DEPTH=32,
                FPRF_ENTRIES=fprf, FPRF_W=max(1, (fprf - 1).bit_length()),
                FL_BANKS=p["HypCfg.FreelistBanks"])


if __name__ == "__main__":
    specs = [
        binding(group, f"{group}-tag-bound", "g6lc_l2_tag", tag_params,
                "g6lc_l2_top.sv:473-476,588-596; g6lc_l2_pkg.sv:17-33")
        for group in ("l2", "l3")]
    specs.append(binding(
        "core-all", "rename-bound", "g6lc_rename_read", rename_params,
        "g6lc64_hyp8_config_pkg.sv:99,184,291-292; build_config_pkg.sv:411-418; "
        "g6lc_ooo_dispatch.sv:142-154,489-500; g6lc_rename.sv:346-350"))
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        for future in [pool.submit(replay, spec) for spec in specs]:
            future.result()
