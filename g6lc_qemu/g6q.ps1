# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Thin wrapper -> tools/g6q.py. NO BUSINESS LOGIC HERE (AGENTS.md section 4).
# If you are about to add a branch to this file, port it to tools/g6q.py instead.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$entry = Join-Path $here 'tools/g6q.py'

foreach ($py in @('python3', 'python', 'py')) {
    $cmd = Get-Command $py -ErrorAction SilentlyContinue
    if ($cmd) {
        & $cmd.Source $entry @args
        exit $LASTEXITCODE
    }
}

Write-Error 'g6q: no python3/python/py on PATH'
exit 1
