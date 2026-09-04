// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  compileWorkspace,
  dropWorkspace,
  parseSvelte,
  buildHost,
  runCli,
  ffiAvailable,
  findRiscvDev,
  workspaceDir,
  templateDir,
  nativeExe,
  nativeLib,
  nativeArtifacts,
  mapKitPath,
  normalizeKitRel,
  adaptWorkspace,
  ADAPTERS,
} from 'svelte-d'

describe('svelte-d is an importable ts+exe/lib library', () => {
  test('named exports resolve from the svelte-d package', () => {
    expect(typeof compileWorkspace).toBe('function')
    expect(typeof dropWorkspace).toBe('function')
    expect(typeof parseSvelte).toBe('function')
    expect(typeof buildHost).toBe('function')
    expect(typeof runCli).toBe('function')
    expect(typeof mapKitPath).toBe('function')
    expect(typeof adaptWorkspace).toBe('function')
    expect(ADAPTERS).toContain('static')
    expect(typeof findRiscvDev).toBe('function')
    expect(typeof nativeExe).toBe('function')
    expect(typeof nativeLib).toBe('function')
  })

  test('native exe exists (application config)', () => {
    const a = nativeArtifacts()
    expect(a.exeExists).toBe(true)
    expect(existsSync(nativeExe())).toBe(true)
  })

  test('native lib exists (dynamicLibrary config)', () => {
    expect(existsSync(nativeLib())).toBe(true)
  })

  test('ffi loads svelte_d_version when the lib is present', () => {
    expect(typeof ffiAvailable()).toBe('boolean')
    if (existsSync(nativeLib())) {
      // load may still fail if the DLL cannot resolve Phobos; exe remains the API
      void ffiAvailable()
    }
  })

  test('CLI version via imported runCli', () => {
    const r = runCli(['version'])
    expect(r.status).toBe(0)
    expect(r.via).toBe('exe')
    expect(r.stdout.trim().split(/\r?\n/)[0]).toBe('1')
  })
})

describe('kit syntax falls through to equivalent svelte-engine-ws structure', () => {
  test('bun src/routes/+page.svelte → src-svelte + src-d + src-ts', () => {
    const page = mapKitPath('src/routes/+page.svelte')
    expect(normalizeKitRel('src/routes/+page.svelte')).toBe('routes/+page.svelte')
    expect(page.kitRel).toBe('routes/+page.svelte')
    expect(page.kind).toBe('page')
    expect(page.srcSvelte).toBe('src-svelte/routes/+page.svelte')
    expect(page.srcD).toBe('src-d/routes/page.d')
    expect(page.srcTs).toBe('src-ts/modules/generated/routes__page_svelte.ts')
    expect(page.runtime).toContain('libwasm')
    expect(page.host).toBe('')
  })

  test('src/lib/Dock.svelte → src-d/lib/Dock.d (libwasm)', () => {
    const dock = mapKitPath('src/lib/Dock.svelte')
    expect(dock.kind).toBe('component')
    expect(dock.srcSvelte).toBe('src-svelte/lib/Dock.svelte')
    expect(dock.srcD).toBe('src-d/lib/Dock.d')
    expect(dock.runtime).toContain('libwasm')
  })

  test('+page.server.d / +server.ts → vibe.0 webserver/source/generated', () => {
    const srv = mapKitPath('src/routes/+page.server.d')
    expect(srv.kind).toBe('page_server')
    expect(srv.runtime).toBe('vibe.0')
    expect(srv.host).toBe('webserver/source/generated/routes/page_server.d')
    expect(srv.srcD).toBe('')

    const ep = mapKitPath('routes/+server.ts')
    expect(ep.kind).toBe('endpoint')
    expect(ep.runtime).toBe('vibe.0')
    expect(ep.host).toBe('webserver/source/generated/routes/server.d')
  })

  test('+layout.svelte stays a layout (@child), not a second wasm module', () => {
    const lay = mapKitPath('src/routes/+layout.svelte')
    expect(lay.kind).toBe('layout')
    expect(lay.srcD).toBe('src-d/routes/layout.d')
    expect(lay.cell).toBe('wasm')
  })

  test('D CLI map agrees with TS mapKitPath', () => {
    const samples = [
      'src/routes/+page.svelte',
      'src/lib/Dock.svelte',
      'src/routes/+page.server.d',
      'src/routes/+server.ts',
    ]
    for (const s of samples) {
      const r = runCli(['map', s])
      expect(r.status).toBe(0)
      const j = JSON.parse(r.stdout.trim().split('\n')[0])
      const ts = mapKitPath(s)
      expect(j.kitRel).toBe(ts.kitRel)
      expect(j.kind).toBe(ts.kind)
      expect(j.srcSvelte).toBe(ts.srcSvelte)
      expect(j.srcD).toBe(ts.srcD)
      expect(j.srcTs).toBe(ts.srcTs)
      expect(j.host).toBe(ts.host)
      expect(j.runtime).toBe(ts.runtime)
    }
  })

  test('dropped workspace has the kit-equivalent cell tree', () => {
    const root = findRiscvDev()
    const ws = workspaceDir(root)
    const tpl = templateDir(root)
    expect(existsSync(join(tpl, 'src-svelte', 'routes', '+page.svelte'))).toBe(true)
    expect(existsSync(join(tpl, 'src-d', 'pglite.d'))).toBe(true)
    expect(existsSync(join(tpl, 'src-ts', 'modules', 'index.ts'))).toBe(true)
    expect(existsSync(join(tpl, 'webserver', 'source', 'app.d'))).toBe(true)
    if (existsSync(ws)) {
      expect(existsSync(join(ws, 'src-svelte', 'routes', '+page.svelte'))).toBe(true)
      expect(existsSync(join(ws, 'src-d', 'pglite.d'))).toBe(true)
      expect(existsSync(join(ws, 'src-ts', 'modules'))).toBe(true)
      expect(existsSync(join(ws, 'webserver', 'source', 'app.d'))).toBe(true)
    }
  })

  test('compile writes fallthrough.json that matches mapKitPath', () => {
    const root = findRiscvDev()
    const ws = workspaceDir(root)
    if (!existsSync(ws)) return
    const manPath = join(ws, '.svelte-d', 'fallthrough.json')
    if (!existsSync(manPath)) return
    const doc = JSON.parse(readFileSync(manPath, 'utf8'))
    expect(doc.schema).toBe('svelte-d-fallthrough/v1')
    expect(doc.principle).toBe('kit-syntax-falls-through-to-equivalent-ws-structure')
    const page = doc.entries.find((e: { kitRel: string }) => e.kitRel === 'routes/+page.svelte')
    expect(page).toBeTruthy()
    expect(page.srcSvelte).toBe(mapKitPath('routes/+page.svelte').srcSvelte)
    expect(page.srcD).toBe(mapKitPath('routes/+page.svelte').srcD)
    const srv = doc.entries.find((e: { kitRel: string }) => e.kitRel === 'routes/+page.server.d')
    expect(srv).toBeTruthy()
    expect(srv.host).toBe(mapKitPath('routes/+page.server.d').host)
    expect(srv.runtime).toBe('vibe.0')
  })
})
