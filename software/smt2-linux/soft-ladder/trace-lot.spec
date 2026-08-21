# SPDX-License-Identifier: MIT
# G1fn: 7bc commit vs leftover jal@766. gpr last.
log npc lo=0x800007a2 hi=0x800007c0 max=24 tag=lot7b
log npc lo=0x800007bc hi=0x800007be max=8 tag=npc7bc
log commit lo=0x800007ac hi=0x800007ac max=8 tag=csrrcmt
log commit lo=0x800007b8 hi=0x800007be max=12 tag=lotcmt
log commit lo=0x800007bc hi=0x800007bc max=8 tag=bnezcmt
log commit lo=0x800007c0 hi=0x800007c8 max=8 tag=pkt7c0
log commit lo=0x80000766 hi=0x8000076a max=8 tag=j766cmt
log npc lo=0x80000766 hi=0x8000076a max=8 tag=hangj
log npc lo=0x800071e4 hi=0x800071f0 max=8 tag=coldfn
log npc lo=0x800038e0 hi=0x80003910 max=8 tag=scratch
log npc lo=0x8000ef4c hi=0x8000ef54 max=8 tag=harthang
log gpr lo=0x800007a8 hi=0x800007c0 max=16 tag=lotgpr gpr=a0,a1,a5,s1,ra
