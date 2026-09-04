// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  bundledTemplateDir,
  compileWorkspace,
  dropWorkspace,
  extractDomUdas,
  identFromRel,
  loadDebugMap,
  loadInspector,
  loadOverlay,
  lookupOrig,
  rewriteStack,
  runCli,
} from 'svelte-d'
import { adminWorkspace } from '../src/ws.ts'

const project = dirname(dirname(fileURLToPath(import.meta.url)))

describe('kit-admin compile: IR, debug-map, vibe.0 PG/Redis/JSON', () => {
  test('drop packaged engine + ingest project admin into the workspace', () => {
    expect(bundledTemplateDir().length).toBeGreaterThan(0)
    const ws = adminWorkspace()
    expect(ws.replace(/\\/g, '/')).toMatch(/svelte-d-kit-admin\/svelte-engine-ws$/)
    const dropped = dropWorkspace({ dest: ws, force: true })
    if (dropped.status !== 0) {
      // Leftover Vite may still hold a file; reuse a populated ws.
      expect(existsSync(join(ws, 'src-d', 'app.d'))).toBe(true)
    }
    expect(compileWorkspace({ ws, project }).status).toBe(0)

    const layout = readFileSync(join(ws, 'src-d', 'routes', 'admin', 'layout.d'), 'utf8')
    expect(layout).toMatch(/\/\/# svelte-d-ir orig=.*routes\/admin\/\+layout\.svelte:1 kind=file/)
    expect(layout).toContain('document().title("Admin")')
    expect(layout).toContain('mixin Slot!"default_"')
    expect(layout).toContain('kind=if')

    const dash = readFileSync(join(ws, 'src-d', 'routes', 'admin', 'page.d'), 'utf8')
    expect(dash).toContain('import lib.Panel')
    expect(dash).toContain('@child Panel panel')
    expect(dash).toContain('@visible!"panel"')
    expect(dash).toContain('kind=component name=Panel')
    expect(extractDomUdas(dash)).toContain('child')
    expect(dash).not.toContain('mixin Spa!')

    const users = readFileSync(join(ws, 'src-d', 'routes', 'admin', 'users', 'page.d'), 'utf8')
    expect(users).toContain('UnorderedList!')
    expect(users).toContain('kind=each')
    expect(users).toContain('kind=if')
    expect(users).toContain('@visible!"users"')

    const logs = readFileSync(join(ws, 'src-d', 'routes', 'admin', 'logs', 'page.d'), 'utf8')
    expect(logs).toContain('UnorderedList!')
    expect(logs).toContain('kind=if')
    expect(logs).toContain('@visible!"items"')

    const user = readFileSync(join(ws, 'src-d', 'routes', 'admin', 'users', '_id_', 'page.d'), 'utf8')
    expect(user).toContain('module routes.admin.users._id_.page')
    expect(user).toContain('import kit.app_environment')
    expect(user).toContain('import kit.app_paths')
    expect(user).toContain('import lib.Panel')
    expect(user).toContain('@visible!"panel"')
    expect(user).toContain('document().title("User")')
    expect(user).toContain('string id')
    expect(user).toContain('void applyKitParams()')
    expect(user).toContain('admin-user-id')
    expect(user).toContain('await_pending')
    expect(user).toContain('await_then')
    expect(user).toContain('await_catch')

    const cover = readFileSync(join(ws, 'src-d', 'lib', 'ComboCover.d'), 'utf8')
    expect(cover).toContain('void wireAwait()')
    expect(cover).toContain('libwasmAwaitSupported()')
    expect(cover).toMatch(/job\.await/)
    expect(cover).toContain('libwasmAwaitFailed()')
    expect(cover).toContain('libwasmAwaitError()')
    expect(cover).toContain('eP.e =')
    expect(cover).toContain('libwasmNoteAwaitFail')
    expect(cover).toContain('libwasmAwaitValue()')
    expect(cover).toContain('vP.v =')
    expect(cover).toContain('libwasmNoteAwaitOk')
    expect(cover).toContain('.then(delegate void(Any _v)')

    const feat = readFileSync(join(ws, 'src-d', 'routes', 'admin', 'features', 'page.d'), 'utf8')
    expect(feat).toContain('import lib.ClickField')
    expect(feat).toContain('import lib.Panel')
    expect(feat).toContain('kind=if')
    expect(feat).toContain('UnorderedList!')
    expect(feat).toContain('await_pending')
    expect(feat).toContain('mixin NodeDef!"form"')
    expect(feat).toContain('document().title("Features")')

    const phobos = readFileSync(join(ws, 'src-d', 'lib', 'PhobosDemo.d'), 'utf8')
    expect(phobos).toContain('import std.algorithm : sum;')
    expect(phobos).toContain('import std.conv : to;')
    expect(phobos).toContain('import std.range : iota;')
    expect(phobos.indexOf('import std.algorithm')).toBeLessThan(phobos.indexOf('struct PhobosDemo'))

    const errp = readFileSync(join(ws, 'src-d', 'routes', 'admin', 'error.d'), 'utf8')
    expect(errp).toContain('text = "admin error"')
    expect(errp).toContain('kind=if')

    const app = readFileSync(join(ws, 'src-d', 'app.d'), 'utf8')
    expect(app).toContain('mixin Spa!App')
    expect(app).not.toContain('@child Admin ')
    expect(app).toContain('@child AdminDash adminDash')
    expect(app).toContain('@child KitRoutes kitRoutes')
    expect(app).toContain('import svelte_engine.kit_router')

    const kr = readFileSync(join(ws, 'src-d', 'kit_router.d'), 'utf8')
    expect(kr).toContain('@entering!"/admin"')
    expect(kr).toContain('@entering!"/admin/users"')
    expect(kr).toContain('@entering!"/admin/users/:id"')
    expect(kr).toContain('@entering!"/admin/logs"')
    expect(kr).toContain('@entering!"/admin/features"')
    expect(kr).not.toMatch(/@entering!"\/admin\/error"/)
    expect(kr).toContain('@child routes.admin.layout.Layout')
    expect(kr).not.toContain('@child routes.admin.page.Page')
    expect(kr).toContain('setVisible!"adminPage"(adminLayout, true)')
    expect(kr).toContain('setVisible!"adminUsersPage"(adminLayout, true)')
    expect(kr).toContain('adminLayout.adminUsersIdPage.id = _p')
    expect(kr).toContain('adminLayout.adminUsersIdPage.applyKitParams()')
    expect(kr).toContain('ev.parameters["id"]')
    expect(kr).toContain('setVisible!"adminLayout"(this, true)')
    expect(kr).toContain('setVisible!"slot_default"(adminLayout, false)')
    expect(kr).toContain('mixin NodeDef!"div"')

    const adminLayout = readFileSync(join(ws, 'src-d', 'routes', 'admin', 'layout.d'), 'utf8')
    expect(adminLayout).toContain('import routes.admin.page')
    expect(adminLayout).toContain('@child routes.admin.page.Page adminPage')
    expect(adminLayout).toContain('@child routes.admin.users.page.Page adminUsersPage')
    expect(adminLayout).toContain('@visible!"adminPage"')

    const dashHost = readFileSync(
      join(ws, 'webserver', 'source', 'generated', 'routes', 'admin', 'page_server.d'),
      'utf8'
    )
    expect(dashHost).toContain('class AdminPageServer')
    expect(dashHost).toContain('void getAdmin(')
    expect(dashHost).toContain('void getSoak(')
    expect(dashHost).toContain('redis.set(')
    expect(dashHost).toContain('svelte-d-host-soak/v1')
    expect(dashHost).toContain('connectCache()')
    expect(dashHost).toContain('connectDB()')
    expect(dashHost).toContain('serializeToJsonString')
    expect(dashHost).toContain('logInfo')
    expect(dashHost).toContain('logError')
    expect(dashHost).toContain('logTrace')
    expect(dashHost).toContain('logWarn')
    expect(dashHost).toContain('scoped!PGCommand')
    expect(dashHost).toContain('executeQuery!int()')
    expect(dashHost).not.toContain('import libwasm')

    const usersHost = readFileSync(
      join(ws, 'webserver', 'source', 'generated', 'routes', 'admin', 'users', 'page_server.d'),
      'utf8'
    )
    expect(usersHost).toContain('class AdminUsersPageServer')
    expect(usersHost).toContain('void getUsers(')
    expect(usersHost).toContain('connectDB()')
    expect(usersHost).toContain('serializeToJsonString')

    const logsHost = readFileSync(
      join(ws, 'webserver', 'source', 'generated', 'routes', 'admin', 'logs', 'page_server.d'),
      'utf8'
    )
    expect(logsHost).toContain('class AdminLogsPageServer')
    expect(logsHost).toContain('void getLogs(')
    expect(logsHost).toContain('connectCache()')
    expect(logsHost).toContain('serializeToJsonString')

    const happ = readFileSync(join(ws, 'webserver', 'source', 'app.d'), 'utf8')
    const userHost = readFileSync(
      join(ws, 'webserver', 'source', 'generated', 'routes', 'admin', 'users', '_id_', 'page_server.d'),
      'utf8'
    )
    expect(userHost).toContain('class AdminUsersIdPageServer')
    expect(userHost).toContain('void getUser(')
    expect(userHost).toContain('req.cookies.get("who")')
    expect(userHost).toContain('res.redirect(')
    expect(userHost).toContain('res.setCookie("seen"')
    expect(userHost).toContain('import generated.kit.app_environment')
    expect(userHost).toContain('PUBLIC_APP_NAME')
    expect(userHost).not.toContain('import libwasm')

    const featHost = readFileSync(
      join(ws, 'webserver', 'source', 'generated', 'routes', 'admin', 'features', 'page_server.d'),
      'utf8'
    )
    expect(featHost).toContain('class AdminFeaturesPageServer')
    expect(featHost).toContain('void postProbe(')
    expect(featHost).toContain('connectCache()')
    expect(featHost).toContain('serializeToJsonString')
    expect(featHost).toContain('import helpers;')
    expect(featHost).toContain('import vibe.db.redis.redis;')
    expect(featHost).toContain('import vibe.db.pgsql.pgsql;')
    expect(featHost).toContain('import botan.passhash.bcrypt;')
    expect(featHost).toContain('import std.conv : to;')
    expect(featHost).toContain('to!string(1)')
    expect(featHost).not.toContain('import libwasm')
    expect(featHost.indexOf('import vibe.db.redis.redis')).toBeLessThan(
      featHost.indexOf('class AdminFeaturesPageServer')
    )

    expect(happ).toContain('registerWebInterface(new AdminPageServer')
    expect(happ).toContain('registerWebInterface(new AdminUsersPageServer')
    expect(happ).toContain('registerWebInterface(new AdminLogsPageServer')
    expect(happ).toContain('registerWebInterface(new AdminUsersIdPageServer')
    expect(happ).toContain('registerWebInterface(new AdminFeaturesPageServer')

    const mapFile = join(ws, '.svelte-d', 'debug-map.json')
    expect(existsSync(mapFile)).toBe(true)
    const dm = JSON.parse(readFileSync(mapFile, 'utf8'))
    expect(dm.schema).toBe('svelte-d-debug-map/v1')
    expect(dm.principle).toContain('D-IR-is-correctness-surface')
    expect(dm.entries.length).toBeGreaterThan(0)
    const fileEnt = dm.entries.find(
      (e: { kind: string; dest: string }) =>
        e.kind === 'file' && e.dest.replace(/\\/g, '/').includes('routes/admin/page.d')
    )
    expect(fileEnt).toBeTruthy()
    expect(fileEnt.orig.replace(/\\/g, '/')).toMatch(/admin\/\+page\.svelte$/)

    const map = loadDebugMap(ws)
    const hit = lookupOrig(map, 'src-d/routes/admin/page.d', 80)
    expect(hit).toBeTruthy()
    expect(hit?.orig.replace(/\\/g, '/')).toMatch(/admin\/\+page\.svelte$/)
    const stack = rewriteStack(
      map,
      'Error\n    at go (src-d/routes/admin/page.d:24:1)'
    )
    expect(stack).toContain('[svelte ')
    expect(stack).toMatch(/admin\/\+page\.svelte/)
    expect(rewriteStack(map, 'at unknown.js:1:1')).toBe('at unknown.js:1:1')
    const idStack = rewriteStack(map, 'at src-d/routes/admin/users/_id_/page.d:20:1')
    expect(idStack).toMatch(/admin\/users\/\[id\]\/\+page\.svelte|admin\/users/)
    const kinds = new Set(map.entries.filter((e) => e.dest.includes('admin')).map((e) => e.kind))
    expect(kinds.has('file')).toBe(true)
    expect(kinds.has('if')).toBe(true)
    expect(kinds.has('each')).toBe(true)
    const featStack = rewriteStack(map, 'at src-d/routes/admin/features/page.d:16:1')
    expect(featStack).toMatch(/admin\/features\/\+page\.svelte/)
    const usersStack = rewriteStack(map, 'at src-d/routes/admin/users/page.d:12:1')
    expect(usersStack).toMatch(/admin\/users\/\+page\.svelte/)

    const ovFile = join(ws, '.svelte-d', 'overlay.json')
    expect(existsSync(ovFile)).toBe(true)
    expect(existsSync(join(ws, 'public', '__svelte-d', 'overlay.json'))).toBe(true)
    expect(existsSync(join(ws, 'public', '__svelte-d', 'overlay', 'index.html'))).toBe(true)
    expect(existsSync(join(ws, 'public', '__svelte-d', 'overlay.html'))).toBe(true)
    const ov = loadOverlay(ws)
    expect(ov.schema).toBe('svelte-d-overlay/v1')
    expect(ov.principle).toContain('overlay-is-trace-only')
    expect(ov.ok).toBe(true)
    expect(ov.fail).toBe(0)
    const ldc = rewriteStack(map, 'src-d/routes/admin/page.d(24,1): Error: no identifier n')
    expect(ldc).toContain('[svelte ')
    expect(ldc).toMatch(/admin\/\+page\.svelte/)

    expect(existsSync(join(ws, '.svelte-d', 'ir.json'))).toBe(true)
    expect(existsSync(join(ws, 'public', '__svelte-d', 'ir.html'))).toBe(true)
    expect(existsSync(join(ws, 'public', '__svelte-d', 'ir', 'index.html'))).toBe(true)
    const ir = loadInspector(ws)
    expect(ir.schema).toBe('svelte-d-ir-inspector/v1')
    expect(ir.principle).toContain('inspector-is-read-only')
    expect(ir.entries).toBeGreaterThan(0)
    expect(ir.kinds.file).toBeGreaterThan(0)
    expect(ir.kinds.if).toBeGreaterThan(0)
    expect(ir.dests.some((d) => d.includes('AdminDash.d'))).toBe(true)
    expect(ir.dests.some((d) => d.includes('routes/admin/page.d'))).toBe(true)
  })

  test('cross-language / multi-tag scripts and project deps fall through to dest', () => {
    const ws = adminWorkspace()
    expect(compileWorkspace({ ws, project }).status).toBe(0)

    const bridgeIdent = identFromRel('lib/AdminBridge.svelte')
    const gen = join(ws, 'src-ts', 'modules', 'generated')
    const inst = join(gen, bridgeIdent + '.ts')
    const mod = join(gen, bridgeIdent + '_mod.ts')
    expect(existsSync(inst)).toBe(true)
    expect(existsSync(mod)).toBe(true)

    const tsInst = readFileSync(inst, 'utf8')
    expect(tsInst).toContain("from 'admin-mini'")
    expect(tsInst).toMatch(/from ['\"]\.\.\/\.\.\/helpers\/lib\/admin-fmt['\"]/)
    expect(tsInst).toContain('registerTs')
    expect(tsInst).toContain('label')
    expect(tsInst).toContain('loadLabel')
    expect(tsInst).toContain('...args')
    expect(tsInst).not.toContain('registerTs("'+bridgeIdent+'", "jsExports"')

    const tsMod = readFileSync(mod, 'utf8')
    expect(tsMod).toContain('adminBridgeReady')
    expect(tsMod).toContain('registerTs')
    expect(tsMod).toContain(bridgeIdent + '_mod')

    const d = readFileSync(join(ws, 'src-d', 'lib', 'AdminBridge.d'), 'utf8')
    expect(d).toContain('callTs!(string)')
    expect(d).toContain(bridgeIdent + '.label')
    expect(d).toContain('callTsPromise!(string)')
    expect(d).toContain(bridgeIdent + '.loadLabel')
    expect(d).toContain('ARGS...')
    expect(d).toContain('extern(C) export int tally')
    expect(d).toContain('int b = 1')
    expect(d).toContain('exportDelegate("' + bridgeIdent + '.tally"')
    expect(d).toContain('registerDExports_' + bridgeIdent)
    expect(d).toContain('label("Ada")')
    expect(d).toContain('label()')

    const peer = readFileSync(join(ws, 'src-d', 'lib', 'AdminPeer.d'), 'utf8')
    expect(peer).toContain('import lib.AdminBridge')
    expect(peer).toContain('label("Peer")')

    const feat = readFileSync(join(ws, 'src-d', 'routes', 'admin', 'features', 'page.d'), 'utf8')
    expect(feat).toMatch(/AdminBridge|adminBridge/)
    expect(feat).toMatch(/AdminPeer|adminPeer/)

    const app = readFileSync(join(ws, 'src-d', 'app.d'), 'utf8')
    expect(app).toContain('@child AdminBridge adminBridge')
    expect(app).toContain('@child AdminPeer adminPeer')

    expect(existsSync(join(ws, 'src-ts', 'modules', 'helpers', 'lib', 'admin-fmt.ts'))).toBe(true)
    expect(readFileSync(join(ws, 'src-ts', 'modules', 'helpers', 'lib', 'admin-fmt.ts'), 'utf8')).toContain(
      'export function fmt'
    )

    const wsPkg = JSON.parse(readFileSync(join(ws, 'package.json'), 'utf8')) as {
      dependencies?: Record<string, string>
    }
    expect(wsPkg.dependencies?.['admin-mini']).toBe('1.0.0')
    expect(existsSync(join(ws, 'node_modules', 'admin-mini', 'package.json'))).toBe(true)
    expect(JSON.parse(readFileSync(join(ws, 'node_modules', 'admin-mini', 'package.json'), 'utf8')).name).toBe(
      'admin-mini'
    )
    expect(readFileSync(join(ws, 'node_modules', 'admin-mini', 'index.js'), 'utf8')).toContain('dash')

    const idx = readFileSync(join(ws, 'src-ts', 'modules', 'index.ts'), 'utf8')
    expect(idx).toContain(bridgeIdent)
    expect(idx).toContain(bridgeIdent + '_mod')
  })

  test('kit-routes CLI lists /admin tree including :id and features', () => {
    const r = runCli(['kit-routes', '--ws', adminWorkspace()])
    expect(r.status).toBe(0)
    expect(r.stdout).toContain('/admin')
    expect(r.stdout).toContain('/admin/users')
    expect(r.stdout).toContain('/admin/users/:id')
    expect(r.stdout).toContain('/admin/logs')
    expect(r.stdout).toContain('/admin/features')
  })
})
