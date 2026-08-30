# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# S4: 2M hang still npc=12918 ra=129fc a0=0x82200000 plat_hc=4
# coldboot_done=1. Is name-skip still advancing? Do not log mem.
log commit lo=0x800129f6 hi=0x800129fd max=16 after=1900000 gpr=ra,sp,a0,s1,s4 tag=nloop
log commit lo=0x80012888 hi=0x8001288c max=8 after=1900000 gpr=ra,a0,a1 tag=opent
exit pin mepc=0x80012c56 mcause=1 hart=0 after=163000 tag=pin12c56
