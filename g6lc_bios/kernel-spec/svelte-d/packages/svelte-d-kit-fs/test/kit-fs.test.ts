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

describe('kit-fs compile: groups + optional expand + unique layout.server', () => {
  test('drop + compile writes (app) IR, /shop /docs /docs/:lang, AppLayoutServer', () => {
    expect(dropWorkspace({ force: true }).status).toBe(0)
    expect(compileWorkspace(workspaceDir()).status).toBe(0)
    const ws = workspaceDir()

    const layout = readFileSync(join(ws, 'src-d', 'routes', '(app)', 'layout.d'), 'utf8')
    expect(layout).toContain('module routes._app_.layout')
    expect(layout).toContain('document().title("App")')
    expect(layout).toContain('mixin Slot!"default_"')
    expect(layout).toContain('text = "app fallback"')
    expect(layout).toContain('mixin NodeDef!"nav"')
    expect(extractDomUdas(layout)).toContain('visible')

    const shop = readFileSync(join(ws, 'src-d', 'routes', '(app)', 'shop', 'page.d'), 'utf8')
    expect(shop).toContain('module routes._app_.shop.page')
    expect(shop).toContain('import lib.ClickField')
    expect(shop).toContain('@child ClickField clickField')
    expect(shop).toContain('@visible!"clickField"')
    expect(shop).toContain('await_pending')
    expect(shop).toContain('await_then')
    expect(shop).toContain('text = "Browse"')
    expect(shop).toContain('text = "Listed"')
    expect(shop).not.toContain('mixin Spa!')

    const docs = readFileSync(
      join(ws, 'src-d', 'routes', '(app)', 'docs', '_lang_', 'page.d'),
      'utf8'
    )
    expect(docs).toContain('module routes._app_.docs._lang_.page')
    expect(docs).toContain('import lib.Panel')
    expect(docs).toContain('@child Panel panel')
    expect(docs).toContain('@visible!"panel"')
    expect(docs).toContain('document().title("Docs")')
    expect(extractDomUdas(docs)).toContain('child')

    const app = readFileSync(join(ws, 'src-d', 'app.d'), 'utf8')
    expect(app).toContain('mixin Spa!App')
    expect(app).not.toContain('@child Shop ')
    expect(app).toContain('@child ClickField clickField')
    expect(app).toContain('@child Panel panel')

    const kr = readFileSync(join(ws, 'src-d', 'kit_router.d'), 'utf8')
    expect(kr).toContain('@entering!"/"')
    expect(kr).toContain('@entering!"/board"')
    expect(kr).toContain('@entering!"/shop"')
    expect(kr).toContain('@entering!"/docs"')
    expect(kr).toContain('@entering!"/docs/:lang"')
    expect(kr).not.toMatch(/@entering!"\/\(app\)/)
    expect(kr).not.toContain('[[lang]]')

    const ls = readFileSync(
      join(ws, 'webserver', 'source', 'generated', 'routes', '(app)', 'layout_server.d'),
      'utf8'
    )
    expect(ls).toContain('module generated.routes._app_.layout_server')
    expect(ls).toContain('class AppLayoutServer')
    expect(ls).toContain('writeBody("app-layout")')
    expect(ls).not.toContain('import libwasm')

    const shopHost = readFileSync(
      join(ws, 'webserver', 'source', 'generated', 'routes', '(app)', 'shop', 'page_server.d'),
      'utf8'
    )
    expect(shopHost).toContain('class AppShopPageServer')
    expect(shopHost).toContain('writeBody("shop")')

    const happ = readFileSync(join(ws, 'webserver', 'source', 'app.d'), 'utf8')
    expect(happ).toContain('import generated.routes._app_.layout_server')
    expect(happ).toContain('import generated.routes._app_.shop.page_server')
    expect(happ).toContain('registerWebInterface(new AppLayoutServer')
    expect(happ).toContain('registerWebInterface(new AppShopPageServer')
    expect(happ).toContain('registerWebInterface(new PageServer')
    expect(happ).toContain('registerWebInterface(new BoardPageServer')

    const gen = join(ws, 'src-ts', 'modules', 'generated')
    const names = existsSync(gen) ? readdirSync(gen) : []
    expect(names.some((n) => n.includes('shop') && n.endsWith('.ts'))).toBe(true)
    expect(names.some((n) => n.includes('docs') && n.endsWith('.ts'))).toBe(true)

    const ft = JSON.parse(readFileSync(join(ws, '.svelte-d', 'fallthrough.json'), 'utf8'))
    const shopEnt = ft.entries.find((e: { kitRel: string }) =>
      e.kitRel.replace(/\\/g, '/').includes('(app)/shop/+page.svelte')
    )
    expect(shopEnt).toBeTruthy()
    expect(shopEnt.srcD).toBe('src-d/routes/(app)/shop/page.d')

    const man = JSON.parse(readFileSync(join(ws, '.svelte-d', 'manifest.json'), 'utf8'))
    expect(man.fail).toBe(0)
    expect(man.host).toBeGreaterThanOrEqual(5)
  })

  test('kit-routes CLI lists /shop, /docs, /docs/:lang and not (app)', () => {
    const r = runCli(['kit-routes', '--ws', workspaceDir()])
    expect(r.status).toBe(0)
    expect(r.stdout).toContain('/shop')
    expect(r.stdout).toContain('/docs\t')
    expect(r.stdout).toContain('/docs/:lang')
    const patterns = r.stdout
      .split(/\r?\n/)
      .map((ln) => ln.split('\t')[0])
      .filter(Boolean)
    expect(patterns.some((p) => p.includes('(app)'))).toBe(false)
    expect(patterns).toContain('/docs')
    expect(patterns).toContain('/docs/:lang')
  })
})
