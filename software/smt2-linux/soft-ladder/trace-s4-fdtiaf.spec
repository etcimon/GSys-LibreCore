# SPDX-License-Identifier: MIT
# S4 RAS16: fetch-0 IAF gone. New pin IAF mepc=0x8001e000 (FDT)
# ra=0x8001e000 => c.jr ra into FDT (not c.jalr a5, that would link .text).
# fw_platform_init jalr a5 @72e8 / @732c. Do not peel. Do not I4v.
log npc lo=0x80007264 hi=0x80007550 max=48 gpr=sp,ra,a0,a5,s3,s4 tag=fwplat
log npc lo=0x800072e0 hi=0x800072f0 max=8 gpr=sp,ra,a0,a5,s3 tag=jalr1
log npc lo=0x80007320 hi=0x80007330 max=8 gpr=sp,ra,a0,a5 tag=jalr2
log npc lo=0x800177da hi=0x80017820 max=16 gpr=sp,ra,a0,a1,a2 tag=match
log npc lo=0x8001e000 hi=0x8001e020 max=8 gpr=sp,ra,a0,a5 tag=fdtiaf
log npc lo=0x800003c8 hi=0x800003d0 max=4 gpr=sp,ra,mepc,mcause tag=hang
log gpr gpr=ra max=48 after=110000 tag=raedge
exit pin mepc=0x8001e000 mcause=1 hart=0 after=4000 tag=pinfdt
