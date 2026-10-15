# CTS on the Venus→RTL path (CTS-0)

Runs a pinned Khronos VK-GL-CTS must-pass subset on the Venus device
inside the stock riscv64 guest, against the Verilator bridge RTL.

## Pin

- `specs/VK-GL-CTS` — submodule, `vulkan-cts-1.4.6.2`
  (`f6a29701220f34dd1407513bfe80d74ca7b392ce`), `update = none`.
- Caselist `caselists/cts0-info-smoke.txt` — 308 exact must-pass names
  (`dEQP-VK.info.*`, `dEQP-VK.api.smoke.*`, `dEQP-VK.api.device_init.*`,
  `dEQP-VK.api.object_management.single.*`), sha256 `0393d069…`.
  `build-deqp.sh` regenerates it from the pin with
  `cts_ledger.py select` and fails on drift — the file can never
  silently disagree with the submodule.

## Toolchain (riscv64 guest payload)

- Bootlin `riscv64-lp64d--glibc--stable-2024.05-1`
- URL: <https://toolchains.bootlin.com/downloads/releases/toolchains/riscv64-lp64d/tarballs/riscv64-lp64d--glibc--stable-2024.05-1.tar.xz>
- sha256: `78e16f3def8b2ff3da09c16155f993ac7e4dc1791d0904ada03fcb2e04910aab`
  (verified against the `.sha256` published beside the tarball)
- Extracted to `.cache/cts/toolchain/bootlin-2024.05-1/` (gcc 13.3.0,
  buildroot sysroot).

## Build

    verif/tb/apu/bridge/guest/cts/build-deqp.sh

- Fetches `external/*/src` (`fetch_sources.py`; recorded in
  `.cache/cts/fetch-revisions.txt`), builds native x86 `deqp-vk`
  (control run of the 308-case list on host llvmpipe,
  `-DDEQP_TARGET=default`) and riscv64 `deqp-vk`
  (`-DDEQP_TARGET=vulkan_headless` — the pinned cross target:
  `targets/vulkan_headless` sets `DEQP_USE_HEADLESS=ON`, giving the
  `tcuLnxPlatform` Vulkan path with no X11/EGL/GLES dependency;
  `default` falls back to the Null platform because the Bootlin
  sysroot ships no X11/XCB/Wayland headers — `CMAKE_BUILD_TYPE=Release
  -DDEQP_DISABLE_VK_VIDEO_TESTS=ON`; video is honestly NotSupported).
- Packages `.cache/cts/deqp-riscv64-<cts12>.tar.zst` (+ `.sha256`) and
  builds `.cache/cts/ctsdata.img` (ext4, label `CTSDATA`) via
  `mkfs.ext4 -d` — unprivileged.
- Build key: `{CTS commit, toolchain sha256}`; never rebuilt for RTL
  changes.  Build trees live under `CTS_BUILD_ROOT` (default
  `${XDG_CACHE_HOME:-$HOME/.cache}/g6lc-cts-build` — a per-user cache;
  the repo `.cache` is on DrvFs and is too slow for a full compile).

## Run

    G6LC_CTS=1 verif/tb/apu/bridge/run-guest.sh [--venus-only]

Attaches `ctsdata.img` as a fourth virtio-blk disk; `drive_guest.py`
mounts it by label after `vkcmp`, selects the Venus physical device
from `vulkaninfo --summary` (deviceName contains `Venus`,
`--deqp-vk-device-id` is 1-based), and runs the contract:

    deqp-vk --deqp-caselist-file=caselists/cts0-info-smoke.txt
            --deqp-log-images=disable --deqp-log-shader-sources=disable
            --deqp-vk-device-id=<N> --deqp-log-filename=…/TestResults.qpa
            --deqp-log-flush=disable --deqp-shadercache=disable
            --deqp-archive-dir=/mnt/ctsdata

Results (`/results/TestResults.qpa`, `vulkaninfo-summary.txt`,
`dmesg.txt`) are pulled host-side with `debugfs` after QEMU exits —
no root needed.  `G6LC_CTS_RUN cases=<n> rc=<rc>` marks completion;
a nonzero rc is reported as-is, never as PASS.
`G6LC_CTS_CASELIST`/`G6LC_CTS_TIMEOUT` (default 4 h) override.

## Ledger

    python3 corev_apu/apu/tools/cts_ledger.py parse \
      --groups .cache/cts/groups.json --qpa <TestResults.qpa> \
      --out .cache/cts/runs/<tag>/results.json --run-tag <tag> …
    python3 corev_apu/apu/tools/cts_ledger.py render \
      --groups .cache/cts/groups.json --results <results.json> \
      --out architecture/uncore/apu-cts-ledger.md
