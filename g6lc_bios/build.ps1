# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# Thin wrapper — logic lives in tools/build.py
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
python "$here\tools\build.py" @args
exit $LASTEXITCODE
