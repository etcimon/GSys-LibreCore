# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# S4: WFI sbi_hart_hang@eef4 (ra=6310 jal@630c in sbi_trap_error).
# Do not log mem.
log commit lo=0x80005d6e hi=0x80005d90 max=16 after=2000000 gpr=ra,a0,a1,a2,a4,a5,s1,s2 tag=traph
log npc lo=0x80000500 hi=0x800005b8 max=8 after=2450000 gpr=ra,a0 tag=mtvec
log commit lo=0x8000053c hi=0x80000540 max=4 after=2456000 gpr=t0,ra,a0 tag=tcsr
log commit lo=0x80000586 hi=0x80000590 max=8 after=2456000 gpr=t0,ra tag=tcause
exit npc lo=0x80000500 hi=0x80000500 after=2450000 tag=pinmtvec
log commit lo=0x80005e10 hi=0x80005e20 max=8 after=2000000 gpr=ra,a0,a5 tag=illh
log commit lo=0x80005f00 hi=0x80005f28 max=8 after=2000000 gpr=ra,a0,a5,s1,s2 tag=trerr
log commit lo=0x8000630c hi=0x80006316 max=4 after=2000000 gpr=ra,a0,s1 tag=hangjal
log npc lo=0x8000eeec hi=0x8000eefc max=8 after=2000000 gpr=ra,a0 tag=hangwfi
log commit lo=0x80012880 hi=0x80012970 max=24 after=2456000 gpr=ra,a0,a2,a4 tag=optrap
log commit lo=0x8000fe0c hi=0x8000fe40 max=8 after=2456000 gpr=ra,a0,a1 tag=illfn
exit npc lo=0x80005d6e hi=0x80005d6e after=2400000 tag=pintrap
exit npc lo=0x8000eef4 hi=0x8000eef4 after=2500000 tag=pineef4
