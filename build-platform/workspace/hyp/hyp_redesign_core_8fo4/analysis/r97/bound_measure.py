# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Measure frozen original and live candidate with source-derived FLU dimensions."""
import concurrent.futures
import os
from pathlib import Path
import subprocess
from measure import HERE, ROOT, FLU, TEMPLATE, read, write, sha


def screen(phase, ports):
    original = read(TEMPLATE)
    command = original["argv"].copy()
    oldlist = Path(command[command.index("--files-from") + 1])
    oldmap = Path(command[command.index("--param-map") + 1])
    params = read(oldmap)
    # The captured scalar configuration and build_config_pkg:206,222 establish
    # these port dimensions. Eight issue ports is a leaf scaling experiment.
    live = read(HERE.parent / "elaborated-scalar-param-map.json")
    assert live["G6LCCfg.TRANS_ID_BITS"] == 5 and live["G6LCCfg.NrWbPorts"] == 4
    assert params["G6LCCfg.NR_SB_ENTRIES"] == 32
    params.update({"G6LCCfg.TRANS_ID_BITS": 5, "G6LCCfg.NrWbPorts": 4,
                   "G6LCCfg.NrIssuePorts": ports, "NIP": ports})
    wbc = params["HypCfg.WbCaptureStages"]
    alu = params["HypCfg.AluStages"]
    stagger = alu >= 2 and params["HypCfg.AluStaggered"] != 0
    mul = params["HypCfg.MultStagesOverride"] or params["G6LCCfg.MultStages"]
    reswin = 2 + max(mul, alu, 2) + wbc
    lowcyc, fullcyc, mulcyc = (2 if stagger else 1) + wbc, (alu if stagger else 1) + wbc, mul + wbc
    assert (reswin, lowcyc, fullcyc, mulcyc) == (10, 2, 3, 8)
    params.update(RES_WIN=reswin, OFF_W=(reswin - 1).bit_length(),
                  WBC=wbc, STAGGER=int(stagger), LOW_CYC=lowcyc,
                  FULL_CYC=fullcyc, MUL_CYC=mulcyc,
                  LOW_MASK=1 << (1 + lowcyc), FULL_MASK=1 << (1 + fullcyc),
                  MUL_MASK=1 << (1 + mulcyc), BR_MASK=1 << (3 + wbc),
                  ONE_MASK=1 << (2 + wbc))
    stem = HERE / "boards" / f"bound-{phase}-p{ports}"
    pmap = HERE / f"bound-params-{phase}-p{ports}.json"
    write(pmap, params)
    target = HERE / "g6lc_flu_reserve.before.sv" if phase == "before" else FLU
    flist = HERE / f"bound-{phase}-p{ports}.f"
    lines = []
    replacements = 0
    for line in oldlist.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or line.startswith("+define+"):
            lines.append(line)
        elif line.startswith("+incdir+"):
            lines.append("+incdir+" + (oldlist.parent / line[8:]).resolve().as_posix())
        elif line.startswith("+"):
            raise ValueError(f"unhandled flist directive {line}")
        else:
            path = (oldlist.parent / line).resolve()
            if path == FLU.resolve():
                path = target.resolve()
                replacements += 1
            lines.append(path.as_posix())
    assert replacements == 1
    with flist.open("x", encoding="utf-8") as out:
        out.write("\n".join(lines) + "\n")
    command[command.index("--files-from") + 1] = str(flist)
    command[command.index("--param-map") + 1] = str(pmap)
    command[command.index("--modules") + 1] = "g6lc_flu_reserve"
    for flag, suffix in (("--json-out", ".json"), ("--ir-out", ".ir.json")):
        command[command.index(flag) + 1] = str(stem.with_suffix(suffix))
    replaced = {oldmap.resolve(), oldlist.resolve(), FLU.resolve()}
    inputs = [Path(p) for p in original["sha256"] if Path(p).resolve() not in replaced]
    inputs += [flist, pmap, target]
    hashes = {p.as_posix(): sha(p) for p in inputs}
    with stem.with_suffix(".log").open("x", encoding="utf-8") as out:
        out.write(str(command) + "\n")
        out.flush()
        result = subprocess.run(command, cwd=ROOT, stdout=out, stderr=subprocess.STDOUT,
                                env=dict(os.environ, RUST_MIN_STACK="16777216"))
    assert all(sha(p) == digest for p, digest in hashes.items())
    write(stem.with_suffix(".manifest.json"),
          dict(argv=command, sha256=hashes, phase=phase, ports=ports,
               source_sha256=sha(target), returncode=result.returncode,
               binding="source-derived local constants; 8 ports is leaf-only"))
    assert result.returncode == 0
    board = read(stem.with_suffix(".json"))
    assert board["versions"] == read(HERE / "boards/before-scalar.json")["versions"]
    assert not board["skipped_files"]
    module = next(m for m in board["modules"] if m["name"] == "g6lc_flu_reserve")
    paths = [p for p in board["paths"] if p["module_id"] == module["id"]]
    by_kind = {}
    for p in paths:
        k = p["path_kind"]
        if k not in by_kind or p["total_fo4"] > by_kind[k]["total_fo4"]:
            by_kind[k] = p
    write(stem.with_suffix(".summary.json"),
          dict(max_by_kind=by_kind, maximum=max(p["total_fo4"] for p in paths),
               versions=board["versions"], budget_fo4=board["budget_fo4"],
               fo4_ps=board["fo4_ps"], report_sha256=sha(stem.with_suffix(".json"))))
    print(phase, ports, {k: p["total_fo4"] for k, p in by_kind.items()}, flush=True)


if __name__ == "__main__":
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(screen, phase, ports)
                   for phase in ("before", "after") for ports in (2, 8)]
        for future in futures:
            future.result()
