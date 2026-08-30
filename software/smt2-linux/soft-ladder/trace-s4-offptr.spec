# SPDX-License-Identifier: MIT
# S4: did offset_ptr run before beqz@12994? Do not log mem.
log commit lo=0x80012888 hi=0x80012973 max=24 after=124880 tag=cmtop
log commit lo=0x80012990 hi=0x80012991 max=8 after=124880 tag=cmtjal
log commit lo=0x80012994 hi=0x80012995 max=8 after=124880 tag=cmtbz
log npc lo=0x80012888 hi=0x80012890 max=8 gpr=ra,a0,sp tag=opnpc after=124880
exit pin mepc=0x8001e000 mcause=1 hart=0 after=2000 tag=pinfdt
