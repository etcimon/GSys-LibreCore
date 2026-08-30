# SPDX-License-Identifier: MIT
# S4: dump commit PCs around 12ad8. If extract works, +64@12a10 should
# appear; +32@12ad8 yes/no. Do not peel. Not I4m-on-B.
log commit lo=0x0 hi=0xffffffffffffffff max=80 after=113640 tag=cmtall
log npc lo=0x80012ad0 hi=0x80012ae0 max=8 gpr=sp tag=epi after=113640
log npc lo=0x8001e000 hi=0x8001e010 max=4 gpr=sp,ra tag=fdtiaf
exit pin mepc=0x8001e000 mcause=1 hart=0 after=2000 tag=pinfdt
