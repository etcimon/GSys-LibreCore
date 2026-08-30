# SPDX-License-Identifier: MIT
# S4: IAF mepc=0xfffffff58001e000 (FDT + high 0xfffffff5). Pin matches
# low 32 of 0x8001e000. Who jumped? Do not peel. Not I4v.
log npc lo=0x800072e0 hi=0x800072f0 max=8 gpr=ra,sp,a0,a5 tag=jalr1 after=118000
log npc lo=0x80007320 hi=0x80007340 max=8 gpr=ra,sp,a0,a5 tag=jalr2 after=118000
log npc lo=0x80007264 hi=0x80007550 max=24 gpr=ra,sp,a0,a5,s3 tag=fwplat after=118000
log npc lo=0x80013370 hi=0x80013390 max=12 gpr=ra,sp,a0,a4 tag=gnepi after=118000
log npc lo=0x80012ada hi=0x80012adc max=8 gpr=ra,sp tag=chkret after=118000
log npc lo=0x8001e000 hi=0x8001e020 max=8 gpr=ra,sp,a0,a4,a5,t0 tag=fdtiaf
log commit lo=0x80000000 hi=0x80200000 max=32 after=124800 tag=cmtend
exit pin mepc=0x8001e000 mcause=1 hart=0 after=2000 tag=pinfdt
