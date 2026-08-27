# SPDX-License-Identifier: MIT
# S4: ra at next_tag sd ra,56(sp)@1297e. Should be 12aca (check_node
# jal return). If 13312, jal link missed and ret skips +32 epi.
# Do not peel. Not I4m-on-B.
log npc lo=0x80012974 hi=0x80012982 max=16 gpr=ra,sp,a0 tag=ntpro after=113400
log npc lo=0x80012ac6 hi=0x80012ad0 max=8 gpr=ra,sp tag=jalnt after=113400
log npc lo=0x80012a00 hi=0x80012a14 max=12 gpr=ra,sp tag=ntepi after=113600
log npc lo=0x8001330e hi=0x80013318 max=8 gpr=ra,sp tag=gnjal after=113400
log npc lo=0x8001e000 hi=0x8001e010 max=4 gpr=ra,sp tag=fdtiaf
exit pin mepc=0x8001e000 mcause=1 hart=0 after=2000 tag=pinfdt
