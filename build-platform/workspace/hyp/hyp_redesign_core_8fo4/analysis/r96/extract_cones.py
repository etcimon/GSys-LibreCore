# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Capture path nodes and relocation cards; this does not prove path sensitization."""
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
SELECT = {
    "core-all": [
        "fpnew_fma", "fpnew_fma_multi", "norm_div_sqrt_mvp",
        "g6lc_flu_reserve", "csr_regfile", "store_unit", "serdiv",
        "g6lc_decode_s3", "g6lc_rename_read", "load_unit", "g6lc_loop_buffer",
        "g6lc_ai_exec", "wt_dcache_wbuffer", "g6lc_lsq", "g6lc_iq",
    ],
    "l3": ["g6lc_l2_top", "g6lc_l2_tag", "g6lc_l2_mshr",
           "g6lc_l2_wtrk", "g6lc_l2_rdtrk"],
    "ai": ["g6lc_ai_gemm_seq", "g6lc_ai_desc_engine", "g6lc_ai_gemm_fp32_norm",
           "g6lc_ai_gemm_fp32_align", "g6lc_ai_island_top",
           "g6lc_ai_pe_dot_float_pipe", "g6lc_ai_cluster_dispatch"],
    "coh": ["g6lc_coherence_hub", "g6lc_inval_bus",
            "g6lc_cmo_engine", "g6lc_snoop_filter"],
}


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    output = HERE / "cones.json"
    if output.exists():
        raise RuntimeError("refusing to overwrite captured analysis")
    rows, inputs = [], {}
    for group, names in SELECT.items():
        stem = HERE / "boards" / ("current-" + group)
        irfile = stem.with_suffix(".ir.json")
        boardfile = stem.with_suffix(".json")
        ir, board = read(irfile), read(boardfile)
        inputs[group] = {"ir_sha256": digest(irfile),
                         "report_sha256": digest(boardfile),
                         "manifest_sha256": digest(stem.with_suffix(".manifest.json"))}
        modules = ir["modules"]
        if isinstance(modules, dict):
            modules = list(modules.values())
        for name in names:
            module = next(m for m in modules if m["name"] == name)
            nodes = module["nodes"]
            nodes = {int(k): n for k, n in nodes.items()} if isinstance(nodes, dict) else {
                n["id"]: n for n in nodes}
            paths = sorted((p for p in ir["paths"]
                            if p["module"] == module["id"] and p.get("total_fo4") is not None),
                           key=lambda p: -p["total_fo4"])
            kinds = {}
            for path in paths:
                kinds.setdefault(path["path_kind"], path)
            selected = {p["id"]: p for p in [*paths[:4], *kinds.values()]}
            row = {"profile": group, "module": name, "file": module["file"],
                   "paths": [dict(p, node_details=[nodes[n] for n in p["nodes"]])
                             for p in selected.values()],
                   "max_by_kind": {k: {"id": p["id"], "fo4": p["total_fo4"]}
                                   for k, p in kinds.items()}}
            rows.append(row)
            top = paths[0]
            print(group, name, round(top["total_fo4"], 2), top["path_class"])
            print(" -> ".join(f"{nodes[n].get('lhs')}@{nodes[n]['loc']['start_line']}"
                              f"({nodes[n]['fo4_cost']:.1f})"
                              for n in top["nodes"]))
        # Preserve the analyzer's actual relocation suggestions separately.
        inputs[group]["relocation_plan"] = board["relocation_plan"]
        inputs[group]["stage_bubbles"] = board["stage_bubbles"]
    output.write_text(json.dumps({"schema": "hyp8-r96-cones.v1",
                                 "inputs": inputs, "modules": rows}, indent=2),
                      encoding="utf-8")


if __name__ == "__main__":
    main()
