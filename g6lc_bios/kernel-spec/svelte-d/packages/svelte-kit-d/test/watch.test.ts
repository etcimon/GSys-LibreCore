// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { join } from 'node:path'
import { existsSync, mkdirSync, mkdtempSync, statSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { compileWorkspace, dropWorkspace, workspaceDir } from 'svelte-d'
import { cellForSrc, readWriteStats, wasmDirty } from '../src/pipeline.ts'

describe('T10 incremental watch: reprint-skip + opposite-cell', () => {
  test('cellForSrc sends kit host files to the host cell only', () => {
    expect(cellForSrc('src-svelte/routes/admin/+page.svelte')).toBe('wasm')
    expect(cellForSrc('src-svelte/lib/ComboCss.svelte')).toBe('wasm')
    expect(cellForSrc('src-svelte/routes/admin/+page.server.d')).toBe('host')
    expect(cellForSrc('src-svelte/routes/board/+server.d')).toBe('host')
    expect(cellForSrc('src-svelte/hooks.server.d')).toBe('host')
    expect(cellForSrc('webserver/source/generated/kit/app_paths.d')).toBe('host')
  })

  test('second compile skips dest writes and keeps ClickField.d mtime', () => {
    const ws = workspaceDir()
    if (!existsSync(join(ws, 'src-svelte'))) {
      expect(dropWorkspace({ force: true }).status).toBe(0)
    }
    expect(compileWorkspace(ws).status).toBe(0)
    const dest = join(ws, 'src-d', 'lib', 'ClickField.d')
    expect(existsSync(dest)).toBe(true)
    const t0 = statSync(dest).mtimeMs
    const first = readWriteStats(ws)
    expect(first.wrote + first.skipped).toBeGreaterThan(0)

    expect(compileWorkspace(ws).status).toBe(0)
    const t1 = statSync(dest).mtimeMs
    const second = readWriteStats(ws)
    expect(t1).toBe(t0)
    expect(second.skipped).toBeGreaterThan(0)
    expect(second.hashSkip).toBeGreaterThan(0)
    expect(second.wasm).toBe(0)
    // hash-skip compile must not mark the wasm cell dirty.

    const only = compileWorkspace({
      ws,
      only: ['lib/ClickField.svelte'],
    })
    expect(only.status).toBe(0)
    const third = readWriteStats(ws)
    expect(third.hashSkip + third.parsed).toBeGreaterThan(0)
    expect(existsSync(join(ws, '.svelte-d', 'src-hash.txt'))).toBe(true)
  }, 60_000)

  test('wasmDirty ignores src-svelte touch; write.json wasm>0 forces dirty', () => {
    const ws = mkdtempSync(join(tmpdir(), 'svelte-d-wasm-dirty-'))
    mkdirSync(join(ws, 'public'), { recursive: true })
    mkdirSync(join(ws, '.svelte-d'), { recursive: true })
    mkdirSync(join(ws, 'src-d'), { recursive: true })
    mkdirSync(join(ws, 'src-svelte', 'lib'), { recursive: true })
    writeFileSync(join(ws, 'dub.sdl'), 'name "t"\n')
    writeFileSync(join(ws, 'src-d', 'app.d'), 'module app;\n')
    const svelte = join(ws, 'src-svelte', 'lib', 'ClickField.svelte')
    writeFileSync(svelte, '<div></div>\n')
    const art = join(ws, 'public', 'svelte-engine.wasm')
    writeFileSync(art, 'stub-wasm')
    writeFileSync(
      join(ws, '.svelte-d', 'wasm.json'),
      '{"schema":"svelte-d-wasm/v1","ok":true,"skipped":true}\n'
    )
    writeFileSync(
      join(ws, '.svelte-d', 'write.json'),
      '{"schema":"svelte-d-write/v1","wrote":0,"skipped":1,"wasm":0,"host":0,"parsed":0,"hashSkip":1}\n'
    )
    const now = new Date()
    utimesSync(art, now, now)
    expect(wasmDirty(ws, 'if-stale')).toBe(false)

    const later = new Date(Date.now() + 60_000)
    utimesSync(svelte, later, later)
    expect(wasmDirty(ws, 'if-stale')).toBe(false)

    writeFileSync(
      join(ws, '.svelte-d', 'write.json'),
      '{"schema":"svelte-d-write/v1","wrote":1,"skipped":0,"wasm":1,"host":0,"parsed":1,"hashSkip":0}\n'
    )
    expect(wasmDirty(ws, 'if-stale')).toBe(true)
    expect(wasmDirty(ws, 'never')).toBe(false)
  })
})
