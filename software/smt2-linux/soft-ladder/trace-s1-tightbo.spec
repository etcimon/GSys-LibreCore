# SPDX-License-Identifier: MIT
# tightbo hang tail: by_offset + namelen epilogue.
exit pin mepc=0x80012eb2 mcause=6 hart=0 tag=pin12eb2
log npc lo=0x80012e00 hi=0x80013200 after=38000 max=48 tag=npc
log commit lo=0x80012e00 hi=0x80013200 after=38000 max=48 gpr=sp,s2,s3,ra,a0 tag=hang
log commit lo=0x80012e26 hi=0x80012eb8 after=10000 max=24 gpr=sp,s2,s3,ra,a0 tag=byoff
log commit lo=0x800130b2 hi=0x800130b8 after=10000 max=8 gpr=sp,s2,s3,ra,a0 tag=jalbo
