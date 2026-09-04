// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// ComboCover {#each}{:else}: seeded extras + wipe, empty voids, Empty inside ul.

export type EachElseCase = {
  id: string
  needles: string[]
  boot: number
  wipe: number
  note: string
}

export const EACH_ELSE_CASES: EachElseCase[] = [
  {
    id: 'extra',
    needles: ['extras.put', '@style!"else-extra"'],
    boot: 2,
    wipe: 0,
    note: 'seeded extras = ["one", "two"]',
  },
  {
    id: 'empty',
    needles: ['empty_extrasP', 'extras_empty', 'shrinkTo', '@style!"else-empty"'],
    boot: 0,
    wipe: 1,
    note: '<ul>{#each extras}{:else} Empty inside ul',
  },
  {
    id: 'void',
    needles: ['voids_empty = true', '@style!"else-void"'],
    boot: 0,
    wipe: 0,
    note: 'string[] voids; undeclared seed stays empty',
  },
  {
    id: 'none',
    needles: ['empty_voidsP', '@style!"else-none"'],
    boot: 1,
    wipe: 1,
    note: '{#each voids}{:else} None',
  },
]
