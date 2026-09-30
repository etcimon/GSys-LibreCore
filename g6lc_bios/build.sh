#!/bin/sh
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
cd "$(dirname "$0")" || exit 1
exec python tools/build.py "$@"
