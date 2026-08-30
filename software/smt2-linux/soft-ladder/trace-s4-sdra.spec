# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# S4: SP 46f50@157908 -> 46f20@157913. 13946 does NOT commit until
# 157923. kill vq=17f16 (fdt_node_is_enabled, also addi -48) at 157908
# while parse_hart_id still retiring. Catch that prologue. Do not log mem.
log commit lo=0x80017f16 hi=0x80017f28 max=16 after=157800 gpr=ra,sp tag=nien
log commit lo=0x80017f54 hi=0x80017f88 max=16 after=157800 gpr=ra,sp tag=niepi
log commit lo=0x80013946 hi=0x80013956 max=8 after=157800 gpr=ra,sp tag=gppro
log commit lo=0x80017fd6 hi=0x80017ff4 max=16 after=157800 gpr=ra,sp tag=mid
exit pin mepc=0x80012c56 mcause=1 hart=0 after=163000 tag=pin12c56
