# ubuntu — custom-fitted RISC-V Ubuntu (alongside OpenWrt)

This slot is **first-party MIT scaffold**. Ubuntu source is not vendored here
yet: Canonical trees are large and a different build (livecd-rootfs /
ubuntu-image / ports.ubuntu.com), not a single `src-git` feed.

It exists so a fitted Ubuntu image can sit next to OpenWrt under
`g6lc_qemu/linux-dist/` and share the same RTL ISA fragment.

## Shared with OpenWrt

| File | Role |
|---|---|
| [`../isa/kernel-6.6.config`](../isa/kernel-6.6.config) | `CONFIG_RISCV_ISA_*` from `g6lc64_smt2` |
| [`../isa/g6lc64_smt2-march.txt`](../isa/g6lc64_smt2-march.txt) | userspace `-march` |
| [`../isa/dts-isa.txt`](../isa/dts-isa.txt) | DTS ISA tokens |

Do not fork a second ISA story. If smt2 grows RVV or H, update `isa/` once.

## Intended later submodules (not added yet)

When a Canonical tree is forked to `github.com/etcimon`, add it **here** as a
sibling submodule (`ubuntu-` prefix, same idea as `openwrt-*`):

| Path (planned) | Upstream | Purpose |
|---|---|---|
| `ubuntu-livecd-rootfs/` | `canonical/livecd-rootfs` | rootfs / seed |
| `ubuntu-image/` | `canonical/ubuntu-image` | image assembly |

Compile will follow the OpenWrt pattern: official Canonical pin + patches
under `g6lc_qemu/ubuntu/patches/` (not created until that builder exists).
The etcimon fork is for extracting diffs only.

Until then, `pins.toml` records the Ubuntu series and RISC-V port URL only.

## Fitting notes

- Series: Ubuntu 24.04 LTS (`noble`) RISC-V.
- Kernel: same 6.6 ISA overlay; EFI stub; virtio; `maxcpus=2`.
- Do not enable RVV or hypervisor (`h`) on smt2.
- Keep this tree a **separate work** from LibreCore RTL (`E-GPLLINK` analogue:
  Ubuntu is Canonical terms; do not copy it into `crates/**`).
