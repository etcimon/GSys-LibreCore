#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# edk2-build.sh — build-platform suite for EDK2 E0 build-only scaffolding.
#
# This is a build-time witness, not a runtime boot test. It generates the
# G6lcPlatformPkg DEC/DSC/FDF/h scaffold and build script under
# g6lc_qemu/out/loader-build/ and validates the dry-run plan. A real build
# requires the pinned edk2 + edk2-platforms sources, a RISC-V cross toolchain,
# bash/make, and (on Windows) WSL.

set -euo pipefail

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: required tool '$1' not found" >&2
        exit 127
    }
}
need python3

cd "$(dirname "$0")/.."

python3 tools/g6q.py build-fw \
    --loader edk2 \
    --target g6lc64_smt2 \
    --machine g6lc-virt \
    --dry-run
