#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Compatibility wrapper. Overlays live in patches/ and are applied onto
# the official OpenWrt tree by apply-patches.sh (never the etcimon forks).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$HERE/apply-patches.sh"
