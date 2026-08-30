# SPDX-License-Identifier: MIT
# S4: get_name ld ra from s3 slot because sp is 32B low.
# check_node_offset_ frame is 32B; addi sp,+32 is c.addi16sp @12ad8
# (same PC as pin leftover-RVI). Confirm skip vs commit.
# Do not peel. Do not I4v. Do not I4m-on-B.
log npc lo=0x80012aaa hi=0x80012adc max=32 gpr=sp,ra,a0,s0 tag=chk after=113400
log npc lo=0x800129fe hi=0x80012a14 max=16 gpr=sp,ra,a0 tag=ntepi after=113400
log npc lo=0x80013366 hi=0x8001338c max=16 gpr=sp,ra,a0,s1 tag=gnepi after=113400
log npc lo=0x800132d6 hi=0x800132ea max=8 gpr=sp,ra,a0 tag=gnpro after=113000
log npc lo=0x8001e000 hi=0x8001e010 max=4 gpr=sp,ra tag=fdtiaf
log mem off=0x46ec8 max=8 after=113000 tag=rasave
log mem off=0x46ea8 max=8 after=113000 tag=s3slot
exit pin mepc=0x8001e000 mcause=1 hart=0 after=2000 tag=pinfdt
