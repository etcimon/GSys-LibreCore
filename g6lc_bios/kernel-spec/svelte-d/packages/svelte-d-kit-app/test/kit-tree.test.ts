// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  compileWorkspace,
  dropWorkspace,
  extractDomUdas,
  runCli,
  workspaceDir,
} from 'svelte-d'

describe('kit-app compile: nested tree + kit_router + unique hosts', () => {
  test('drop + compile writes layout/page/error/[id] IR and three host classes', () => {
    expect(dropWorkspace({ force: true }).status).toBe(0)
    expect(compileWorkspace(workspaceDir()).status).toBe(0)
    const ws = workspaceDir()

    const layout = readFileSync(join(ws, 'src-d', 'routes', 'board', 'layout.d'), 'utf8')
    expect(layout).toContain('document().title("Board")')
    expect(layout).toContain('mixin Slot!"default_"')
    expect(layout).toContain('text = "board fallback"')

    const page = readFileSync(join(ws, 'src-d', 'routes', 'board', 'page.d'), 'utf8')
    expect(page).toContain('import lib.AppShell')
    expect(page).toContain('@child AppShell appShell')
    expect(page).toContain('await_pending')
    expect(page).toContain('await_then')

    const err = readFileSync(join(ws, 'src-d', 'routes', 'board', 'error.d'), 'utf8')
    expect(err).toContain('module routes.board.error')
    expect(err).toContain('struct ')
    expect(err).toContain('@visible')
    expect(err).toContain('text = "board error"')
    expect(extractDomUdas(err)).toContain('visible')
    expect(err).not.toContain('mixin Spa!')

    const item = readFileSync(join(ws, 'src-d', 'routes', 'board', '_id_', 'page.d'), 'utf8')
    expect(item).toContain('module routes.board._id_.page')
    expect(item).toContain('import lib.Panel')
    expect(item).toContain('@child Panel panel')
    expect(item).toContain('@visible!"panel"')
    expect(item).toContain('document().title("Item")')
    expect(item).toContain('await_pending')
    expect(item).toContain('await_then')
    expect(item).toContain('await_catch')
    expect(item).toContain('text = "Loading"')
    expect(item).toContain('text = "Done"')
    expect(item).toContain('text = "Fail"')
    expect(extractDomUdas(item)).toContain('child')

    const app = readFileSync(join(ws, 'src-d', 'app.d'), 'utf8')
    expect(app).toContain('mixin Spa!App')
    expect(app).not.toContain('@child Board ')
    expect(app).not.toContain('@child Error ')
    expect(app).toContain('@child Panel panel')
    expect(app).toContain('@child AppShell appShell')

    const kr = readFileSync(join(ws, 'src-d', 'kit_router.d'), 'utf8')
    expect(kr).toContain('module svelte_engine.kit_router')
    expect(kr).toContain('@entering!"/"')
    expect(kr).toContain('@entering!"/board"')
    expect(kr).toContain('@entering!"/:slug"')
    expect(kr).toContain('@entering!"/board/:id"')
    expect(kr).not.toMatch(/@entering!"\/board\/error"/)

    const pageHost = readFileSync(
      join(ws, 'webserver', 'source', 'generated', 'routes', 'board', 'page_server.d'),
      'utf8'
    )
    expect(pageHost).toContain('class BoardPageServer')
    expect(pageHost).toContain('writeBody("board")')

    const epHost = readFileSync(
      join(ws, 'webserver', 'source', 'generated', 'routes', 'board', 'server.d'),
      'utf8'
    )
    expect(epHost).toContain('module generated.routes.board.server')
    expect(epHost).toContain('class BoardServer')
    expect(epHost).toContain('void post(')
    expect(epHost).toContain('writeBody("board-post")')
    expect(epHost).not.toContain('import libwasm')

    const happ = readFileSync(join(ws, 'webserver', 'source', 'app.d'), 'utf8')
    expect(happ).toContain('import generated.routes.page_server')
    expect(happ).toContain('import generated.routes.board.page_server')
    expect(happ).toContain('import generated.routes.board.server')
    expect(happ).toContain('registerWebInterface(new PageServer')
    expect(happ).toContain('registerWebInterface(new BoardPageServer')
    expect(happ).toContain('registerWebInterface(new BoardServer')
    expect(happ).toContain('/__svelte-d/host/')

    const gen = join(ws, 'src-ts', 'modules', 'generated')
    const names = existsSync(gen) ? readdirSync(gen) : []
    expect(names.some((n) => n.includes('board') && n.includes('id') && n.endsWith('.ts'))).toBe(
      true
    )
    const idx = readFileSync(join(ws, 'src-ts', 'modules', 'index.ts'), 'utf8')
    expect(idx).toMatch(/board/)

    const ft = JSON.parse(readFileSync(join(ws, '.svelte-d', 'fallthrough.json'), 'utf8'))
    const idEnt = ft.entries.find((e: { kitRel: string }) =>
      e.kitRel.replace(/\\/g, '/').includes('board/[id]/+page.svelte')
    )
    expect(idEnt).toBeTruthy()
    expect(idEnt.srcD).toBe('src-d/routes/board/_id_/page.d')

    const man = JSON.parse(readFileSync(join(ws, '.svelte-d', 'manifest.json'), 'utf8'))
    expect(man.fail).toBe(0)
    expect(man.host).toBeGreaterThanOrEqual(3)
    expect(man.dom).toBeGreaterThan(0)
  })

  test('kit-routes CLI lists /, /board, /:slug, /board/:id', () => {
    const r = runCli(['kit-routes', '--ws', workspaceDir()])
    expect(r.status).toBe(0)
    expect(r.stdout).toContain('/\t')
    expect(r.stdout).toContain('/board')
    expect(r.stdout).toContain('/:slug')
    expect(r.stdout).toContain('/board/:id')
  })
})
