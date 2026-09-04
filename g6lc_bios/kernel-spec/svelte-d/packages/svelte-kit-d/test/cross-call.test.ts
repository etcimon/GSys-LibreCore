// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { compileWorkspace, dropWorkspace, identFromRel, workspaceDir } from 'svelte-d'

describe('D ↔ TS calling convention', () => {
  test('prints Lodash callTs thunks, registers both cells, keeps optional args', () => {
    const project = join(import.meta.dir, 'fixtures', 'cross-call')
    const ws = workspaceDir()
    expect(dropWorkspace({ dest: ws, force: existsSync(ws) }).status).toBe(0)
    const hash = join(ws, '.svelte-d', 'src-hash.txt')
    if (existsSync(hash)) rmSync(hash)
    const stale = join(ws, 'src-ts', 'modules', 'generated', 'lib_Bridge_svelte2.ts')
    if (existsSync(stale)) rmSync(stale)
    expect(compileWorkspace({ ws, project }).status).toBe(0)

    const bridgeIdent = identFromRel('lib/Bridge.svelte')
    const gen = join(ws, 'src-ts', 'modules', 'generated')
    const inst = join(gen, bridgeIdent + '.ts')
    const mod = join(gen, bridgeIdent + '_mod.ts')
    expect(existsSync(inst)).toBe(true)
    expect(existsSync(mod)).toBe(true)
    const ts = readFileSync(inst, 'utf8')
    expect(ts).toContain('ensureSvelteD')
    expect(ts).toContain('registerTs')
    expect(ts).toContain('greet')
    expect(ts).toContain('loadUser')
    expect(ts).toContain('...args')
    expect(ts).toMatch(/from ['\"].*helpers\/lib\/helper/)
    const tsMod = readFileSync(mod, 'utf8')
    expect(tsMod).toContain('readyFlag')
    expect(tsMod).toContain('registerTs')

    const d = readFileSync(join(ws, 'src-d', 'lib', 'Bridge.d'), 'utf8')
    expect(d).toContain('callTs!(string)')
    expect(d).toContain(bridgeIdent + '.greet')
    expect(d).toContain('callTsPromise!(string)')
    expect(d).toContain('extern(C) export int add')
    expect(d).toContain('registerDExports_' + bridgeIdent)
    expect(d).toContain('exportDelegate("' + bridgeIdent + '.add"')
    expect(d).toContain('ARGS...')
    expect(d).toContain('int b = 0')

    const peer = readFileSync(join(ws, 'src-d', 'lib', 'Peer.d'), 'utf8')
    expect(peer).toContain('import lib.Bridge')
    expect(peer).toContain('greet("Peer")')

    const pageIdent = identFromRel('routes/+page.svelte')
    const pageTs = readFileSync(join(gen, pageIdent + '.ts'), 'utf8')
    expect(pageTs).toContain('pagePing')
    expect(pageTs).toContain('registerTs')
    const pageD = readFileSync(join(ws, 'src-d', 'routes', 'page.d'), 'utf8')
    expect(pageD).toMatch(/callTs!\(?long\)?/)
    expect(pageD).toContain(pageIdent + '.pagePing')

    const idx = readFileSync(join(ws, 'src-ts', 'modules', 'index.ts'), 'utf8')
    expect(idx).toContain(bridgeIdent)
    expect(idx).toContain(pageIdent)
    expect(existsSync(join(ws, 'src-ts', 'modules', 'helpers', 'lib', 'helper.ts'))).toBe(true)
  })
})
