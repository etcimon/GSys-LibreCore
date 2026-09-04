// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// ComboSurf svelte:boundary failed(error, reset) + throwBoundary.
// ComboMedia is the earlier soak dest.

export type BoundaryCase = {
  id: string
  dest: string
  needles: string[]
  boot?: number
  trip?: number
  retry?: number
  note: string
}

export const BOUNDARY_CASES: BoundaryCase[] = [
  {
    id: 'ok',
    dest: 'ComboSurf',
    needles: ['boundary_ok = true', '@style!"bound-ok"'],
    boot: 1,
    trip: 0,
    retry: 1,
    note: 'body Ok mounted first',
  },
  {
    id: 'fail',
    dest: 'ComboSurf',
    needles: ['boundary_failed = false', '@style!"bound-fail"', 'throwBoundary'],
    boot: 0,
    trip: 1,
    retry: 0,
    note: 'failed snippet + throwBoundary("boom")',
  },
  {
    id: 'retry',
    dest: 'ComboSurf',
    needles: ['resetBoundary', '@style!"bound-retry"'],
    note: 'Retry remounts Ok',
  },
  {
    id: 'media',
    dest: 'ComboMedia',
    needles: ['throwBoundary', 'failBoundary', 'resetBoundary', '@style!"fail-msg"'],
    note: 'ComboMedia trip / retry soak dest',
  },
]
