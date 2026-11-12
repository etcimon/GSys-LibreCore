#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# One hyp8 leaf on the remote leaf toolchain (the leaf of record), from an
# integration closure directory built by verif/regress/remote/hyp8/build_closure.py.
#   bash analysis/r127/remote_leaf.sh <closure-tag> <leaf> [--env K=V ...]
# The leaf runner's default compiler (/opt/testharness/src/verilator-causal) is
# gone from the host, so the integration toolchain is named explicitly together
# with ITS runtime and digest (run_hyp8_memory.py honours HYP8_RUNTIME_DIR /
# HYP8_RUNTIME_DIGEST since r127; a driver/runtime mismatch fails to compile).
TC=/opt/testharness/toolchains/verilator-v5.008-g6lc-44063db8-pgo
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
TAG="${1:?closure tag}"; LEAF="${2:?leaf}"; shift 2
L="$ROOT/build-platform/workspace/build/r127-remote"; mkdir -p "$L"
cd "$ROOT"
python3 verif/regress/remote/testharness_proxy.py --timeout 0 py --tag "hyp8-$TAG-leaf-$LEAF${LEAF_RUN:+-$LEAF_RUN}" --threads 1 --env HYP8_ALLOW_OVERLAP=1 --env HYP8_LEAF="$LEAF" --env HYP8_VERILATOR_DIR=$TC --env HYP8_RUNTIME_DIR=$TC/runtime --env HYP8_RUNTIME_DIGEST=e900ec451629715860e4faffdce5127f5f118ddcaa433125b79f12d3cbb718f8 "$@" --data "build-platform/workspace/build/closure-$TAG" --pull --pull-exclude-build --dest "remote-runs/hyp8-$TAG-leaf-$LEAF${LEAF_RUN:+-$LEAF_RUN}" verif/regress/remote/run_hyp8_memory.py > "$L/$TAG.leaf-$LEAF.log" 2>&1
echo "leaf rc=$?" >> "$L/$TAG.leaf-$LEAF.log"
D="$HOME/cva6-remote-runs/hyp8-$TAG-leaf-$LEAF${LEAF_RUN:+-$LEAF_RUN}"
grep -a -h -E "HYP8_[A-Z_]*PASS|FAIL [A-Z_]+|%Fatal|RuntimeError|AssertionError|FileNotFoundError" "$D"/*.log 2>/dev/null | head -6 | cut -c1-200
grep -a -m2 -E "%Error|error:" "$D/build-model.log" 2>/dev/null | cut -c1-200
tail -1 "$L/$TAG.leaf-$LEAF.log"
