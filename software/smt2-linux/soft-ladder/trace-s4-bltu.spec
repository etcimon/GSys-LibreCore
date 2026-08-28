# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# S4: 8M illegal mepc=12958 mcause=2 (bltu@12956 8B leftover hi).
# leftover_pending / kill vs leftover_drop. Do not log mem.
log commit lo=0x8001294e hi=0x80012972 max=24 after=2400000 gpr=ra,a0,a2,a4 tag=opbl
log npc lo=0x80012950 hi=0x80012970 max=24 after=2400000 gpr=ra,a0 tag=npcbl
exit pin mepc=0x80012958 mcause=2 hart=0 after=2000000 tag=pin12958
