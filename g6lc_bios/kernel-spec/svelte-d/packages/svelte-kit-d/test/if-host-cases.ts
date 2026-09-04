// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// ComboIfHost host-level {#if}. Flip toggles `on` only.

export type HostIfCase = {
  id: string
  pred: string
  boot: number
  flip: number
  note: string
}

export const HOST_IF_CASES: HostIfCase[] = [
  { id: 'on', pred: 'on', boot: 1, flip: 0, note: '{#if on}' },
  { id: 'not', pred: '!on', boot: 0, flip: 1, note: '{#if !on}' },
  { id: 'and', pred: 'on && !hide', boot: 1, flip: 0, note: '{#if on && !hide}' },
  { id: 'or', pred: 'flag || on', boot: 1, flip: 1, note: '{#if flag || on} flag stays true' },
  { id: 'gt', pred: 'n > 0', boot: 1, flip: 1, note: '{#if n > 0} n stays 1' },
  { id: 'eq', pred: 'who == extra', boot: 1, flip: 1, note: '{#if who == extra}' },
]
