# SPDX-License-Identifier: MIT
# Combined FDT walk (peel_both): namelen -> check_node jal next_tag (ra=0x12b2a)
# -> by_offset sw a0,0(s2) @0x12eb2.
# Round 2: previous gchg max=48 exhausted at boot; nt max=80 ate the first
# next_tag; commit missed mv s2,a2 @0x12e34 (PEEL cave @0x2cc0 / possible
# port-1). Window gpr on npc (not global RF-edge) + cave + tight mv.
exit pin mepc=0x80012eb2 mcause=6 hart=0 tag=pin12eb2
log commit lo=0x800129d4 hi=0x80012a72 max=256 gpr=s2,s3,ra,a0,a2 tag=nt
log commit lo=0x80012b0a hi=0x80012b3e max=48 gpr=s2,s3,ra,a0,a2 tag=cn
log commit lo=0x8001305e hi=0x80013090 max=40 gpr=s2,s3,ra,a0,a2,s1 tag=nl
log commit lo=0x800130a8 hi=0x800130b6 max=16 gpr=s2,s3,a0,a1,a2,ra tag=n2bo
log commit lo=0x80012b40 hi=0x80012b80 max=32 gpr=s2,s3,a0,a2,ra tag=cp
log commit lo=0x80012e26 hi=0x80012eb8 max=64 gpr=s2,s3,a0,a2,ra tag=bo
log commit lo=0x80012e30 hi=0x80012e40 max=32 gpr=s2,s3,a0,a2,ra tag=mv
log commit lo=0x80002cc0 hi=0x80002d00 max=48 gpr=s2,s3,ra,a0,a1,a2,t0,t1 tag=cave
log npc lo=0x80012e30 hi=0x80012e40 max=48 gpr=s2,s3,a0,a2,ra tag=mvn
log npc lo=0x80002cc0 hi=0x80002d00 max=48 gpr=s2,s3,ra,a0,a1,a2 tag=cavn
log gpr lo=0x800129d4 hi=0x80013200 max=256 gpr=s2,s3,ra,a0,a2 tag=gchg
log gpr lo=0x80002cc0 hi=0x80002d00 max=64 gpr=s2,s3,ra,a0,a2 tag=cag
