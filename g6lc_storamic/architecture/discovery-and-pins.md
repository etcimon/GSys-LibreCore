# Stick discovery and physical profiles

Passive sticks contain RAM, flash or both with carrier-side controllers. Active
sticks later add a first-party controller and serial PHY. These are separate
physical profiles; connector compatibility requires explicit electrical proof.
Initial insertion/removal is power-off only.

## Discovery

```text
ABSENT -> PRESENT -> POWER_CHECK -> IDENTIFY -> VALIDATE
       -> INITIALIZE/TRAIN -> READY -> QUIESCE -> FAULT/REMOVED
```

Synchronize/debounce presence. Identity and geometry need a keyed board-approved
descriptor/straps and supported chip ID/parameter reads. A literal RAM/flash-only
BOM without descriptor storage needs a fixed electrical profile and sufficient
on-chip identification. Presence alone is not geometry. Never probe by destructive
writes or guessed voltage. Unknown/unsupported modules stay disabled.

Bound descriptor version/length/checksum, persistent identity, voltage/profile,
RAM/flash flags, capacities, address geometry, erase/program sizes, timing and
ECC/persistence capability against controller limits. Descriptor data is not
trusted merely because its checksum matches.

Track media-ready, RAM-ready and persistence-ready independently. Freeze RAM
region assignment before boot; removal cannot compact live addresses. Match
equal extents for optional interleaving and map remaining capacity separately.
Drive identity follows the module/namespace, not Linux numbering or slot alone.
Devices without unique identity require a descriptor/provisioning policy.

## Signal budgets, not routed pinouts

| Profile | Signal calculation |
| --- | --- |
| Differential x8 HyperBus-style RAM | 8 DQ + RWDS + 2 CK + CS + RESET = 13 |
| Differential x16 extended HyperBus | 16 DQ + 2 RWDS + 2 CK + CS + RESET = 22 |
| Separate QSPI flash | 4 DQ + CK + CS = 6, before optional reset/status |
| Mixed passive example | 13 + 6 + presence = 20 per slot |
| Compatible shared RAM/flash example | 13 + second CS + presence = 15 per slot |
| Active x4 serial example | 16 TX/RX conductors + 2 refclock + reset + presence = 20 |
| Repository VCU118 DDR4 x64 port | 64 DQ + 16 DQS + 8 DM/DBI + 27 address/control = 115 |
| Illustrative single-rank DDR4 x32 | 32 DQ + 8 DQS + 4 DM/DBI + 27 address/control = 71 |
| Illustrative single-rank DDR4 x16 | 16 DQ + 4 DQS + 2 DM/DBI + 27 address/control = 49 |

The DDR4 figures exclude power/reference/ground and optional parity/alert signals;
address geometry, bank groups and rank count can change them. The 115-signal
example is the VCU118 interface in `corev_apu/fpga/src/ariane_xilinx.sv`, not a
universal DIMM pinout. An x72 ECC arrangement adds data/strobe/mask signals and
can require approximately 127 signal contacts before optional controls.

Shared descriptor wiring, address mux/isolation, power enable/good, alerts and
test pins add to these counts. Shared buses save signals but limit bandwidth and
increase loading/fault coupling. Shared HyperBus does not imply arbitrary NAND
compatibility.

`signal_pads = shared_controls + sum(slot_signals) + host_interface_signals`.
Package balls additionally include power/ground/reference, calibration and test;
connector contacts need current capacity and return paths. Runtime presence
cannot change a fabricated ball count. Different `MaxSticks` package variants can.

The mechanical goal is right-angle sockets seating short sticks parallel to a
PCIe carrier, with keyed insertion, retention, airflow and cooling clearance.
Do not assume a SO-DIMM socket is qualified for the active link's serial rate.
Final pin assignments require actual device/connector data and SI/PI analysis.

At 200 MHz DDR, x8 is 0.4 GB/s and x16 is 0.8 GB/s raw. Fewer pins do not imply
DDR4 throughput. Active serial links move the parallel RAM bus onto the stick,
reducing carrier signals while adding distributed controllers, PHYs and power.

DDR4-3200 x64 has 25.6 GB/s raw payload bandwidth; x32 has 12.8 GB/s. A hypothetical
four-lane link at 16 Gb/s with 128b/130b coding has a 7.88 GB/s per-direction coding
ceiling, before headers/credits/turnaround and media stalls. Four independent links
offer 31.51 GB/s at that boundary, not at every master. A host x8 link at 32 GT/s
also has a 31.51 GB/s coding ceiling before its protocol overhead.

Sustained throughput is raw rate times measured protocol/service efficiency,
bounded by all narrower stages. No sustained efficiency is measured for Storamic;
publish a workload-specific range only after simulation and physical qualification.
Serial latency and credit depth can limit random 64-byte demand long before
sequential DMA reaches the coding ceiling.
