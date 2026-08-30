# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# S4: 180k npc=12918 is a live next_tag name-skip, not a stuck fetch.
# Confirm 12c56 IAF stays gone at 2M. Do not log mem.
exit pin mepc=0x80012c56 mcause=1 hart=0 after=163000 tag=pin12c56
