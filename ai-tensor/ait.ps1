# Thin wrapper → tools/ait.py
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
& python $Root/tools/ait.py @args
exit $LASTEXITCODE
