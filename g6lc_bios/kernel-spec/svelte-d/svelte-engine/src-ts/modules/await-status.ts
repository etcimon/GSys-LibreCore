// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Last-await bookkeeping for asyncify + wasm-eh. `.await` must not throw
// across env.libwasm_await__void (rewind re-enters from the top). JS
// records reject here; D reads the flag *after* rewind in the same
// function and may then throw/catch off the import.

export type AwaitSettlement = {
  failed: boolean
  reason: string
  value: string
  exportName: string
}

const empty: AwaitSettlement = {
  failed: false,
  reason: '',
  value: '',
  exportName: '',
}

let last: AwaitSettlement = { ...empty }

export function formatAwaitValue(v: unknown): string {
  if (v == null) return ''
  if (typeof v === 'string') return v
  if (typeof v === 'number' || typeof v === 'boolean' || typeof v === 'bigint')
    return String(v)
  if (typeof v === 'function') return ''
  try {
    const s = JSON.stringify(v)
    if (typeof s === 'string') return s
  } catch {
    /* circular */
  }
  try {
    return String(v)
  } catch {
    return ''
  }
}

export function formatAwaitReason(e: unknown): string {
  if (e == null) return ''
  if (typeof e === 'string') return e
  const wasmEx =
    typeof WebAssembly !== 'undefined' &&
    typeof (WebAssembly as any).Exception === 'function' &&
    e instanceof (WebAssembly as any).Exception
  if (wasmEx) return 'WebAssembly.Exception'
  const err = e as { message?: unknown; stack?: unknown; name?: unknown }
  if (err && typeof err.stack === 'string' && err.stack.length)
    return err.stack
  if (err && typeof err.message === 'string' && err.message.length)
    return err.name ? `${err.name}: ${err.message}` : err.message
  try {
    return String(e)
  } catch {
    return 'await failed'
  }
}

export function recordAwaitOk(
  exportName = '',
  value: unknown = ''
): AwaitSettlement {
  last = {
    failed: false,
    reason: '',
    value: formatAwaitValue(value),
    exportName,
  }
  noteHost(last)
  return last
}

export function recordAwaitFail(
  e: unknown,
  exportName = ''
): AwaitSettlement {
  last = {
    failed: true,
    reason: formatAwaitReason(e),
    value: '',
    exportName,
  }
  noteHost(last)
  return last
}

export function getLastAwait(): AwaitSettlement {
  return last
}

export function clearLastAwait(): void {
  last = { ...empty }
}

export function isAsyncifiedExports(ex: any): boolean {
  return !!ex && typeof ex.asyncify_get_state === 'function'
}

function noteHost(s: AwaitSettlement): void {
  const w = typeof window !== 'undefined' ? (window as any) : null
  if (!w) return
  w.__svelteDLastAwait = s
  if (typeof w.__svelteDNoteAwait === 'function') {
    try {
      w.__svelteDNoteAwait(s)
    } catch {
      /* debug bridge optional */
    }
  }
}
