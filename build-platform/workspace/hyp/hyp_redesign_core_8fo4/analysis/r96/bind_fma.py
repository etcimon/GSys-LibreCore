# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bind the two live FMA formats, including derived constants the parser did not resolve."""
import concurrent.futures
import json
from pathlib import Path

from reboard import HERE, ROOT, replay, sha


def prepare(name, fmt, exp, mant):
    baseline = HERE / "boards/current-core-all.manifest.json"
    record = json.loads(baseline.read_text(encoding="utf-8"))
    command = record["argv"].copy()
    oldmap = Path(command[command.index("--param-map") + 1])
    params = json.loads(oldmap.read_text(encoding="utf-8"))
    assert params["HypCfg.FpuLatOverride"] == 1
    precision = mant + 1
    lower = 2 * precision + 3
    lzc = (lower - 1).bit_length()
    # fpnew_fma.sv:60-95; fpnew_pkg format definitions and pipe_config_t.
    params.update(FpFormat=fmt, NumPipeRegs=8, PipeConfig=3,
                  WIDTH=1 + exp + mant, ExtRegEnaWidth=8,
                  EXP_BITS=exp, MAN_BITS=mant, BIAS=(1 << (exp - 1)) - 1,
                  PRECISION_BITS=precision, LOWER_SUM_WIDTH=lower,
                  LZC_RESULT_WIDTH=lzc, EXP_WIDTH=max(exp + 2, lzc),
                  SHIFT_AMOUNT_WIDTH=(3 * precision + 4).bit_length(),
                  NUM_INP_REGS=3, NUM_MID_REGS=3, NUM_OUT_REGS=2)
    pmap = HERE / ("params-" + name + ".json")
    with pmap.open("x", encoding="utf-8") as out:
        json.dump(params, out, indent=2)
    command[command.index("--param-map") + 1] = str(pmap)
    command[command.index("--modules") + 1] = "fpnew_fma"
    hashes = {n: h for n, h in record["sha256"].items()
              if Path(n).resolve() != oldmap.resolve()}
    hashes[pmap.as_posix()] = sha(pmap)
    spec = HERE / ("binding-" + name + ".manifest.json")
    with spec.open("x", encoding="utf-8") as out:
        json.dump(dict(group=name, argv=command, sha256=hashes,
                       source_manifest_sha256=sha(baseline),
                       derived_constants_source="core/cvfpu/src/fpnew_fma.sv:60-95",
                       expected_product_width=2 * precision), out, indent=2)
    board = json.loads((HERE / "boards/current-core-all.json").read_text(encoding="utf-8"))
    return {"manifest": spec.relative_to(ROOT).as_posix(),
            "versions": board["versions"]}


if __name__ == "__main__":
    specs = [prepare("fma-fp32", 0, 8, 23), prepare("fma-fp64", 1, 11, 52)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        for future in [pool.submit(replay, spec) for spec in specs]:
            future.result()
