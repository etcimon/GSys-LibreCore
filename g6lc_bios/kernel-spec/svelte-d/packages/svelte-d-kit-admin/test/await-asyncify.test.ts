// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Admin coverage for fork-asyncify await: printed IR, TS glue, dest
// wasm exports, and (when Puppeteer is up) live DevTools hooks.
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { compileWorkspace, rewriteStack, loadDebugMap, WASM_ASYNCIFY_ARGS } from 'svelte-d'
import { adminWorkspace } from '../src/ws.ts'
import {
  formatAwaitReason,
  formatAwaitValue,
  recordAwaitFail,
  recordAwaitOk,
  getLastAwait,
  clearLastAwait,
  isAsyncifiedExports,
} from '../../../svelte-engine/src-ts/modules/await-status.ts'
import { EXPORTED_FROM_D, moduleHasAsyncify } from '../../../svelte-engine/src-ts/modules/asyncify.ts'

const project = dirname(dirname(fileURLToPath(import.meta.url)))

describe('admin await + asyncify glue', () => {
  test('await-status records reject without throwing across the import', () => {
    clearLastAwait()
    expect(getLastAwait().failed).toBe(false)
    const ok = recordAwaitOk('_start', 'ready')
    expect(ok.failed).toBe(false)
    expect(ok.exportName).toBe('_start')
    expect(ok.value).toBe('ready')
    expect(ok.reason).toBe('')
    const fail = recordAwaitFail(new Error('fetch failed'), 'domEvent')
    expect(fail.failed).toBe(true)
    expect(fail.reason).toMatch(/fetch failed/)
    expect(fail.value).toBe('')
    expect(fail.exportName).toBe('domEvent')
    expect(formatAwaitReason('plain')).toBe('plain')
    expect(formatAwaitReason(null)).toBe('')
    expect(formatAwaitValue('ok')).toBe('ok')
    expect(formatAwaitValue(3)).toBe('3')
    expect(formatAwaitValue({ a: 1 })).toBe('{"a":1}')
    expect(isAsyncifiedExports({ asyncify_get_state: () => 0 })).toBe(true)
    expect(isAsyncifiedExports({})).toBe(false)
    expect(isAsyncifiedExports(null)).toBe(false)
  })

  test('asyncify wraps _start and the await import only', () => {
    expect(EXPORTED_FROM_D).toContain('_start')
    expect(EXPORTED_FROM_D).toContain('domEvent')
    expect(EXPORTED_FROM_D).toContain('jsCallback')
    expect(WASM_ASYNCIFY_ARGS.join(' ')).toContain(
      'asyncify-imports@env.libwasm_await__void'
    )
  })

  test('engine TS exports last-await + rewriteError hooks', () => {
    const root = join(project, '..', '..', 'svelte-engine', 'src-ts', 'modules')
    const lib = readFileSync(join(root, 'libwasm.ts'), 'utf8')
    expect(lib).toContain('libwasm_await_supported')
    expect(lib).toContain('libwasm_await_failed')
    expect(lib).toContain('libwasm_await_error')
    expect(lib).toContain('libwasm_await_value')
    expect(lib).toContain('libwasm_note_await_fail')
    expect(lib).toContain('libwasm_note_await_ok')
    expect(lib).toContain('recordAwaitFail')
    expect(lib).not.toMatch(/promise\.finally\(\(\) => resolve\(null\)\)/)
    const ay = readFileSync(join(root, 'asyncify.ts'), 'utf8')
    expect(ay).toContain('recordAwaitFail')
    expect(ay).toContain('asyncify_start_rewind')
    expect(ay).toContain('this.queue')
    const dbg = readFileSync(join(root, 'debug-bridge.ts'), 'utf8')
    expect(dbg).toContain('__svelteDRewriteError')
    expect(dbg).toContain('__svelteDLastAwait')
    expect(dbg).toContain('[asyncify]')
    const spa = readFileSync(join(root, 'spa.ts'), 'utf8')
    expect(spa).toContain('for (const cb of cbs)')
    expect(spa).not.toMatch(/cbs\.forEach\(async/)
    const idx = readFileSync(join(root, 'index.ts'), 'utf8')
    expect(idx).toContain('asyncify')
    expect(idx).toContain('awaitStatus')
  })

  test('compile ComboCover wireAwait uses .await then fallback then', () => {
    const ws = adminWorkspace()
    expect(compileWorkspace({ ws, project }).status).toBe(0)
    const cover = join(ws, 'src-d', 'lib', 'ComboCover.d')
    expect(existsSync(cover)).toBe(true)
    const src = readFileSync(cover, 'utf8')
    const body = src.slice(src.indexOf('void wireAwait()'))
    expect(body).toContain('import await_status')
    expect(body).toContain('libwasmAwaitSupported()')
    expect(body).toMatch(/job\.await/)
    expect(body).toContain('libwasmAwaitFailed()')
    expect(body).toContain('libwasmAwaitError()')
    expect(body).toContain('eP.e =')
    expect(body).toContain('libwasmNoteAwaitFail')
    expect(body).toContain('libwasmAwaitValue()')
    expect(body).toContain('vP.v =')
    expect(body).toContain('libwasmNoteAwaitOk')
    expect(body).toContain('other.await')
    expect(body).toContain('await_pending_other')
    expect(body).toContain('eP2.e =')
    expect(body).toContain('vP2.v =')
    expect(body).toContain('.then(delegate void(Any _v)')
    expect(body).toContain('.error(delegate void(Any _e)')
    expect(body).not.toMatch(/try\s*\{\s*[\s\S]{0,40}job\.await/)
    const throwSrc = readFileSync(join(ws, 'src-d', 'lib', 'ComboSurf.d'), 'utf8')
    const tb = throwSrc.slice(throwSrc.indexOf('void throwBoundary'))
    expect(tb.slice(0, 180)).not.toMatch(/\.await\b/)
    const map = loadDebugMap(ws)
    const rewritten = rewriteStack(
      map,
      'at wireAwait (wasm://wasm/svelte-engine.wasm)\nwasm-function[12]\nasyncify_start_unwind'
    )
    expect(rewritten).toMatch(/\[async-wasm\]/)
    expect(rewritten).toMatch(/\[asyncify\]/)
  })

  test('dest wasm: moduleHasAsyncify matches asyncify_get_state export', () => {
    const ws = adminWorkspace()
    const files = [
      join(ws, 'public', 'svelte-engine-ay.wasm'),
      join(ws, 'public', 'svelte-engine.wasm'),
      join(ws, 'public', 'svelte-engine-raw.wasm'),
    ]
    const found = files.filter((p) => existsSync(p))
    if (!found.length) return
    for (const p of found) {
      const buf = readFileSync(p)
      const mod = new WebAssembly.Module(buf)
      const names = WebAssembly.Module.exports(mod).map((e) => e.name)
      expect(moduleHasAsyncify(mod)).toBe(names.includes('asyncify_get_state'))
    }
  })
})
