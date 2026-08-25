#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Thin wrapper for verif/regress/remote/testharness_proxy.py.
#
# Typical first-time flow (each step is idempotent):
#   bash verif/regress/remote-testharness.sh doctor
#   bash verif/regress/remote-testharness.sh setup
#   bash verif/regress/remote-testharness.sh sync
#   bash verif/regress/remote-testharness.sh build B
#   bash verif/regress/remote-testharness.sh build legacy
#
# Per-test (uploads only the ELF):
#   bash verif/regress/remote-testharness.sh run /path/to/mini.elf --flavour B
#
# A/B soak pair:
#   bash verif/regress/remote-testharness.sh soak --flavour B
#   bash verif/regress/remote-testharness.sh soak --flavour legacy
#
# Credentials: the key passphrase is read from $TH_SSH_PASSPHRASE or from an
# untracked file (~/.config/librecore/th-remote.pass). It is never stored in
# the repository. See AGENTS-build.md "Remote testharness".
#
# Map: architecture/multi-threading/soft-ladder/firmware-boot-principles.md §4

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec python3 "$ROOT/verif/regress/remote/testharness_proxy.py" "$@"
