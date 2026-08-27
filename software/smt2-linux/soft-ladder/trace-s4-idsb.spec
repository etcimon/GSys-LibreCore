# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# S4 leftover-complete vs 12960: npc order of trapping visit. Do not log mem.
log npc lo=0x80012950 hi=0x80012970 max=80 after=103000 gpr=ra,sp tag=nptail
log commit lo=0x80012950 hi=0x80012970 max=40 after=103600 gpr=ra,sp,a0 tag=cmttail
log commit lo=0x8001297c hi=0x80012980 max=8 after=103500 gpr=ra,sp,s3 tag=cmtra
log commit lo=0x80012a00 hi=0x80012a12 max=16 after=103600 gpr=ra,sp,s3 tag=cmtepi
exit pin mepc=0x0 mcause=1 hart=0 after=8000 tag=pin0
