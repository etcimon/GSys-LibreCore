// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// ComboCover bind:value / checked / open / group / files.
// Live: one host write per row (button, click, or select).

export type BindCase = {
  id: string
  needles: string[]
  action: 'note' | 'ok' | 'open' | 'pick' | 'files'
  note: string
}

export const BIND_CASES: BindCase[] = [
  {
    id: 'note',
    needles: ['@prop!"value" string note', '@style!"bind-note"'],
    action: 'note',
    note: 'bind:value textarea/input + this.update.note',
  },
  {
    id: 'ok',
    needles: ['@prop!"checked" bool ok', '@style!"bind-ok"'],
    action: 'ok',
    note: 'bind:checked writes host ok',
  },
  {
    id: 'open',
    needles: ['@prop!"open" bool open', '@style!"bind-open"'],
    action: 'open',
    note: 'bind:open details',
  },
  {
    id: 'pick',
    needles: ['@prop!"value" string pick', 'pick == "b"', '@style!"bind-pick"'],
    action: 'pick',
    note: 'bind:value select + bind:group radios share pick',
  },
  {
    id: 'files',
    needles: ['@prop!"files" Handle files', '@style!"bind-files"'],
    action: 'files',
    note: 'bind:files Handle — IR only',
  },
]
