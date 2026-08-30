# SPDX-License-Identifier: MIT
# S4: 12ad8 fetched, c.addi16sp +32 not retired. Watch sp around epi.
# 46e20 = next_tag sp; +32=46e40; +64=46e60. Do not peel. Not I4m-on-B.
log gpr gpr=sp max=48 after=113640 tag=spedge
log npc lo=0x80012ad0 hi=0x80012ae0 max=16 gpr=sp,ra,s0,a0 tag=epi after=113640
log npc lo=0x80012a10 hi=0x80012a14 max=8 gpr=sp,ra tag=ntret after=113640
log npc lo=0x80013366 hi=0x8001338c max=12 gpr=sp,ra tag=gnepi after=113640
log npc lo=0x8001e000 hi=0x8001e010 max=4 gpr=sp,ra tag=fdtiaf
exit pin mepc=0x8001e000 mcause=1 hart=0 after=2000 tag=pinfdt
