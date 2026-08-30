# SPDX-License-Identifier: MIT
# S4: next_tag fail epi @129fe then IAF. ld ra@12a02? jal@12ac6?
# sw -11,0(s3) @129ca. Do not peel. Not I4v.
log npc lo=0x800129c0 hi=0x80012a14 max=24 gpr=ra,sp,a0,a2,a4,a5,s2,s3 tag=fail after=124900
log npc lo=0x80012ac6 hi=0x80012ada max=12 gpr=ra,sp tag=jalnt after=124900
log commit lo=0x80012ac0 hi=0x80012ada max=16 after=124900 tag=cmtjal
log commit lo=0x800129c0 hi=0x80012a14 max=16 after=124900 tag=cmtfail
exit pin mepc=0x8001e000 mcause=1 hart=0 after=2000 tag=pinfdt
