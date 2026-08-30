# SPDX-License-Identifier: MIT
# S4: next_tag sp +16 vs -64. 12970 is offset_ptr addi+16/ret.
# same_win(12970,12974)? Do not peel. Not I4v. Not log mem.
log npc lo=0x80012970 hi=0x80012973 max=8 gpr=ra,sp tag=plus16 after=124880
log npc lo=0x80012974 hi=0x8001298c max=16 gpr=ra,sp,s0,a2,s3 tag=ntpro after=124880
log npc lo=0x80012ab0 hi=0x80012ac8 max=12 gpr=ra,sp,s0,a2 tag=chk after=124880
log commit lo=0x80012970 hi=0x80012986 max=16 after=124880 tag=cmtpro
log commit lo=0x80012ab0 hi=0x80012ac8 max=12 after=124880 tag=cmtchk
log npc lo=0x80012ac6 hi=0x80012ada max=8 gpr=ra,sp tag=jalnt after=124880
exit pin mepc=0x8001e000 mcause=1 hart=0 after=2000 tag=pinfdt
