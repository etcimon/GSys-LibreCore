# SPDX-License-Identifier: MIT
# S4 RAS16: fdt_get_name ld ra,72(sp) = FDT then ret IAF @0x8001e000.
# Last call from subnode_offset_namelen (prologue ra=0x80013408).
# Slot 0x80046e60+72 = 0x80046ea8. after= last invocation (~113k).
# Do not peel. Do not I4v. Do not I4m-on-B.
log npc lo=0x800132d6 hi=0x800132ea max=16 gpr=sp,ra,a0,a1,a2 tag=pro after=113000
log npc lo=0x80013302 hi=0x80013316 max=16 gpr=sp,ra,a0,s1,s3,s4 tag=chk after=113000
log npc lo=0x80013366 hi=0x8001338c max=24 gpr=sp,ra,a0,s1,s3 tag=epi after=113000
log npc lo=0x80013400 hi=0x8001340c max=8 gpr=sp,ra,a0,s1,s3 tag=subn after=113000
log npc lo=0x8001e000 hi=0x8001e010 max=4 gpr=sp,ra,a0 tag=fdtiaf
log mem off=0x46ea8 max=16 after=113000 tag=raslot
log hold lo=0x800132d6 hi=0x8001338c off=0x80046ea8 max=16 after=113000 tag=holdra
log gpr gpr=ra max=16 after=113400 tag=raedge
exit pin mepc=0x8001e000 mcause=1 hart=0 after=2000 tag=pinfdt
