// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// ComboCover declared JsPromise job (pending → then / catch) plus no-job
// then-first on ComboExpr / ComboOr.

export type AwaitCase = {
  id: string
  dest: string
  needles: string[]
  boot?: number
  go?: number
  fail?: number
  note: string
}

export const AWAIT_CASES: AwaitCase[] = [
  {
    id: 'pend',
    dest: 'ComboCover',
    needles: [
      'await_pending = true',
      'void wireAwait()',
      'import await_status',
      'libwasmAwaitSupported()',
      '.await',
      '@style!"await-pend"',
    ],
    boot: 1,
    go: 0,
    fail: 0,
    note: '{#await job} pending first',
  },
  {
    id: 'then',
    dest: 'ComboCover',
    needles: [
      'await_then = false',
      'libwasmAwaitFailed()',
      '@style!"await-then"',
      'libwasmAwaitValue()',
      'vP.v =',
      'libwasmNoteAwaitOk',
    ],
    boot: 0,
    go: 1,
    fail: 0,
    note: 'wireAwait .await / Go shows {:then}',
  },
  {
    id: 'catch',
    dest: 'ComboCover',
    needles: [
      'await_catch = false',
      '@style!"await-catch"',
      'string e',
      'libwasmAwaitError()',
      'eP.e =',
      'libwasmNoteAwaitFail',
    ],
    boot: 0,
    go: 0,
    fail: 1,
    note: '{:catch e} {e}',
  },
  {
    id: 'ready',
    dest: 'ComboExpr',
    needles: ['await_then = true'],
    note: '{#await job then v} no JsPromise — then first, no wireAwait',
  },
  {
    id: 'or',
    dest: 'ComboOr',
    needles: ['await_then = true', 'string e'],
    note: 'undeclared job then-first + catch {e}',
  },
  {
    id: 'multi',
    dest: 'ComboCover',
    needles: [
      'JsPromise!Any other',
      'await_pending_other',
      'await_then_other',
      'await_catch_other',
      'other.await',
      'eP.e =',
      'eP2.e =',
      'vP.v =',
      'vP2.v =',
    ],
    note: 'second {#await other} has its own flags; both {:catch e}{e} get unique eP/eP2',
  },
]
