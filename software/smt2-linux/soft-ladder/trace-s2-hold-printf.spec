# SPDX-License-Identifier: MIT
# %s of platform+8 ("Generic\\0" in ELF). Catch lbu and DRAM name.
exit pin mepc=0x80012eb2 mcause=6 hart=0 tag=pin12eb2
log commit lo=0x8000a146 hi=0x8000a146 after=150000 max=24 gpr=s5,a5,s2,ra tag=plbu
log mem off=0x403f0 after=150000 max=6 tag=pname
log mem off=0x42b48 after=150000 max=4 tag=tbuf
