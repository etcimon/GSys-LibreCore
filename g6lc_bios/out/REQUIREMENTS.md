# Inferred architecture requirements (from BoardSpec)
- reserved DRAM carve-out 0x100000 for runtime BIOS (Linux maps view-only)
- SBI SRST (or equivalent) for reboot/shutdown from the management port
- in-kernel HTML+JS display stays mapped for KVM-over-port
- HolyC dual-band TCP remains open after Linux handoff
- always-on domain or Wake-on-LAN on the management port
- PMP/PMA lock of immutable sections after handoff: config,keys,boot-policy
- QEMU UART1 -serial tcp:127.0.0.1:2222,server,nowait (ssh-like HolyC REPL)
