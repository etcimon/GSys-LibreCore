# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# S4: 20M cap after 2M plat_hc=4 coldboot_done=1 still in relocated DTB
# next_tag. Cookie or new pin. Do not log mem.
exit cookie off=0x1000 val=0x51b1babe tag=cookie
exit pin mepc=0x80012c56 mcause=1 hart=0 after=163000 tag=pin12c56
