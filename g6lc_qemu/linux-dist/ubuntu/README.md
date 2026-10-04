# Ubuntu — kernel references and separate runtime lanes

This directory remains a first-party MIT scaffold, not an Ubuntu distribution
checkout. The nested kernel submodules are untouched upstream works under their
own licenses; they are reference inputs, not linked into the generator or RTL.

## Pinned source references

| Local path | Official source series/tag | Commit |
|---|---|---|
| `kernel/` | Resolute, `Ubuntu-7.0.0-27.27` | `01543ba213ac86680193399096806a6e265e1cdf` |
| `kernel-noble/` | Noble, `Ubuntu-6.8.0-90.91` | `28e5daf6ca5bdc7104d1d5877c7113e578c94e9e` |

Both are explicitly initialized locally, detached, shallow and sparse. The host
repository's `.gitmodules` sets `update = none` and `shallow = true`; ordinary
submodule update skips them. Pins also live in [`pins.toml`](pins.toml). The tags
identify source, not the kernel installed in a qualified Ubuntu image.

Review `drivers/gpu/drm/virtio/`, `drivers/virtio/`, `include/uapi/drm/` and selected
`include/uapi/linux/virtio_*.h`. The sources expose feature negotiation, capsets,
context initialization, blob creation/mapping and shared-memory discovery. They
do not establish the Mesa package version, enabled distro kernel configuration,
ICD selection or graphics-device correctness.

The separate `specs/UnrealEngine` reference in the host repository is UE 5.8.3 at
`396c9f059903aed5fec78ecd3d437a40c6415368`. It is also lazy, locally initialized
and sparse. Its Epic terms remain intact; it is not a QEMU build dependency.
No Epic Setup script, kernel build/install or Ubuntu image download was run.

## Stock Ubuntu acceptance lane

Test official Ubuntu **26.04.1 first**, then **24.04 separately**, on x86-64 first.
RISC-V is a later CPU/platform track. Only official distribution packages and
updates qualify. Record each image, installed kernel/configuration, Mesa,
libdrm, Vulkan loader/ICD and window-system package manifest independently.
A source tag or a package listing is not an installed-runtime manifest.

No custom kernel, PPA/DKMS driver, ICD, preload shim, graphics-library override,
privileged bridge daemon or APU-specific service/compiler firmware may be
required by the final graphics runtime. Ordinary distro diagnostics may be
installed for testing; an installation-free claim additionally requires the
chosen clean image to contain the necessary stock drivers.

The first modern application target is an unmodified packaged UE 5.8.3 desktop
Vulkan SM5 raster project with profile checks enabled. SM6/ray tracing and CS2
are separate later gates. Native RISC-V Unreal is not implied by Ubuntu or GPU
support. Current device limitations and the incomplete requirement matrix are
in the host's `architecture/uncore/apu-graphics.md`; no runtime is qualified yet.

## Historical custom-image development lane

The original Noble/RISC-V 6.6 ISA-overlay recipe remains a development scaffold,
not vanilla Ubuntu acceptance. Its `[ubuntu]` pins are retained for that purpose.

| File | Development role |
|---|---|
| [`../isa/kernel-6.6.config`](../isa/kernel-6.6.config) | `CONFIG_RISCV_ISA_*` from `g6lc64_smt2` |
| [`../isa/g6lc64_smt2-march.txt`](../isa/g6lc64_smt2-march.txt) | userspace `-march` |
| [`../isa/dts-isa.txt`](../isa/dts-isa.txt) | DTS ISA tokens |

Keep that lane's ISA description shared with OpenWrt; do not enable RVV or H
for an smt2 configuration that does not implement them. The old EFI/virtio,
`maxcpus=2`, livecd-rootfs/ubuntu-image and downstream-patch ideas are not
implemented here and are not the recipe for final stock-runtime qualification.
Do not copy kernel sources into `crates/**` or LibreCore flists.

## Sparse checkout on Windows

Linux trees contain reserved Windows names and case-colliding netfilter headers.
Use WSL Git and narrow **non-cone** patterns before materializing a future kernel
reference on a case-insensitive filesystem. Do not select all of
`include/uapi/linux/`, disable Git path protections or force-reset user changes.
The repaired local checkouts are clean and use these patterns:

```text
/*
!/*/
/drivers/gpu/drm/virtio/
/drivers/virtio/
/include/uapi/drm/
/include/uapi/linux/virtio_gpu.h
/include/uapi/linux/virtio_ids.h
/include/uapi/linux/virtio_config.h
/include/uapi/linux/virtio_pci.h
/include/uapi/linux/virtio_mmio.h
```

Launchpad ignored blob filtering during this download; shallow history and
sparse working-tree selection still apply. Upstream objects were not modified.
