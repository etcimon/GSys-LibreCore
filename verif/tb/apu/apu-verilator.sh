#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# The real compiler binding is supplied/revalidated by local-verilator.sh.
exec python3 -B "$(dirname "$0")/apu_sim_pgo.py" "$@"
