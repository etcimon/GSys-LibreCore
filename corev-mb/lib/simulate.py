# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# simulate.py — entry point for `mb simulate <board> --scenario <name>`.
#
#   python corev-mb/lib/simulate.py <boardid> <scenario> [<scenario> ...]
#
# Reads boards/<id>/circuit.json and boards/<id>/sim/<scenario>.json, writes
# boards/<id>/outputs/sim/<scenario>.json with the revision-bound result.
# Exit 0 = every scenario passed, 1 = a scenario failed, 4 = incomplete.

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import simulation  # noqa: E402
from circuit import load_circuit  # noqa: E402


def repo_root() -> Path:
    return Path(os.environ.get("CVA6_REPO_DIR", os.getcwd()))


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: simulate.py <boardid> <scenario> [<scenario> ...]")
        return 2
    boardid, names = argv[0], argv[1:]
    board = repo_root() / "corev-mb" / "boards" / boardid
    circuit_file = board / "circuit.json"
    if not circuit_file.exists():
        print(f"[corev-mb] no circuit.json for {boardid}; run `mb ingest --from <bundle>/platform.json` first")
        return 4
    circuit = load_circuit(circuit_file)
    out_dir = board / "outputs" / "sim"
    out_dir.mkdir(parents=True, exist_ok=True)
    worst = 0
    for name in names:
        scenario_file = board / "sim" / f"{name}.json"
        if not scenario_file.exists():
            print(f"[corev-mb] scenario {name}: missing {scenario_file}")
            worst = max(worst, 4)
            continue
        scenario = simulation.load_scenario(scenario_file)
        result = simulation.run_scenario(
            circuit,
            scenario,
            out_dir,
            ngspice=os.environ.get("NGSPICE_BIN") or None,
            timeout=float(os.environ.get("SIM_TIMEOUT_SEC", "120")),
        )
        (out_dir / f"{name}.json").write_text(json.dumps(result.as_dict(), indent=2) + "\n")
        print(f"[corev-mb] scenario {name}: {result.status.upper()} — {result.reason}")
        for mname, row in result.measurements.items():
            print(f"[corev-mb]   {mname:16} = {row['value']}  [{row.get('min')}, {row.get('max')}] {'ok' if row['ok'] else 'OUT'}")
        worst = max(worst, {"pass": 0, "fail": 1, "incomplete": 4}[result.status])
    return worst


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
