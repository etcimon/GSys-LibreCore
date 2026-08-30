# SPDX-License-Identifier: MIT
# Head load is c.ld a5,0(a3) @8d8c; 8d8e is beq empty. 8d9e is node-next.
# 120k headld-only already NULL-walks (no 8d8c). 100k+mem Heisenbug.
# 90k headld-only, no mem.
exit pin mepc=0x80012eb2 mcause=6 hart=0 tag=pin12eb2
log commit lo=0x80008d8c hi=0x80008d8c after=90000 max=8 gpr=a0,a3,a5,ra tag=headld
log commit lo=0x80008d9e hi=0x80008d9e after=90000 max=8 gpr=a3,a5,ra tag=nxld
