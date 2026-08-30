# SPDX-License-Identifier: MIT
# S4: mini_fdt_nt_stock on _v hangs at offset_ptr ld ra,8(sp)@0xe0.
# ra still nt_pad@148 (2nd jal taken). Distinguish first-visit HPD fill
# vs replay/cancel. Do not peel. Do not I4v. I13: B has no ld-ra keep.
log npc lo=0x800000c0 hi=0x800000e6 max=80 gpr=sp,ra,s0,a0,a1 tag=op
log npc lo=0x80000104 hi=0x80000152 max=32 gpr=sp,ra,a0,s1 tag=nt
log npc lo=0x800000e0 hi=0x800000e0 max=8 every=1024 gpr=sp,ra,a0 tag=stuck
