# r53-D1 investigation — wt_dcache_mem 33.35 regtoreg @:544 (forward tree)

Board: analyze-r52.json (sha d6ffd997). Path class `plain` regtoreg,
`reg0/CP → reg1/D`, 7 nodes, 33.35 FO4. No per-step FO4 in the json
(node-level billing is inside the path aggregate). The board also notes
`cycle dm: rd_data_o→rd_hit_oh_o not measured; cone stays on the board`.

## Signal chain (verified in source)

1. `rd_tag = rd_tag_i[vld_sel_q]` (:322) — **live port read** muxed by
   registered `vld_sel_q`; `vld_sel_q` is the reg startpoint class.
2. `wbuffer_cmp_addr = {rd_tag, bank_idx_q, bank_off_q}` (:463) —
   live tag + two registered fields.
3. `wbuffer_hit_oh[k] = (|wbuffer_all[k].valid) & (wtag == cmp_addr >>
   XLEN_ALIGN_BYTES)` (:474) — **wtag = {tag,idx,off} minus 3 byte bits
   ≈ 50b**, ×WbufferAllDepth (pow2-padded WtDcacheWbufDepth+2+fixup ≈ 8)
   full-width compares.
4. `merge_hit` = wbuffer_hit_oh | fixup hit bits → per byte-lane
   balanced merge tree (:524-551): 8 lanes × log2(8)=3 levels of
   {v,d,u} 17-bit leaf select → `fwd_data_c`/`fwd_be_c`/`fwd_user_c`.
5. → response arm mux → T2 registers (`:544`, rd_data/rd_hit regs).

Depth estimate: vld_sel mux (~2) + concat + 8×~50b compare (~6-8) +
fixup merge (~1-2) + 3-level 17b select tree (~12-15) + arm mux
(~4-6) ≈ matches 33.35.

## Candidates (est. gain)

1. **T1-registered compare (hit vector pipelined at the C→T2 edge)** —
   compute `wbuffer_hit_oh` against `{rd_tag_i[vld_sel_d], bank_idx_d,
   bank_off_d}` in T1, register `hit_oh_q` into T2; T2 keeps only the
   merge tree (~15 FO4 → module ≈ 22-24). **Same-cycle-allocation
   hazard**: a wbuffer entry allocated at the T1→T2 edge (store write
   landing while the load's compare is already registered) would be
   invisible to `hit_oh_q` → the load forwards stale DRAM data.
   Mitigation: OR in a bypass lane — the allocating write's own
   `{tag,idx,off}` is live at that edge, so `hit_oh = hit_oh_q |
   (alloc_v & wtag_match_alloc)`; the allocating store is the *youngest*
   entry, which is exactly the priority the merge wants (lowest index =
   wbuffer entry wins per the T46 fixup rule — verify the alloc slot's
   index position before assuming priority). Needs a leaf case:
   load T2-forward where the covering store allocates on the edge.
2. **Registered `rd_tag_q`** — capture `rd_tag_i[vld_sel_d]` at T1 and
   use `rd_tag_q` in `wbuffer_cmp_addr`; removes the port mux (~2-3
   FO4) but not the compare or tree. Cheap, stacks with (1) or alone
   gives ~30.5.
3. **Two-level compare split** — compare the low bits (idx+off ≈ 9b)
   first for a pre-filter then the 44b tag on survivors: reduces gate
   count, not the dependent depth — est. ~2 FO4, likely noise.
   (The flat AND-OR byte merge is a recorded T4 countercase: 33.3→35.0 —
   do not retry.)

Recommendation: (1) is the only candidate with real headroom; the
alloc-edge bypass must be verified before landing. (2) is a safe
partial if (1)'s hazard analysis fails.
