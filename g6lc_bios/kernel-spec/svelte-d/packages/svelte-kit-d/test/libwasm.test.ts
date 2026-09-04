// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  compileWorkspace,
  dropWorkspace,
  runCli,
  workspaceDir,
  templateDir,
  mapKitPath,
  kitToPattern,
  loadBindingsCatalog,
  coreBindings,
  coreTypes,
  routerNames,
} from 'svelte-d'

describe('libwasm bindings / types / router catalogs', () => {
  test('bindings catalog includes Document, Window, Console', () => {
    const cat = loadBindingsCatalog()
    expect(cat.length).toBeGreaterThan(100)
    for (const b of coreBindings) expect(cat).toContain(b)
  })

  test('kit [slug] falls through to :slug URLRouter pattern', () => {
    expect(kitToPattern('src/routes/+page.svelte')).toBe('/')
    expect(kitToPattern('src/routes/[slug]/+page.svelte')).toBe('/:slug')
    expect(mapKitPath('src/routes/[slug]/+page.svelte').srcD).toBe('src-d/routes/_slug_/page.d')
    expect(mapKitPath('src/routes/docs/[[lang]]/+page.svelte').srcD).toBe(
      'src-d/routes/docs/_lang_/page.d'
    )
    expect(mapKitPath('src/routes/files/[...path]/+page.svelte').srcD).toBe(
      'src-d/routes/files/_path_/page.d'
    )
    expect(kitToPattern('src/routes/(app)/blog/[id]/+page.svelte')).toBe('/blog/:id')
    expect(kitToPattern('src/lib/Dock.svelte')).toBe('')
    const r = runCli(['map', 'src/routes/[slug]/+page.svelte'])
    expect(r.status).toBe(0)
    const j = JSON.parse(r.stdout.trim().split('\n')[0])
    expect(j.srcD).toBe('src-d/routes/_slug_/page.d')
    expect(j.srcD).toBe(mapKitPath('src/routes/[slug]/+page.svelte').srcD)
  })
})

describe('lang=d bindings, types, router compile into svelte-engine-ws', () => {
  test('engine fixtures exist', () => {
    const tpl = templateDir()
    expect(existsSync(join(tpl, 'src-svelte', 'lib', 'BindingsDemo.svelte'))).toBe(true)
    expect(existsSync(join(tpl, 'src-svelte', 'lib', 'TypesDemo.svelte'))).toBe(true)
    expect(existsSync(join(tpl, 'src-svelte', 'routes', '[slug]', '+page.svelte'))).toBe(true)
  })

  test('drop + compile prints bindings, types, kit_router', () => {
    const ws = workspaceDir()
    expect(dropWorkspace({ force: true }).status).toBe(0)
    const c = compileWorkspace(ws)
    expect(c.status).toBe(0)
    expect(c.stdout).toMatch(/bind=/)
    expect(c.stdout).toMatch(/router=/)

    const bind = readFileSync(join(ws, 'src-d', 'lib', 'BindingsDemo.d'), 'utf8')
    expect(bind).toContain('module lib.BindingsDemo')
    expect(bind).toContain('document()')
    expect(bind).toContain('window()')
    expect(bind).toContain('location()')
    expect(bind).not.toContain('location().front')
    expect(bind).toContain('console.info')
    expect(bind).toContain('Handle')

    const types = readFileSync(join(ws, 'src-d', 'lib', 'TypesDemo.d'), 'utf8')
    expect(types).toContain('module lib.TypesDemo')
    expect(types).toContain('Eval(')
    expect(types).toContain('JSON(')
    expect(types).toContain('VarType.handle')
    expect(types).toContain('JsHandle')
    for (const t of ['Handle', 'Eval', 'JSON', 'VarType'] as const) {
      expect(coreTypes as readonly string[]).toContain(t)
    }

    const slug = readFileSync(join(ws, 'src-d', 'routes', '_slug_', 'page.d'), 'utf8')
    expect(slug).toContain('module routes._slug_.page')
    expect(slug).toContain('@entering!')
    expect(slug).toContain('RouterEvent')
    expect(slug).toContain('navigateTo')
    expect(slug).toContain('setBasePath')
    for (const n of ['navigateTo', 'RouterEvent', 'entering'] as const) {
      expect(routerNames as readonly string[]).toContain(n)
    }

    const kr = readFileSync(join(ws, 'src-d', 'kit_router.d'), 'utf8')
    expect(kr).toContain('module svelte_engine.kit_router')
    expect(kr).toContain('@entering!"/"')
    expect(kr).toContain('@entering!"/:slug"')
    expect(kr).toContain('RouterEvent')

    const host = join(ws, 'webserver', 'source', 'generated', 'routes', 'page_server.d')
    expect(existsSync(host)).toBe(true)

    const man = JSON.parse(readFileSync(join(ws, '.svelte-d', 'manifest.json'), 'utf8'))
    expect(man.bindings).toBeGreaterThan(0)
    expect(man.router).toBeGreaterThan(0)
    expect(man.host).toBeGreaterThan(0)

    const irRoute = join(ws, '.svelte-d', 'ir', 'kit_router.json')
    expect(existsSync(irRoute)).toBe(true)
    expect(JSON.parse(readFileSync(irRoute, 'utf8')).ir).toBe('libwasm-router')
  })

  test('D CLI kit-routes lists / and /:slug', () => {
    const r = runCli(['kit-routes', '--ws', workspaceDir()])
    expect(r.status).toBe(0)
    expect(r.stdout).toContain('/\t')
    expect(r.stdout).toContain('/:slug')
  })
})
