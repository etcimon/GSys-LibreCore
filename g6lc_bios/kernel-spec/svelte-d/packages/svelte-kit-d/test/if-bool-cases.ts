// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// ComboNest {#each}{#if [!]item.ok [&&/|| [!]on]} and the G109–G112 cmps
// that still live on that fixture. Flip toggles host `on`.

export type EachIfBoolCase = {
  id: string
  pred: string
  sync: string
  boot: number
  flip: number
}

export const EACH_IF_BOOL_CASES: EachIfBoolCase[] = [
  { id: 'ok', pred: 'it.ok', sync: 'sync_rows_ok', boot: 1, flip: 1 },
  { id: 'pick', pred: 'it.ok && on', sync: 'sync_picks_on', boot: 1, flip: 0 },
  { id: 'hold', pred: 'it.ok || on', sync: 'sync_holds_on', boot: 2, flip: 1 },
  { id: 'skip', pred: '!it.ok', sync: 'sync_skips_ok', boot: 1, flip: 1 },
  { id: 'cut', pred: '!it.ok && on', sync: 'sync_cuts_on', boot: 1, flip: 0 },
  { id: 'keep', pred: '!it.ok || on', sync: 'sync_keeps_on', boot: 2, flip: 1 },
  { id: 'drop', pred: 'it.ok && !on', sync: 'sync_drops_on', boot: 0, flip: 1 },
  { id: 'both', pred: '!it.ok || !on', sync: 'sync_boths_on', boot: 1, flip: 2 },
  { id: 'nand', pred: '!it.ok && !on', sync: 'sync_nands_on', boot: 0, flip: 1 },
  { id: 'hit', pred: 'it.n > 0', sync: 'sync_hits_n', boot: 1, flip: 1 },
  { id: 'more', pred: 'it.n > 0 && on', sync: 'sync_mores_on', boot: 1, flip: 0 },
  { id: 'lot', pred: 'it.n > 0 || on', sync: 'sync_lots_on', boot: 2, flip: 1 },
  { id: 'few', pred: 'it.n > 0 && !on', sync: 'sync_fews_on', boot: 0, flip: 1 },
]
