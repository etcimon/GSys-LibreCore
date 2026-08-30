# SPDX-License-Identifier: MIT
# S4: offset_ptr NULL epi 1296a-12972 vs next_tag@12974. Do not log mem.
# drop= on cmtnt is I13 cancel (arch ack hides it).
log commit lo=0x80012966 hi=0x80012973 max=20 after=124880 tag=cmtail
log commit lo=0x80012974 hi=0x80012994 max=40 after=124880 tag=cmtnt
log commit lo=0x800129c0 hi=0x800129d4 max=8 after=124880 tag=cmtsw
log commit lo=0x800129fe hi=0x80012a12 max=12 after=124880 tag=cmtepi
log npc lo=0x8001296a hi=0x80012973 max=12 gpr=ra,sp,a0,s3 tag=offail after=124880
log npc lo=0x80012990 hi=0x80012994 max=8 gpr=ra,sp,a0,s3 tag=ntjal after=124880
exit pin mepc=0x8001e000 mcause=1 hart=0 after=2000 tag=pinfdt
