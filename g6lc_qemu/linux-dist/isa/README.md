# ISA fragment — LibreCore `g6lc64_smt2`

Copied from the RTL/DTS contract, not from QEMU or a distro defconfig.

| Artifact | Use |
|---|---|
| `g6lc64_smt2-march.txt` | userspace/toolchain `-march` (gcc 13: no `zacas`) |
| `kernel-6.6.config` | Linux 6.6 `CONFIG_RISCV_ISA_*` overlay |
| `dts-isa.txt` | `riscv,isa` / `riscv,isa-extensions` from `ariane-smt2.dts` |

When the active target is not smt2, regenerate these from that target's
config package + DTS before building a distro. Do not hand-edit tokens
to “match QEMU”.
