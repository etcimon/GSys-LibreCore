# SPDX-License-Identifier: MIT
# ipi-lot: hart1 _start_warm to SP / _start_hang.
log commit lo=0x800002e8 hi=0x80000302 max=12 gpr=t0,t1,ra hart=1 tag=wait1
log commit lo=0x80000306 hi=0x80000390 max=40 gpr=sp,ra,s6,s7,s9,a4,a5 hart=1 tag=w1
log commit lo=0x80000306 hi=0x80000390 max=16 gpr=sp,s6,s7,s9 hart=0 tag=w0
log commit lo=0x800003c8 hi=0x800003d4 max=8 gpr=s6,s7,ra,sp hart=1 tag=hang1
log commit lo=0x80000366 hi=0x80000366 max=4 gpr=sp,tp hart=1 tag=sp1
log mem off=0x40438 max=6 tag=hcnt
log mem off=0x42870 max=6 tag=hidtab
