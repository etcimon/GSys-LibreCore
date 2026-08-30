# SPDX-License-Identifier: MIT
# S1 TRACE: 2nd fdt_next_tag c.sdsp s3 @0x129d8 (t≈8245) vs ld s3,24(sp) @0x12a66.
# Adds SP so 32B check_node / 64B next_tag alias PAs can be computed:
#   1st sd ra,56(sp_nt1)  ==  2nd ld s3,24(sp_nt2)  iff  sp_nt2 == sp_nt1 + 32.
# log commit uses commit_ack bit0 — a hit at 129d8 is not by itself proof the
# store reached D$ (I4cf: B can commit_ack a cancelled stack sd).
exit pin mepc=0x80012eb2 mcause=6 hart=0 tag=pin12eb2
log commit lo=0x800129d8 hi=0x800129d8 max=16 gpr=sp,s2,s3,ra,a0,a2 tag=sdsp
log commit lo=0x80012a60 hi=0x80012a72 max=48 gpr=sp,s2,s3,ra,a0,a2 tag=ntr
log commit lo=0x800129d4 hi=0x80012a72 max=256 gpr=sp,s2,s3,ra,a0,a2 tag=nt
log commit lo=0x80012b0a hi=0x80012b3e max=48 gpr=sp,s2,s3,ra,a0,a2 tag=cn
log commit lo=0x80012e26 hi=0x80012eb8 max=64 gpr=sp,s2,s3,a0,a2,ra tag=bo
log commit lo=0x80012e30 hi=0x80012e40 max=32 gpr=sp,s2,s3,a0,a2,ra tag=mv
