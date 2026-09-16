# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# Clone Unlicense reference trees. Pins: g6lc_bios/pins.toml [zealos] [templeos].
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
function Fetch($dir, $url) {
  $dst = Join-Path $here $dir
  if (Test-Path (Join-Path $dst ".git")) {
    git -C $dst pull --ff-only
  } else {
    git clone --depth 1 --single-branch $url $dst
  }
}
Fetch "ZealOS" "https://github.com/Zeal-Operating-System/ZealOS.git"
Fetch "TempleOS" "https://github.com/cia-foundation/TempleOS.git"
Fetch "goja" "https://github.com/dop251/goja.git"
Fetch "lirx-dom" "https://github.com/lirx-js/dom.git"
Fetch "svelte-d" "https://github.com/etcimon/svelte-d.git"
if (Test-Path (Join-Path $here "lirx-dom/.git")) {
  git -C (Join-Path $here "lirx-dom") config core.longpaths true
}
# botan: vendored tree is enough when present.
$botan = Join-Path $here "botan"
$marker = Join-Path $botan "test_data/tls_13_rfc8448/server_certificate.pem"
if (Test-Path (Join-Path $botan ".git")) {
  git -C $botan pull --ff-only
} elseif (-not (Test-Path $marker)) {
  git clone --depth 1 --single-branch "https://github.com/etcimon/botan.git" $botan
}
# libwasm is copied from riscv-compilers/libwasm (exclude tmp/, runtime-v1.*, *.a).
# Refresh: copy the tree excluding build/; do not compile it here.
