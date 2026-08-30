# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# S4: 180k hang npc=12918 (slliw off_dt_struct) ra=129fc (name-loop
# jal@129f8). Walk vs stuck. Do not log mem.
log commit lo=0x80012888 hi=0x80012890 max=20 after=160000 gpr=ra,sp,a0,a1 tag=opent
log commit lo=0x80012904 hi=0x80012928 max=24 after=160000 gpr=ra,sp,a0,a3,a4,a5 tag=op18
log commit lo=0x8001295a hi=0x80012972 max=16 after=160000 gpr=ra,sp,a0 tag=opepi
log commit lo=0x800129f0 hi=0x80012a00 max=16 after=160000 gpr=ra,sp,a0,s1 tag=nloop
log npc lo=0x80012910 hi=0x80012924 max=24 after=170000 gpr=ra,a0,a3,a4,a5 tag=npc18
exit npc lo=0x80012918 hi=0x8001291c after=175000 tag=stuck18
