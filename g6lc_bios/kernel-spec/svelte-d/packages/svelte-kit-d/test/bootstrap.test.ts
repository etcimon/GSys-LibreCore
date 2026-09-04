// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  accommodateFeatures,
  requiredSurfaces,
  missingSurfaces,
  verifyBootstrap,
  compileWorkspace,
  runCli,
  findRiscvDev,
  workspaceDir,
  templateDir,
} from 'svelte-d'

describe('kit features are accommodated in svelte-engine / libwasm / vibe.0', () => {
  test('named bootstrap exports resolve from svelte-d', () => {
    expect(accommodateFeatures.length).toBeGreaterThan(0)
    expect(requiredSurfaces.length).toBeGreaterThan(0)
    expect(typeof verifyBootstrap).toBe('function')
  })

  test('every accommodation lands in the engine or a titled runtime seam', () => {
    for (const a of accommodateFeatures) {
      expect(a.land).toMatch(/svelte-engine|libwasm|vibe\.0/)
      expect(a.runtime).not.toBe('svelte-d')
      expect(a.ws.length).toBeGreaterThan(0)
    }
    const neu = accommodateFeatures.find((a) => a.feature === 'new kit syntax')
    expect(neu?.runtime).toBe('engine-first')
    expect(neu?.ws).toBe('svelte-engine-ws')
  })

  test('client kit features land in svelte-engine + libwasm', () => {
    const d = accommodateFeatures.find((a) => a.feature === 'script lang=d')
    expect(d?.land).toContain('svelte-engine')
    expect(d?.runtime).toBe('libwasm')
    const ts = accommodateFeatures.find((a) => a.feature.startsWith('script lang=ts'))
    expect(ts?.land).toContain('svelte-engine')
    expect(ts?.runtime).toBe('libwasm')
  })

  test('server kit features land in svelte-engine/webserver + vibe.0', () => {
    const srv = accommodateFeatures.find((a) => a.feature.includes('+page.server'))
    expect(srv?.land).toContain('webserver')
    expect(srv?.runtime).toBe('vibe.0')
  })
})

describe('svelte-engine is the compile-time svelte-engine-ws bootstrap', () => {
  test('template presents every required D-IR surface', () => {
    const tpl = templateDir()
    expect(missingSurfaces(tpl)).toEqual([])
    for (const s of requiredSurfaces) {
      expect(existsSync(join(tpl, s.path))).toBe(true)
    }
  })

  test('D CLI bootstrap agrees with TS accommodateFeatures', () => {
    const r = runCli(['bootstrap', '--ws', templateDir()])
    expect(r.status).toBe(0)
    const doc = JSON.parse(r.stdout.trim().split('\n').filter((l) => l.startsWith('{'))[0])
    expect(doc.schema).toBe('svelte-d-bootstrap/v1')
    expect(doc.principle).toBe('kit-features-accommodated-by-engine-libwasm-vibe0')
    expect(doc.integratedAt).toBe('compile-time')
    expect(doc.irFormat).toBe('libwasm-d+vibe.0-d')
    const names = (doc.accommodate as { feature: string }[]).map((a) => a.feature)
    expect(names).toEqual(accommodateFeatures.map((a) => a.feature))
    const lands = (doc.accommodate as { land: string }[]).map((a) => a.land)
    expect(lands).toEqual(accommodateFeatures.map((a) => a.land))
  })

  test('compile integrates the current engine into the ws', () => {
    const root = findRiscvDev()
    const ws = workspaceDir(root)
    const c = compileWorkspace(ws)
    expect(c.status).toBe(0)
    const v = verifyBootstrap(ws)
    expect(v.ok).toBe(true)
    expect(v.missing).toEqual([])
    expect(v.document).toBeTruthy()
    expect(v.document?.schema).toBe('svelte-d-bootstrap/v1')
    expect(v.document?.integratedAt).toBe('compile-time')
    expect(v.document?.template.replace(/\\/g, '/')).toMatch(
      /svelte-engine|templates\/engine/
    )
    expect(v.document?.workspace).toContain('svelte-engine-ws')
    const boot = JSON.parse(readFileSync(join(ws, '.svelte-d', 'bootstrap.json'), 'utf8'))
    expect(boot.irFormat).toBe('libwasm-d+vibe.0-d')
    for (const s of boot.surfaces) {
      expect(s.present).toBe(true)
    }
    const hashes = boot.templateFiles as { path: string; hash: string }[]
    expect(hashes.some((h) => h.path === 'src-d/app.d' && h.hash.length === 16)).toBe(true)
    expect(existsSync(join(ws, 'src-d', 'app.d'))).toBe(true)
    expect(existsSync(join(ws, 'webserver', 'source', 'app.d'))).toBe(true)
    expect(readFileSync(join(ws, 'src-d', 'pglite.d'), 'utf8')).toBe(
      readFileSync(join(templateDir(), 'src-d', 'pglite.d'), 'utf8')
    )
  })
})
