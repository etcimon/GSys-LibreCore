# SPDX-License-Identifier: MIT
# S4: next_tag ret should land at 12aca (c.li after jal@12ac6).
# chksp TRACE jumped 12a10 -> 12ad0 with no 12aca. leftover/align?
# Do not peel. Do not I4v. Do not I4m-on-B.
log npc lo=0x80012a10 hi=0x80012a14 max=8 gpr=sp,ra,a0,a5 tag=ntret after=113600
log npc lo=0x80012ac0 hi=0x80012acf max=16 gpr=sp,ra,a0,a5,s0 tag=line0 after=113600
log npc lo=0x80012aca hi=0x80012acf max=8 gpr=sp,ra,a0,a5 tag=aca after=113600
log npc lo=0x80012ad0 hi=0x80012adf max=12 gpr=sp,ra,a0,a5,s0 tag=epi after=113600
log commit lo=0x80012aca hi=0x80012adc max=16 after=113600 tag=cmt
log npc lo=0x8001e000 hi=0x8001e010 max=4 gpr=sp,ra tag=fdtiaf
exit pin mepc=0x8001e000 mcause=1 hart=0 after=2000 tag=pinfdt
