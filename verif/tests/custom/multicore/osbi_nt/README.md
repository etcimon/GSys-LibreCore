# OpenSBI next_tag trampoline blobs

Machine-code excerpts from `fw_payload_peel_both.elf` (pin md5
`bc7ed11dab17454fd147e4927ba07fef`). Used only by `mini_fdt_nt_osbi.S`.
`namelen.bin` / `by_offset.bin` have the entry `jal x0` cave replaced with
`addi sp,sp,-144` / `-48` (the 4B the cave deleted). Nops left the
callee `addi +144/+48` unmatched and hung FDT_PROP after a correct
restore (`ra=0x800130b6` epilogue loop).

Regenerate (from repo root, WSL):

```bash
python3 verif/tests/custom/multicore/osbi_nt/extract.py
```

`namelen.bin` is the **unpatched** pin excerpt. `patch_namelen_fence.py` is
experiment-only (does not peel OpenSBI). Restore from `namelen.bin.pre-fence`
after any insert. Directed 2026-08-25 (proxy flavour B, h0):

| Insert | Tag | Result |
|--------|-----|--------|
| `fence rw,rw` at `0x8001307e` (in FDT_PROP loop) | `b1-nt-nl-h0-fence` | hang `tohost=0` @40000 |
| `fence rw,rw` at `0x80013074` (after 5 mid-saves, not in loop) | `b1-nt-nl-h0-fence2` | hang `tohost=0` @40000 |
| `addi x0,x0,0` at `0x80013074` (reloc control) | `b1-nt-nl-h0-nop4` | pin `tohost=13` @11083 |

Software five mid-saves + `fence rw,rw` still **PASS** (`b1-nt-five-fence`).
Do not land a namelen fence peel. `b1-nt-nl` / `b1-nt-nl-h0` stay the red gate.

Cave at `0x80013040` is `j 0x80002d48` (soft getprop skip), not `addi sp`.
`extract.py` also writes `namelen_cut.bin` (ret after 2nd `jal next_tag`) and
`namelen_cut_bo.bin` (ret before `jal by_offset`) — both **hang** on flavour B
(truncated I-stream). Full namelen + stub `by_offset` checker
(`mini_fdt_nt_osbi_bochk.S`) **FAIL write 3 @10649**: live s3 is already
dead at `jal by_offset`. The five `c.sdsp` bytes match software five (PASS);
stock then goes straight into `jal next_tag@1307e`. Software **tight**
(those five then the stock tail, no extra CF, low VA) **FAIL s3**
(`b1-nt-nl-tight`). Mid-count: 0 hang, 1–3 PASS, 4 hang, 5 s3
(`DCACHE_MAX_TX=4`). Extra CF/fence drains; pin VA is not required.
Late L1 write after ACK (`*-latel1` / `*-latel1b`) still s3 @11033;
pending hung n3 — reverted. Check-hit `wr_req` (`*-chkhit`) PASSed tight
(even with overlay) but hung h0/nl; in-flight-only (`txblock`) s3 + pin.
Do not extra `wr_req`. Keep-all-ACK'd wbuffer (`*-keepv*`) PASSed tight
(even with overlay) but hung h0 — reverted. Last-ACK keep (`*-keep1`) s3 (alias not last of 5) and hung sw — reverted.
Cap-5 (`*-keep5`) still s3 (prologue fills the cap). Keep-all hung h0.
Keep-all with stock `empty_o` (`*-keepv-emp`) still hung h0 (tight PASS).
Cap-7 PASSed tight, hung h0; cap-6 PASSed tight, hung sw. Occupancy
caps closed. Skip overlay while wbuffer busy (`*-ovl-wbuf`) still s3 @11033
(alias already ACK'd). Hold-grant update (`*-hold-grant`) still s3 @10633. TRACE
`s1-tight-hold-trace`: `g1ao_hold` **DEAD** at 2nd `ld s3` (`v=0 hit=0`,
leftover PA `0x80046e38` not mini alias `0x80046ec8`). Poison is stale L1.
ACK L1 inval (`*-ackinv`): tight **PASS @22606**, h0 **HANG @40000** —
reverted (all-way VOID). VOID-until-check (`*-voidchk`) still s3 (alias ACK
is checked). Checked hit-way (`*-voidchk2`) tight PASS + h0 hang (miss-storm).
Keep-until-`wr_ack` (`*-wrack`): tight **PASS @10616**, h0 **HANG @40000**.
Consume-on-snoop (`*-snoop`): tight **PASS @10407**, h0 **tohost=12 @10264**,
sw hang. Steal-oldest-keep (`*-steal`): tight **PASS @10580**, h0 **HANG @40000**.
Keep+`empty_o` (`*-empkeep`): tight **PASS @10616**, h0 **HANG @40000**
(not sticky). Keep h0 hang TRACE: namelen **`0x8001311a–0x80013176`** (FDT_PROP), s3=0,
SP growing. Keep-nonzero (`*-keepnz`): tight **PASS @10616**, h0 **HANG @40000**.
Keep-one-newest (`*-keep1nz`): tight **s3 @10633**, h0 **pin 13 @11079**.
Keep cap 3 (`*-keep3nz`): tight **PASS @10616**, h0 **HANG @40000**.
Keep cap 2 (`*-keep2nz`): tight **PASS @10616**, h0 **HANG @40000**.
Keep TTL 512 (`*-keep512`): tight **PASS @10616**, h0 **HANG @40000**.
Keep coalesced-only (`*-keepcoal`): tight **tohost=12 @10763**, h0 **pin 13 @10869**.
One pending-alias (`*-keeppend`): tight **s3 @10633**, h0 **pin 13 @11079** (same as `keep1nz`).
Two pending-alias (`*-keeppend2`): tight **PASS @10616**, h0 **HANG @40000** (same as `keep2nz`).
TRACE keepcoal: tight **s3** (2nd `ld s3` still `0x12b2a`); first 12 was a coalesce race.
One-cycle `wr_req` retry (`*-wr1`): **tight/h0/sw HANG @40000**. Do not retry way-write after evict.
Deny-hit poison (`*-nackhit`): tight **s3 @10639**, h0 **pin 13 @10878**. Stock pairing.
wr_ack TRACE: lenp **denied @t=10229**, FDT deny @t=10249 steals one-entry poison.
Two-entry poison (`*-nackhit2`): **tight/h0 HANG @40000** (had latches).
Sticky poison (`*-nackstick`): tight **s2 @10640** (s3 passed); h0 **HANG**.
Latch-free 2-entry + consume (`*-nack2`): tight **s2 @10646**; h0 **HANG**.
Latch-free 2-entry `wr_cl`-only (`*-nack2cl`): tight **s2 @10646**; h0 **HANG**
(same pairing; nackhit2 tight hang was latches). Idx-only all-ways
(`*-nack2idx`): still **s2 @10646**. TRACE: `c.ldsp s2,32(sp)` @`12a6e` PA
`0x80046ed0` got **0** (DRAM=FDT). Poison closed. Data-snoop keep
(`*-snoopd`): **tight PASS @10614**, sw **PASS @10713**, h0 **HANG**
(FDT_PROP occupancy). Lifetime cap 2 (`*-snoopd2`): same pairing —
the two keeps hang namelen. TTL 512 (`*-snoopd2t`): still h0 **HANG**
(pair poisons FDT_PROP before expiry). One-shot L1 write on snoop
(`*-snoopwr`): tight/sw **PASS**, h0 **HANG**. Next: keep only if
stored data[31:28]==4'h8. Pointer keep (`*-snoopd8`): tight/sw **PASS**,
h0 **HANG** (still FDT_PROP s3=0). Stock h0 wrack: same two pointer
denies as tight (`10222`/`10242`), pin 13. TTL 400 (`*-snoopd8t`):
tight/sw **PASS**, h0 **HANG** — restore got lenp then FDT_PROP hang.
**nackinv kept** + addi-sp prologues: **h0 PASS @16268**, tight PASS
@10645, nt-osbi PASS @16279. Overlay stock. ACK-before-check stock.
`mini_stq_alias_jal` **PASS @986** hart1 WFI park.
