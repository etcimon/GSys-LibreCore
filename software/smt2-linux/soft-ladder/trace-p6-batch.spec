# SPDX-License-Identifier: MIT
# Batch localization for mini P6 0x65. Wide P6 window survives G1ad realign.
# gpr (no lo/hi) = RF write edge. Do not exit on 51b1c001.
log gpr gpr=ra,t2 tag=gchg max=40
log gpr gpr=t3,t1 tag=t3chg max=32
log npc lo=0x800002b0 hi=0x800002e0 max=24 gpr=ra,t2,a0 tag=p6fetch
log commit lo=0x800002b0 hi=0x800002e0 max=16 gpr=ra,t2,a0 tag=p6wb
log npc lo=0x80000490 hi=0x800004f0 max=80 gpr=ra,t2,a0,s11,sp,t1,t3 tag=op_entry
log commit lo=0x80000490 hi=0x800004f0 max=48 gpr=ra,t2,a0,sp,t1,t3 tag=op_cmt
log npc lo=0x80000532 hi=0x80000588 max=24 gpr=ra,t2,sp,t1,t3 tag=op_epil
log npc lo=0x800006c2 hi=0x800006e0 max=8 gpr=ra,s11,t3 tag=fail
# P8 check_node nest (0x18). After G1ct P6 0x69 closed.
log gpr gpr=s1,s2,s4,s5,a0 tag=p8chg max=40
log npc lo=0x800003e8 hi=0x80000420 max=48 gpr=s1,s2,s4,s5,a0,s11,ra tag=p8
log commit lo=0x800003e8 hi=0x80000420 max=24 gpr=s1,s2,s4,s5,a0 tag=p8cmt
log npc lo=0x80000690 hi=0x800006d0 max=32 gpr=s1,s2,s4,s5,a0,ra,sp tag=cn
log npc lo=0x8000058c hi=0x80000620 max=48 gpr=s4,s5,a0,ra,sp tag=ntag
