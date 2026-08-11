# virt_ai_card — virtual PCIe AI card (userspace)

Hostless **soft UIO / eventfd** stand-in for the LibreCore PCIe AI card.
Pure Python (stdlib); numpy not required.

| Module | Role |
|---|---|
| `driver.py` | `VirtualUioDevice` (4 KiB MMIO, CAP seed, INT8 GEMM on doorbell), `VirtualEventFd` |
| `transport.py` | `VirtualPcieLink` — localhost TCP, length-prefixed JSON |
| `card_agent.py` | Card-side agent (bind, run jobs, signal IRQ, return C) |
| `host_client.py` | Host-side connect / BAR4 put / gemm_s8 |
| `smoke.py` | E2E: local driver + multi-ticket + TCP path |

## Board

`corev-mb/boards/virt-ai-pcie/board.json` — class `virtual`, primary UIO:

```text
virt://virt-ai-pcie/island0   # soft-sticky
virt://virt-ai-pcie/island0_irq  # eventfd
```

## Run

```bash
# monorepo root
python3 ai-tensor/tools/virt_ai_card/smoke.py
bash monorepo-soak/run-virt-ai-card.sh
# optional
bash monorepo-soak/run-ai-tensor.sh virt-card
```

Expected golden: \(A{=}[[1,2],[3,4]], B{=}[[5,6],[7,8]] \Rightarrow C{=}[[19,22],[43,50]]\).

## Claim order

1. Wait (`VirtualEventFd.wait` / sticky IRQ)
2. **Claim DONE** — write 1 @ `0x10C` (`claim_done`)
3. Clear / rearm eventfd

See `architecture/ai-matrix/board-uio-eventfd.md` § Virtual board.

## License

MIT (tier T tooling).
