# SPDX-License-Identifier: MIT
# S1 TRACE of keep-class h0 hang (tohost=0 @40000). Dumps start at
# after=38000 so maxn is the hang tail, not namelen prologue.
# CVA6_SOAK_POLL=64. loc on npc/commit is PC.
exit pin mepc=0x80012eb2 mcause=6 hart=0 tag=pin12eb2
log npc lo=0x80000000 hi=0x80020000 after=38000 max=48 tag=npc
log commit lo=0x80000000 hi=0x80020000 after=38000 max=48 gpr=sp,s2,s3,ra,a0 tag=hang
log commit lo=0x80012a60 hi=0x80012a72 after=10000 max=16 gpr=sp,s3,ra tag=ntr
log mem off=0x46ec8 after=38000 max=8 tag=alias
