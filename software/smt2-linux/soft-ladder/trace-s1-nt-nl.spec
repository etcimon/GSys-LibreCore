# SPDX-License-Identifier: MIT
# S1 TRACE of mini_fdt_nt_osbi: 2nd next_tag c.sdsp s3 @0x129d8 vs
# ld s3,24(sp) @0x12a66. Warmup pushes the window past t=10000 so
# log mem can dump the alias PA (peel TRACE could not: t=8245).
# DRAM off is PA-0x80000000. loc on a mem line is the 8B LE value.
# CVA6_SOAK_POLL=64 (set by trace_mini_nt_nl.py) for denser dumps.
exit pin mepc=0x80012eb2 mcause=6 hart=0 tag=pin12eb2
log commit lo=0x800129d8 hi=0x800129d8 max=16 gpr=sp,s2,s3,ra,a0,a2 tag=sdsp
log commit lo=0x80012a60 hi=0x80012a72 max=48 gpr=sp,s2,s3,ra,a0,a2 tag=ntr
log commit lo=0x800129d4 hi=0x80012a72 max=256 gpr=sp,s2,s3,ra,a0,a2 tag=nt
log commit lo=0x80012b0a hi=0x80012b3e max=32 gpr=sp,s2,s3,ra,a0,a2 tag=cn
log commit lo=0x80012e26 hi=0x80012eb8 max=48 gpr=sp,s2,s3,a0,a2,ra tag=bo
log commit lo=0x80012eb2 hi=0x80012eb2 max=8 gpr=sp,s2,s3,a0,a2 tag=sw
# Mini fail3/fail13/fail_exit/trap (tohost=12 is write 25 = other trap).
log commit lo=0x80000116 hi=0x8000014e max=16 gpr=sp,s2,s3,ra,a0,a2 tag=fail
# WT D$ word-write grant around alias ACK (after warmup t>10000).
log wrack after=10000 max=64 tag=wrack
# Mini 2nd next_tag SP=0x80046eb0 (1st SP=0x80046e90, Δ=+32).
# Alias PA = 1st sd ra,56(sp) = 2nd ld s3,24(sp) = 0x80046ec8.
log mem off=0x46ec8 max=32 tag=alias
log mem off=0x46ed0 max=16 tag=s2slot
log mem off=0x46f2c max=8 tag=lenp
# g1ao_hold at 2nd ld s3 execute (off=alias PA). Dumps v/hit/data plus
# load_paddr when the load's PA matches, and every ntr commit.
log hold lo=0x80012a60 hi=0x80012a72 off=0x80046ec8 max=96 tag=hold
