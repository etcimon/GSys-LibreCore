# Heritage and attribution

GSys LibreCore is a derivative of the **OpenHW Group CVA6**, which is itself a
descendant of the **PULP Platform "Ariane"** core from ETH Zurich and the
University of Bologna.

This page exists for three reasons. It is good practice under Apache-2.0 §4(d)
and Solderpad §4. It is honest. And it is commercially useful: a prospective
licensee needs to know exactly which parts of this repository they already hold
for free, and which parts they do not.

## Lineage

```
ETH Zurich / University of Bologna — "Ariane"      (Solderpad SHL-0.51)
                    |
                    v
OpenHW Group — CORE-V CVA6                          (Apache-2.0 WITH SHL-2.0/2.1)
   + Thales DIS design services SAS  — configuration packages, verification
   + CEA, Univ. Grenoble Alpes, Inria, TIMA — HPDcache subsystem
   + PlanV Technologies — Altera/Agilex FPGA integration
   + lowRISC, PULP Platform — utilities, technology cells
   + SiFive, UC Regents — Apache-2.0 / BSD-3-Clause material
                    |
                    v
GSys LibreCore (G6LC)                     (CERN-OHL-S-2.0 OR GSys Commercial,
Etienne Cimon / GlobecSys Inc.             for LibreCore-original material only)
```

## What is LibreCore-original, and what is not

Most of the *processor RTL* was written by other people; most of the *product
surface* around it is LibreCore. Measured by **tracked blob size** of
`origin/master` versus HEAD on the claim surface
(RTL SV under `core/` + `corev_apu/` + `sv-timing/` + `build-platform/` +
`docs/website/`), origin is about **37%** of HEAD — so about **63%** of that
surface is LibreCore growth (`sv-timing/`, `build-platform/`, and
`docs/website/` have no origin counterpart). **RTL SV alone** remains about
**82%** origin-sized. See `monorepo-soak/size-claim-scopes.py` and
`README.md` §Licensing.

LibreCore-original material (tier R in `.licensing-tiers`) is, in substance:

| Area | Files |
|---|---|
| Out-of-order backend | `core/ooo/**` — ROB, RAT, PRF, freelist, issue queue, LSQ, memory-dependence predictor, rename, dispatch |
| Coarse-grain SMT | `core/smt/**` — per-hart state, CSR/PC banks, regfile, thread select |
| Issue slices | `core/g6lc_slice_*.sv` |
| Branch prediction | `core/frontend/g6lc_bp_*.sv` — TAGE, ITTAGE, gshare, loop, statistical corrector, checkpointing; plus FTQ, FDIP, loop buffer |
| Cache extras | `g6lc_way_predictor`, `g6lc_rrip_repl`, `hpdcache_victim_rrip` |
| Uncore | `corev_apu/{coherence,l2_cache,l3_cache}/**` — coherence hub, snoop filter, LR/SC tracker, invalidation bus, L2, L3, server prefetcher |
| Cluster / vector attach | `corev_apu/src/g6lc_{cluster,ara_attach,axi_2to1_mux}.sv` |
| Config profiles | `core/include/g6lc64_*_config_pkg.sv` |
| Reference device trees | `corev_apu/bootrom/ariane-{linux,smt2,server-math-v}.dts` |

Tooling — `build-platform/`, `sv-timing/`, `verif/` scripting, `docs/`,
`software/` — is LibreCore-original and **MIT**.

Some tier-R files are *substantially modified upstream files* rather than new
ones (`core/csr_regfile.sv`, `core/decoder.sv`, `core/perf_counters.sv`,
`core/frontend/frontend.sv`, `core/frontend/ras.sv`,
`core/cache_subsystem/g6lc_icache.sv`, `corev_apu/src/ariane.sv`). Those files
**retain their original copyright notices and licence identifiers verbatim**; only
the file as a whole carries an additional outbound offer, as Apache-2.0 §4
permits. See `REUSE.toml` for the machine-readable statement and
`AGENTS-licensing.md` for the measured deltas.

Two files carry a LibreCore modification that was measured as **too small** to
justify relicensing — `core/include/ariane_pkg.sv` (+39 lines in 806) and
`corev_apu/clint/clint.sv` (+8 lines in 264). They remain entirely under ETH
Zurich's Solderpad licence. We could have claimed them; we decided the claim
would not have been honest.

## What this means for you

- **You already hold the upstream RTL footprint for free** (the ~82% of current
  `core/` + `corev_apu/` SystemVerilog by the origin/HEAD size comparison above),
  directly from its authors under Solderpad/Apache/BSD. Nothing in LibreCore's
  licensing changes that, and the GSys Commercial License explicitly does not
  purport to license it (`LICENSE.GSys-Commercial` §4.2).
- **Upstream CVA6 remains available** at `github.com/openhwgroup/cva6` under its
  own permissive terms. Reciprocity here binds the LibreCore delta only. We say
  so plainly rather than leaving you to discover it.
- **The FPGA bootrom is a separate GPL work** and is excluded from both LibreCore
  licences. See `corev_apu/fpga/src/bootrom/README.md`.

## Trademarks

"CVA6", "CORE-V" and "OpenHW" are marks of the **OpenHW Group**. "Ariane" and
"PULP" are associated with **ETH Zurich** and the **University of Bologna**.
"RISC-V" is a registered trademark of **RISC-V International**. Neither
Apache-2.0 §6 nor Solderpad §6 grants any trademark rights — which is precisely
why this project is renamed rather than continuing to call itself CVA6.

References to CVA6 in this repository are factual and historical: upstream
attribution, device-tree fallback `compatible` strings, upstream CI workflow
names, and this page. They do not assert any affiliation with or endorsement by
the OpenHW Group, ETH Zurich, the University of Bologna, Thales, CEA or RISC-V
International.

## Thanks

LibreCore exists because a large number of people published serious engineering
work under licences that permitted this. The full attribution list is in
`NOTICE` §4 and in the files themselves.
