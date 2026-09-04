// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  compileWorkspace,
  dropWorkspace,
  runCli,
  findRiscvDev,
  workspaceDir,
  templateDir,
  mapKitPath,
  loadLodashCatalog,
  libwasmLodashPath,
  lodashCore,
  lodashMethodsUsed,
} from 'svelte-d'

const required = [
  'compact',
  'uniq',
  'map',
  'filter',
  'find',
  'join',
  'size',
  'take',
  'defaultTo',
  'attempt',
  'invoke',
  'get',
  'toLower',
  'trim',
  'execute',
]

describe('libwasm lodash catalog', () => {
  test('lodash.d is next to riscv-dev (riscv-compilers/libwasm)', () => {
    expect(existsSync(libwasmLodashPath())).toBe(true)
  })

  test('catalog contains struct Lodash methods used by lang=d fixtures', () => {
    const cat = loadLodashCatalog()
    expect(cat.length).toBeGreaterThan(100)
    for (const m of required) {
      expect(cat).toContain(m)
    }
    expect(cat).toContain('execute')
    expect(cat).not.toContain('initialize')
  })

  test('D CLI lodash lists the same catalog', () => {
    const r = runCli(['lodash'])
    expect(r.status).toBe(0)
    const lines = r.stdout.trim().split(/\r?\n/)
    expect(lines[0]).toContain('libwasm.lodash')
    const names = lines.slice(1)
    const cat = loadLodashCatalog()
    expect(names).toEqual(cat)
  })
})

describe('lang=d Lodash compiles into svelte-engine-ws', () => {
  test('engine fixture maps to src-d/lib/LodashDemo.d', () => {
    const ft = mapKitPath('src/lib/LodashDemo.svelte')
    expect(ft.srcSvelte).toBe('src-svelte/lib/LodashDemo.svelte')
    expect(ft.srcD).toBe('src-d/lib/LodashDemo.d')
    expect(ft.runtime).toContain('libwasm')
    expect(existsSync(join(templateDir(), 'src-svelte', 'lib', 'LodashDemo.svelte'))).toBe(true)
  })

  test('drop + compile prints libwasm Lodash IR into the ws', () => {
    const ws = workspaceDir()
    const d = dropWorkspace({ force: true })
    expect(d.status).toBe(0)
    const c = compileWorkspace(ws)
    expect(c.status).toBe(0)
    expect(c.stdout).toContain('LodashDemo')
    expect(c.stdout).toMatch(/lodash=1/)

    const dest = join(ws, 'src-d', 'lib', 'LodashDemo.d')
    expect(existsSync(dest)).toBe(true)
    const printed = readFileSync(dest, 'utf8')
    expect(printed).toContain('module lib.LodashDemo')
    expect(printed).toContain('import libwasm')
    expect(printed).toContain('Lodash(')
    expect(printed).toContain('execute!string')
    expect(printed).toContain('execute!long')
    expect(printed).toContain('execute!JSON')
    expect(printed).toContain('VarType.handle')
    expect(printed).toContain('VarType.string_')
    expect(printed).toContain('Eval(')

    const cat = loadLodashCatalog()
    const used = lodashMethodsUsed(printed, cat)
    for (const m of required) {
      expect(used).toContain(m)
    }
    expect(used).toContain('Lodash')
    for (const m of used) {
      if (m === 'Lodash') continue
      expect(cat).toContain(m)
    }

    const ir = join(ws, '.svelte-d', 'ir', 'lodash-src-d_lib_LodashDemo.d.json')
    expect(existsSync(ir)).toBe(true)
    const node = JSON.parse(readFileSync(ir, 'utf8'))
    expect(node.kind).toBe('LodashChain')
    expect(node.ir).toBe('libwasm-lodash')
    expect(node.cell).toBe('wasm')
    expect(node.dest).toBe('src-d/lib/LodashDemo.d')
    expect(node.methods).toContain('map')
    expect(node.methods).toContain('execute')

    const man = JSON.parse(readFileSync(join(ws, '.svelte-d', 'manifest.json'), 'utf8'))
    expect(man.lodash).toBeGreaterThan(0)
    expect(man.pglite).toBe('passthrough')

    // template passthrough untouched
    expect(readFileSync(join(ws, 'src-d', 'pglite.d'), 'utf8')).toContain('window.pglite')
    expect(existsSync(join(ws, 'src-d', 'app.d'))).toBe(true)
  })

  test('compiled LodashDemo still parses as dual-script', () => {
    const r = runCli([
      'parse',
      join(templateDir(), 'src-svelte', 'lib', 'LodashDemo.svelte'),
    ])
    expect(r.status).toBe(0)
    expect(r.stdout).toMatch(/lang=d/)
    expect(r.stdout).toMatch(/lang=ts/)
  })

  test('lodashCore export matches the fixture set', () => {
    for (const m of required) {
      expect(lodashCore as readonly string[]).toContain(m)
    }
    void findRiscvDev
  })
})
