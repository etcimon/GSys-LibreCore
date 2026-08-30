# SPDX-License-Identifier: MIT
# S4: did leftover jal@12ac6 commit, and what did fetch present?
# fetch_snap via TH_PLUSARGS. Do not peel. Not I4m-on-B.
log commit lo=0x80012ac0 hi=0x80012ada max=24 after=113480 tag=cmtjal
log commit lo=0x80012974 hi=0x80012a14 max=24 after=113480 tag=cmtnt
log commit lo=0x80013300 hi=0x80013320 max=12 after=113480 tag=cmtgn
log npc lo=0x80012ac0 hi=0x80012ae0 max=20 gpr=ra,sp tag=win after=113480
exit pin mepc=0x8001e000 mcause=1 hart=0 after=2000 tag=pinfdt
