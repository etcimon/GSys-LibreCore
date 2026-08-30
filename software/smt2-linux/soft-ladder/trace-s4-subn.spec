# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# S4: ra flips 17ff2@13008 t=163039 -> 0x480012c56@13010 t=163053.
# Wide commit to catch the x1 writer. Do not log mem.
log commit lo=0x80000000 hi=0x80022000 max=48 after=163030 gpr=ra,sp tag=cmtall
log npc lo=0x80013000 hi=0x80013020 max=16 after=163030 gpr=ra,sp tag=subn
exit pin mepc=0x80012c56 mcause=1 hart=0 after=163000 tag=pin12c56
