# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Thin wrapper — all logic lives in tools/svt.py (see AGENTS-toolchain.md).
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgsRemain
)
$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script = Join-Path $Here "tools\svt.py"

function Find-Python {
    foreach ($c in @(
        @{ Exe = "py"; Args = @("-3", $Script) },
        @{ Exe = "python"; Args = @($Script) },
        @{ Exe = "python3"; Args = @($Script) }
    )) {
        $cmd = Get-Command $c.Exe -ErrorAction SilentlyContinue
        if ($cmd) {
            return @{ Exe = $cmd.Source; Prefix = $c.Args }
        }
    }
    return $null
}

$py = Find-Python
if (-not $py) {
    Write-Error "[svt.ps1] need Python 3 on PATH (py -3, python, or python3)"
    exit 1
}
$all = @($py.Prefix) + @($ArgsRemain)
& $py.Exe @all
exit $LASTEXITCODE
