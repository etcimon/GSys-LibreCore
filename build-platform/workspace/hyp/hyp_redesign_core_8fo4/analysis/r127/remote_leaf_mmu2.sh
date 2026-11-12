#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# mmu leaf on the remote toolchain under a fresh run tag (a reused tag keeps
# the previously uploaded runner script).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEAF_RUN="${1:-t2}" bash "$HERE/remote_leaf.sh" r127m mmu
