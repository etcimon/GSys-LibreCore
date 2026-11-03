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
`G6LC_ONLY=cts` skips the vk* leaves and runs only deqp-vk.

Incremental must-pass lists, each a true subset of the pin (regenerate
with `cts_ledger.py select`, then `debugfs -w write` into `ctsdata.img`
because the guest reads the list from that image):

- `caselists/cts-a-compute-basic.txt` — the full
  `dEQP-VK.compute.pipeline.basic.*` group (80). Next group run after
  `MaxWaves=16`.
- `caselists/cts-a-image-objects.txt` — the 20 image 1D/3D object and
  view cases that were open defects (20). Next group after the image
  object contract.

CTS runs verilate the bridge on the remote testharness with the
optimized Verilator (`verilator-v5.008-g6lc` on `ovh_calltorch`). The
Ubuntu image and `ctsdata.img` are rsynced into
`/opt/testharness/cache` and reused. Do not verilate the bridge locally
for these runs.

```
G6LC_CTS=1 G6LC_ONLY=cts G6LC_SKIP_APT=1 G6LC_VN_DEBUG=no_abort \
  G6LC_CTS_CASELIST=caselists/cts-a-compute-basic.txt \
  verif/tb/apu/bridge/run-guest-remote.sh --detach
```

`apu-leaf-collect <tag>` pulls the verdict and every `*.qpa`. The tag
is the first line the launcher prints. Run the proxy from WSL (or any
host with `rsync`); native Windows Python has no `rsync`, so collection
fails there.

Ongoing leaves:

    testharness_proxy.py apu-leaf-progress <tag>...   # live counts (progress only)
    guest/cts/collect-leaves.sh <tag>...              # collect + ledger as each ends

`collect-leaves.sh` re-runs `cts_ledger.py harvest` and `render` after
every collection. `harvest` rebuilds one results JSON per retained run
(`remote-runs/apu-leaf-*`, `.cache/apu-guest/out-*`). It skips
diagnostic runs (image or shader logging) and records a case cut by the
driver's CTS budget as Timeout, not Crash.

### Concurrent shards

`G6LC_CTS_SHARDS=N` runs one caselist as N concurrent guest+bridge pairs.
Shard `i` runs caselist lines `i, i+N, …` (`G6LC_CTS_SHARD=i,N`). The
slice is written into the shard's private image as
`caselists/g6lc-shard.txt`. `--deqp-fraction` is not used for shards:
deqp splits by hierarchy node, so a 21-case list from one group put all
21 cases in fraction 0. `G6LC_CTS_FRACTION` still passes that flag
through for full `vk-default` runs. Each shard boots the root image
`snapshot=on` and writes a private copy of `ctsdata.img`
(`G6LC_INSTANCE_DIR`), so shards share no writable disk, socket or log.
N is also clamped to the number of cases.
The bridge binary is built once and shared. N is clamped to
`(nproc - busy - 1) * 2 / 3`, where `busy` comes from a 2 s `/proc/stat`
sample. While deqp runs, a shard is one saturated bridge thread and its
QEMU sits near 5 %. QEMU uses about 2 cores only while booting, so
shard starts are staggered by `G6LC_CTS_SHARD_STAGGER` (20 s). Set
`G6LC_CTS_SHARDS_FORCE=1` to skip the clamp (local runs only; the leaf
allowlist does not forward it).

Every CTS run, sharded or not, writes its results into a private copy
of `ctsdata.img`. The copy is deleted after the results are dumped. The
remote image path is keyed by the local file name. To add caselists
while a leaf is live, copy the image under a new name (for example
`ctsdata-b2.img`), `debugfs -w write` the lists into it, and point
`G6LC_CTSDATA` at it. A push of `ctsdata.img` would replace the file a
running leaf still reads.
Results land in `output/guest/shard-<i>/cts-TestResults.qpa`. Pass all of
them to `cts_ledger.py parse` (`--qpa` repeats). The top-level
`drive-venus.log` prints one line per shard and ends in `GUEST-PASS`
only if every shard passed.

Shard only lists where RTL time dominates. A leaf has about 90 s of
fixed cost (venus bridge build, 28 s guest boot, teardown). SSBO and
binding lists finish in about 100 s total, so sharding them gains
little. UBO matrix lists take 1.4–4 h, and those are the lists to
shard. Venus-only guest leaves no longer build the unused venusoff
bridge (`APU_BRIDGE_VENUS_ONLY`).

Sharding changes which cases share one deqp-vk process and one device
session. A device that leaks state between cases can therefore score
differently sharded than serial. This happened on 2026-11-02, locally,
with the Oct-29 bridge binary on `cts1-ssbo-std430-basic` (21 cases):
- Serial, in one process: 18 Pass, 3 Fail (`highp_mat3`, `highp_mat2x3`,
  `highp_mat4x3`).
- Two shards: 21/21 Pass.

The same list was 21/21 serial with newer RTL on
`apu-leaf-20261031T163945-b771df9f11af`. The same class of problem as the
`cts_b2b_opt_1` pair contamination in the plan. A sharded pass is
throughput evidence. A group is closed only when one serial-order run of
the full list also passes. Treat a serial/shard disagreement as a device
ordering defect, not as noise.

## Ledger

    python3 corev_apu/apu/tools/cts_ledger.py parse \
      --groups .cache/cts/groups.json --qpa <TestResults.qpa> \
      --out .cache/cts/runs/<tag>/results.json --run-tag <tag> …
    python3 corev_apu/apu/tools/cts_ledger.py render \
      --groups .cache/cts/groups.json --results <results.json> \
      --out architecture/uncore/apu-cts-ledger.md
