// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  compileWorkspace,
  dropWorkspace,
  extractDomUdas,
  kitToPattern,
  mapKitPath,
  parseSvelte,
  templateDir,
  workspaceDir,
} from 'svelte-d'

describe('kit board route: layout + page + host (import svelte-d)', () => {
  test('mapKitPath / kitToPattern send board files to wasm + host cells', () => {
    const page = mapKitPath('src/routes/board/+page.svelte')
    expect(page.kind).toBe('page')
    expect(page.srcSvelte).toBe('src-svelte/routes/board/+page.svelte')
    expect(page.srcD).toBe('src-d/routes/board/page.d')
    expect(page.runtime).toContain('libwasm')
    expect(kitToPattern('src/routes/board/+page.svelte')).toBe('/board')

    const layout = mapKitPath('src/routes/board/+layout.svelte')
    expect(layout.kind).toBe('layout')
    expect(layout.srcD).toBe('src-d/routes/board/layout.d')

    const host = mapKitPath('src/routes/board/+page.server.d')
    expect(host.kind).toBe('page_server')
    expect(host.cell).toBe('host')
    expect(host.runtime).toContain('vibe.0')
    expect(host.host).toBe('webserver/source/generated/routes/board/page_server.d')
    expect(host.srcD).toBe('')
  })

  test('parse dual-script layout + page; host file is not scanned as svelte', () => {
    const tpl = templateDir()
    const lay = parseSvelte(join(tpl, 'src-svelte', 'routes', 'board', '+layout.svelte'))
    expect(lay.status).toBe(0)
    expect(lay.stdout).toMatch(/lang=d/)
    expect(lay.stdout).toMatch(/lang=ts/)
    const pg = parseSvelte(join(tpl, 'src-svelte', 'routes', 'board', '+page.svelte'))
    expect(pg.status).toBe(0)
    expect(pg.stdout).toMatch(/lang=d/)
    expect(pg.stdout).toMatch(/AppShell|lang=ts/)
  })

  test('compile writes layout/page IR, unique BoardPageServer, does not hang route on Spa!App', () => {
    expect(dropWorkspace({ force: true }).status).toBe(0)
    expect(compileWorkspace(workspaceDir()).status).toBe(0)
    const ws = workspaceDir()

    const layout = readFileSync(join(ws, 'src-d', 'routes', 'board', 'layout.d'), 'utf8')
    expect(layout).toContain('module ')
    expect(layout).toContain('struct ')
    expect(layout).toContain('document().title("Board")')
    expect(layout).toContain('@visible')
    expect(layout).toContain('mixin Slot!"default_"')
    expect(layout).toContain('text = "board fallback"')
    expect(layout).toContain('mixin NodeDef!"nav"')
    expect(extractDomUdas(layout)).toContain('visible')

    const page = readFileSync(join(ws, 'src-d', 'routes', 'board', 'page.d'), 'utf8')
    expect(page).toContain('import lib.AppShell')
    expect(page).toContain('@child AppShell appShell')
    expect(page).toContain('@visible!"appShell"')
    expect(page).toContain('await_pending')
    expect(page).toContain('await_then')
    expect(page).toContain('text = "Wait"')
    expect(page).toContain('text = "Ready"')
    expect(page).not.toContain('mixin Spa!')
    expect(extractDomUdas(page)).toContain('child')

    const app = readFileSync(join(ws, 'src-d', 'app.d'), 'utf8')
    expect(app).toContain('mixin Spa!App')
    expect(app).not.toContain('@child Board ')
    expect(app).toContain('@child AppShell appShell')

    const host = join(ws, 'webserver', 'source', 'generated', 'routes', 'board', 'page_server.d')
    expect(existsSync(host)).toBe(true)
    const hsrc = readFileSync(host, 'utf8')
    expect(hsrc).toContain('module generated.routes.board.page_server')
    expect(hsrc).toContain('class BoardPageServer')
    expect(hsrc).toContain('void get(')
    expect(hsrc).toContain('writeBody("board")')
    expect(hsrc).not.toContain('import libwasm')

    const happ = readFileSync(join(ws, 'webserver', 'source', 'app.d'), 'utf8')
    expect(happ).toContain('import generated.routes.page_server')
    expect(happ).toContain('import generated.routes.board.page_server')
    expect(happ).toContain('registerWebInterface(new PageServer')
    expect(happ).toContain('registerWebInterface(new BoardPageServer')
    expect(happ).toContain('/__svelte-d/host/')

    const gen = join(ws, 'src-ts', 'modules', 'generated')
    const names = existsSync(gen) ? readdirSync(gen) : []
    expect(names.some((n) => n.includes('board') && n.endsWith('.ts'))).toBe(true)
    const idx = readFileSync(join(ws, 'src-ts', 'modules', 'index.ts'), 'utf8')
    expect(idx).toMatch(/boardLayoutReady|board_layout|board/)

    const ft = JSON.parse(readFileSync(join(ws, '.svelte-d', 'fallthrough.json'), 'utf8'))
    const pageEnt = ft.entries.find((e: { kitRel: string }) =>
      e.kitRel.replace(/\\/g, '/').includes('board/+page.svelte')
    )
    expect(pageEnt).toBeTruthy()
    expect(pageEnt.srcD).toBe('src-d/routes/board/page.d')
  })
})
