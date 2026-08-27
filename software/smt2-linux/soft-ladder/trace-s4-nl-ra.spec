# SPDX-License-Identifier: MIT
# S4: fdt_offset_ptr ld ra,8(sp)@1295a / ret@12968 after next_tag jal@129f8.
# Jump table jr a5@129e8 already reached BEGIN_NODE name scan. Do not peel.
log npc lo=0x80012888 hi=0x80012972 max=64 gpr=sp,ra,s0,a0,a1 tag=op
log npc lo=0x800129ea hi=0x80012a12 max=16 gpr=sp,ra,s0,a0,s1,s4 tag=nt
log gpr gpr=ra max=24 after=13000 tag=raedge
log mem off=0x46e50 max=8 tag=opra
log mem off=0x46e10 max=8 tag=stk
exit pin mepc=0x80046f2c mcause=1 hart=0 tag=pin46f2c
