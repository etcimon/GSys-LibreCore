# SPDX-License-Identifier: MIT
# Optional localization spec for g6lc_tb.cpp (CVA6_TRACE_FILE=this).
# Off unless CVA6_TRACE=1 or this file is exported. Does not change
# default soak-exit (cookie / pin / WFI) unless you add more `exit` lines.
#
# Grammar (one rule per line, or `;` in CVA6_TRACE_SPEC):
#   exit cookie [off=0x1000] [val=0x51b1babe] [tag=cookie]
#   exit pin mepc=0x800129f8 mcause=4 [hart=0] [tag=pin]
#   exit wfi [after=200000] [hits=8] [tag=wfi]
#   exit npc lo=0x800006c2 hi=0x800006c2 [after=0] [tag=fail_phase]
#   log npc lo=0x800002b8 hi=0x800002c2 [max=32] [gpr=ra,t2] [tag=p6jal]
#   log commit lo=0x80000490 hi=0x8000055c [max=64] [gpr=ra,s0,a0] [tag=offset_ptr]
#   log mem off=0x1000 [max=8] [tag=cookie]
#   log gpr lo=0x800002be hi=0x800002c2 gpr=ra,t2 [max=16] [tag=p6rf]
#   log gpr gpr=ra,t2 [max=40] [tag=gchg]   # no lo/hi: RF write edge
#
# Do not `exit` on 51b1c001 — cave lui before addi.

# Mini P6 jal window (straddle 0x2b8 / jal 0x2be). Enable with CVA6_TRACE=1.
log npc lo=0x800002b8 hi=0x800002c2 max=24 gpr=ra,t2,a0 tag=p6jal
log commit lo=0x80000490 hi=0x8000055c max=32 gpr=ra,s0,a0,t2 tag=offset_ptr
