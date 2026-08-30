# SPDX-License-Identifier: MIT
# S4: v4 OpenSBI IAF mepc=0 after jal fdt_stringlist_contains
# (ra=0x80014182 in fdt_node_check_compatible). Namelen returned.
# Do not peel. Do not I4v. FtqDepth=0 live.
log npc lo=0x80014170 hi=0x80014196 max=32 gpr=sp,ra,a0,a1,a2,s0 tag=compat
log npc lo=0x80013f06 hi=0x80013f84 max=64 gpr=sp,ra,a0,a1,a2,a5,s1,s2,s4 tag=slc
log npc lo=0x800049d4 hi=0x80004a02 max=24 gpr=sp,ra,a0,a5 tag=strlen
log npc lo=0x80004ba8 hi=0x80004be2 max=16 gpr=sp,ra,a0,a1,a2 tag=memcmp
log npc lo=0x80004be4 hi=0x80004c18 max=16 gpr=sp,ra,a0,a1,a2 tag=memchr
log npc lo=0x0 hi=0x100 max=16 gpr=sp,ra,a0,a5,mepc,mcause tag=iaf0
log npc lo=0x800003c8 hi=0x800003d0 max=4 gpr=sp,ra,mepc,mcause tag=hang
log gpr gpr=ra max=32 after=12000 tag=raedge
exit pin mepc=0x0 mcause=1 hart=0 after=10000 tag=pin0
