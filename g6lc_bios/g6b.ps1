# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# Thin wrapper — logic lives in tools/g6b.py
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
python "$here\tools\g6b.py" @args
exit $LASTEXITCODE
