#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Remote integration + smokes of a hyp8 closure on the fork PGO toolchain
# (the r126 recipe, single model thread, no sim-PGO: a smoke gate, not a
# witness model). Never touches other workloads (HYP8_ALLOW_OVERLAP=1).
#   bash analysis/r127/remote_gate.sh <tag> [extra --env KEY=VAL ...]
# Reads build-platform/workspace/build/closure-<tag>; writes
# remote-runs/hyp8-<tag>-{aggregate,smokes}-t1 and
# build-platform/workspace/build/r127-remote/<tag>.{aggregate,smokes}.log
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
TAG="${1:?usage: remote_gate.sh <tag> [--env K=V ...]}"; shift
TC=/opt/testharness/toolchains/verilator-v5.008-g6lc-44063db8-pgo
L="$ROOT/build-platform/workspace/build/r127-remote"; mkdir -p "$L"
cd "$ROOT"
python3 verif/regress/remote/testharness_proxy.py --timeout 0 py --tag "hyp8-$TAG-aggregate-t1" --threads 1 \
  --env HYP8_ALLOW_OVERLAP=1 --env HYP8_VERILATOR_DIR=$TC --env HYP8_RUNTIME_DIR=$TC/runtime \
  --env HYP8_RUNTIME_DIGEST=e900ec451629715860e4faffdce5127f5f118ddcaa433125b79f12d3cbb718f8 \
  --env HYP8_VERILATOR_FLAVOUR=g6lc --env HYP8_VERILATOR_THREADS=1 --env HYP8_BUILD_JOBS=6 \
  --env HYP8_BUILD_TIMEOUT=14400 "$@" \
  --data "build-platform/workspace/build/closure-$TAG" --pull --pull-exclude-build \
  --dest "remote-runs/hyp8-$TAG-aggregate-t1" verif/regress/remote/run_hyp8_integration.py \
  > "$L/$TAG.aggregate.log" 2>&1
echo "aggregate rc=$?" >> "$L/$TAG.aggregate.log"
python3 verif/regress/remote/testharness_proxy.py --timeout 0 py --tag "hyp8-$TAG-smokes-t1" --threads 1 \
  --env HYP8_INT_TAG="hyp8-$TAG-aggregate-t1" --env HYP8_ALLOW_OVERLAP=1 \
  --pull --dest "remote-runs/hyp8-$TAG-smokes-t1" verif/regress/remote/run_hyp8_smokes.py \
  > "$L/$TAG.smokes.log" 2>&1
echo "smokes rc=$?" >> "$L/$TAG.smokes.log"
{ python3 - <<PY
import json
r=json.load(open("remote-runs/hyp8-$TAG-aggregate-t1/results.json"))
print("status", r["status"], "lint", {k:(v["rc"], v["warnings"].get("%Error",0)) for k,v in r["lint"].items()}, "model", str(r.get("build",{}).get("modelSha256"))[:16])
PY
cat "remote-runs/hyp8-$TAG-smokes-t1/run_hyp8_smokes.log"; echo REMOTE_GATE_DONE; } > "$L/$TAG.summary.txt" 2>&1
