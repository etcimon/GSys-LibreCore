// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { compileWorkspace } from 'svelte-d'
import { adminWorkspace } from '../src/ws.ts'

const project = dirname(dirname(fileURLToPath(import.meta.url)))

describe('T5 kit remount + slot projection', () => {
  test('admin pages remount on the layout; layouts stay; one Spa!App', () => {
    const ws = adminWorkspace()
    const appPath = join(ws, 'src-d', 'app.d')
    if (
      !existsSync(join(ws, 'src-d', 'kit_router.d')) ||
      !existsSync(appPath) ||
      !readFileSync(appPath, 'utf8').includes('@child KitRoutes kitRoutes')
    ) {
      expect(compileWorkspace({ ws, project }).status).toBe(0)
    }
    const kr = readFileSync(join(ws, 'src-d', 'kit_router.d'), 'utf8')
    expect(kr).toContain('struct KitRoutes')
    expect(kr).toContain('@entering!"/admin"')
    expect(kr).toMatch(/@entering!"\/admin"[\s\S]*setVisible!"adminPage"\(adminLayout, true\)/)
    expect(kr).toMatch(/@entering!"\/admin\/users"[\s\S]*setVisible!"adminUsersPage"\(adminLayout, true\)/)
    expect(kr).toMatch(/@entering!"\/admin\/users\/:id"[\s\S]*setVisible!"adminUsersIdPage"\(adminLayout, true\)/)
    expect(kr).toMatch(/@entering!"\/admin"[\s\S]*setVisible!"adminUsersPage"\(adminLayout, false\)/)
    expect(kr).toContain('setVisible!"slot_default"(adminLayout, false)')
    expect(kr).toContain('@child routes.admin.layout.Layout adminLayout')
    expect(kr).toContain('@entering!"/admin"')
    expect(kr).toContain('@entering!"/:slug"')
    expect(kr.indexOf('@entering!"/admin"')).toBeLessThan(kr.indexOf('@entering!"/:slug"'))
    expect(kr).not.toContain('@child routes.admin.page.Page')
    expect(kr).not.toContain('mixin Spa!')

    const layout = readFileSync(join(ws, 'src-d', 'routes', 'admin', 'layout.d'), 'utf8')
    expect(layout).toContain('@child routes.admin.page.Page adminPage')
    expect(layout).toContain('@child routes.admin.users._id_.page.Page adminUsersIdPage')
    expect(layout).toContain('@child routes.admin.features.page.Page adminFeaturesPage')
    expect(layout).toContain('@child routes.admin.logs.page.Page adminLogsPage')
    expect(kr).toMatch(/@entering!"\/admin\/features"[\s\S]*setVisible!"adminFeaturesPage"\(adminLayout, true\)/)
    expect(kr).toMatch(/@entering!"\/admin\/logs"[\s\S]*setVisible!"adminLogsPage"\(adminLayout, true\)/)

    const feat = readFileSync(join(ws, 'src-d', 'routes', 'admin', 'features', 'page.d'), 'utf8')
    expect(feat).toContain('@style!"admin-features"')
    expect(feat).toMatch(/\/\/# svelte-d-ir orig=.*features\/\+page\.svelte/)
    const idPage = readFileSync(join(ws, 'src-d', 'routes', 'admin', 'users', '_id_', 'page.d'), 'utf8')
    expect(idPage).toContain('@style!"admin-user"')
    expect(idPage).toMatch(/\/\/# svelte-d-ir orig=.*users\/\[id\]\/\+page\.svelte/)
    expect(idPage).toContain('applyKitParams')
    expect(idPage).toContain('import kit.app_navigation')
    expect(idPage).toContain('gotoUrl("/admin/users")')
    expect(kr).toContain('adminLayout.adminUsersIdPage.id = _p')

    const app = readFileSync(join(ws, 'src-d', 'app.d'), 'utf8')
    expect(app).toContain('mixin Spa!App')
    expect(app).toContain('@child KitRoutes kitRoutes')
    const spa = app.match(/mixin Spa!/g) ?? []
    expect(spa.length).toBe(1)
  })
})
