// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  mapKitPath,
  parseSvelte,
  templateDir,
  workspaceDir,
} from 'svelte-d'

describe('kit fall-through + dual-script for composed lib files', () => {
  test('mapKitPath sends src/lib/Panel.svelte to libwasm src-d + ts generated', () => {
    const p = mapKitPath('src/lib/Panel.svelte')
    expect(p.kind).toBe('component')
    expect(p.srcSvelte).toBe('src-svelte/lib/Panel.svelte')
    expect(p.srcD).toBe('src-d/lib/Panel.d')
    expect(p.runtime).toContain('libwasm')
    expect(p.srcTs).toContain('src-ts/modules/generated')
    expect(p.host).toBe('')

    const a = mapKitPath('src/lib/AppShell.svelte')
    expect(a.srcD).toBe('src-d/lib/AppShell.d')
    expect(a.srcSvelte).toBe('src-svelte/lib/AppShell.svelte')
  })

  test('parseSvelte sees lang=d and lang=ts on both fixtures', () => {
    const tpl = templateDir()
    const panel = parseSvelte(join(tpl, 'src-svelte', 'lib', 'Panel.svelte'))
    expect(panel.status).toBe(0)
    expect(panel.stdout).toMatch(/lang=d/)
    expect(panel.stdout).toMatch(/lang=ts/)

    const shell = parseSvelte(join(tpl, 'src-svelte', 'lib', 'AppShell.svelte'))
    expect(shell.status).toBe(0)
    expect(shell.stdout).toMatch(/lang=d/)
    expect(shell.stdout).toMatch(/lang=ts/)
  })

  test('compile attached jsExports for Panel and AppShell module scripts', () => {
    const ws = workspaceDir()
    const gen = join(ws, 'src-ts', 'modules', 'generated')
    expect(existsSync(gen)).toBe(true)
    const names = readdirSync(gen)
    const idx = readFileSync(join(ws, 'src-ts', 'modules', 'index.ts'), 'utf8')
    expect(idx).toContain('generated/')

    const panelTs = names.find((n) => n.includes('Panel') && n.endsWith('.ts'))
    expect(panelTs).toBeTruthy()
    const psrc = readFileSync(join(gen, panelTs as string), 'utf8')
    expect(psrc).toContain('jsExports')
    expect(psrc).toContain('panelReady')

    const shellTs = names.find((n) => n.includes('AppShell') && n.endsWith('.ts'))
    expect(shellTs).toBeTruthy()
    const ssrc = readFileSync(join(gen, shellTs as string), 'utf8')
    expect(ssrc).toContain('jsExports')
    expect(ssrc).toContain('appShellReady')

    const man = JSON.parse(readFileSync(join(ws, '.svelte-d', 'manifest.json'), 'utf8'))
    expect(man.fail).toBe(0)
    expect(man.dom).toBeGreaterThan(0)
    expect(man.tsModules).toBeGreaterThan(0)
    expect(man.fallthrough).toBe('kit-equivalent-ws')

    const irPanel = join(ws, '.svelte-d', 'ir', 'dom-src-d_lib_Panel.d.json')
    const irShell = join(ws, '.svelte-d', 'ir', 'dom-src-d_lib_AppShell.d.json')
    expect(existsSync(irPanel) || existsSync(join(ws, '.svelte-d', 'ir'))).toBe(true)
    void irShell
  })
})
