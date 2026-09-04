// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Table of {#each}{#if item.n ⊐ k [&&/|| [!]host]} cases (G113).
// Two items per list; first seeded to rhs+1, second stays 0.
// Flip toggles host `on` (starts true).

export type EachIfCmpCase = {
  id: string
  coll: string
  pred: string
  sync: string
  seed: string
  boot: number
  flip: number
  note: string
}

export const EACH_IF_CMP_CASES: EachIfCmpCase[] = [
  { id: 'gt', coll: 'gts', pred: 'it.n > 0', sync: 'sync_gts_n', seed: 'gts.items[0].n = 0 + 1', boot: 1, flip: 1, note: 'n > 0' },
  { id: 'lor', coll: 'lors', pred: 'it.n > 0 || !on', sync: 'sync_lors_on', seed: 'lors.items[0].n = 0 + 1', boot: 1, flip: 2, note: 'n > 0 || !on' },
  { id: 'eq', coll: 'eqs', pred: 'it.n == 0', sync: 'sync_eqs_n', seed: 'eqs.items[0].n = 0 + 1', boot: 1, flip: 1, note: 'n == 0 (unseeded item)' },
  { id: 'ne', coll: 'nes', pred: 'it.n != 0', sync: 'sync_nes_n', seed: 'nes.items[0].n = 0 + 1', boot: 1, flip: 1, note: 'n != 0' },
  { id: 'lt', coll: 'lts', pred: 'it.n < 1', sync: 'sync_lts_n', seed: 'lts.items[0].n = 1 + 1', boot: 1, flip: 1, note: 'n < 1' },
  { id: 'le', coll: 'les', pred: 'it.n <= 0', sync: 'sync_les_n', seed: 'les.items[0].n = 0 + 1', boot: 1, flip: 1, note: 'n <= 0' },
  { id: 'ge', coll: 'ges', pred: 'it.n >= 1', sync: 'sync_ges_n', seed: 'ges.items[0].n = 1 + 1', boot: 1, flip: 1, note: 'n >= 1' },
  { id: 'ga', coll: 'gas', pred: 'it.n >= 1 && on', sync: 'sync_gas_on', seed: 'gas.items[0].n = 1 + 1', boot: 1, flip: 0, note: 'n >= 1 && on' },
  { id: 'hf', coll: 'hfs', pred: 'it.n > 0 && on', sync: 'sync_hfs_on', seed: 'hfs.items[0].n = 0 + 1', boot: 1, flip: 0, note: 'on && n > 0 (host first)' },
  { id: 'hi', coll: 'his', pred: 'it.n > 1', sync: 'sync_his_n', seed: 'his.items[0].n = 1 + 1', boot: 1, flip: 1, note: 'n > 1 (rhs not 0)' },
  { id: 'nt', coll: 'nts', pred: '!(it.n > 0)', sync: 'sync_nts_n', seed: 'nts.items[0].n = 0 + 1', boot: 1, flip: 1, note: '!(n > 0) — unseeded item' },
  { id: 'zed', coll: 'zeds', pred: 'it.n > 0', sync: 'sync_zeds_n', seed: '', boot: 0, flip: 0, note: 'empty {#each} string[] zeds = []' },
  { id: 'vs', coll: 'vss', pred: 'it.n > lim', sync: 'sync_vss_lim', seed: 'vss.items[0].n = lim + 1', boot: 1, flip: 1, note: 'n > lim (item vs host)' },
]
