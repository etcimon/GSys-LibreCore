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

describe('kit-host compile: rest *, hooks errorPageHandler, inbox post/postSave', () => {
  test('drop + compile writes files/inbox IR, /files/*, Hooks, InboxPageServer', () => {
    expect(dropWorkspace({ force: true }).status).toBe(0)
    expect(compileWorkspace(workspaceDir()).status).toBe(0)
    const ws = workspaceDir()

    const files = readFileSync(
      join(ws, 'src-d', 'routes', 'files', '_path_', 'page.d'),
      'utf8'
    )
    expect(files).toContain('module routes.files._path_.page')
    expect(files).toContain('import lib.Panel')
    expect(files).toContain('@child Panel panel')
    expect(files).toContain('@visible!"panel"')
    expect(files).toContain('document().title("Files")')
    expect(files).toContain('UnorderedList!')
    expect(extractDomUdas(files)).toContain('child')
    expect(files).not.toContain('mixin Spa!')

    const inbox = readFileSync(join(ws, 'src-d', 'routes', 'inbox', 'page.d'), 'utf8')
    expect(inbox).toContain('module routes.inbox.page')
    expect(inbox).toContain('import lib.ClickField')
    expect(inbox).toContain('@child ClickField clickField')
    expect(inbox).toContain('@visible!"clickField"')
    expect(inbox).toContain('document().title("Inbox")')
    expect(inbox).toContain('mixin NodeDef!"form"')
    expect(inbox).toContain('mixin NodeDef!"input"')
    expect(extractDomUdas(inbox)).toContain('visible')

    const app = readFileSync(join(ws, 'src-d', 'app.d'), 'utf8')
    expect(app).toContain('mixin Spa!App')
    expect(app).not.toContain('@child Files ')
    expect(app).not.toContain('@child Inbox ')

    const kr = readFileSync(join(ws, 'src-d', 'kit_router.d'), 'utf8')
    expect(kr).toContain('@entering!"/files/*"')
    expect(kr).toContain('@entering!"/inbox"')
    expect(kr).not.toContain('[...path]')

    const hooks = readFileSync(join(ws, 'webserver', 'source', 'generated', 'hooks.d'), 'utf8')
    expect(hooks).toContain('module generated.hooks')
    expect(hooks).toContain('class Hooks')
    expect(hooks).toContain('void handleError(')
    expect(hooks).toContain('HTTPServerErrorInfo')
    expect(hooks).toContain('writeBody("hook-error")')
    expect(hooks).not.toContain('import libwasm')

    const inboxHost = readFileSync(
      join(ws, 'webserver', 'source', 'generated', 'routes', 'inbox', 'page_server.d'),
      'utf8'
    )
    expect(inboxHost).toContain('class InboxPageServer')
    expect(inboxHost).toContain('void post(')
    expect(inboxHost).toContain('void postSave(')
    expect(inboxHost).toContain('writeBody("inbox")')
    expect(inboxHost).toContain('writeBody("inbox-save")')

    const happ = readFileSync(join(ws, 'webserver', 'source', 'app.d'), 'utf8')
    expect(happ).toContain('import generated.hooks')
    expect(happ).toContain('import generated.routes.inbox.page_server')
    expect(happ).toContain('settings.errorPageHandler')
    expect(happ).toContain('new Hooks')
    expect(happ).toContain('hooks.handleError(')
    expect(happ).toContain('registerWebInterface(new InboxPageServer')
    expect(happ).not.toContain('registerWebInterface(new Hooks')
    expect(happ).toContain('registerWebInterface(new PageServer')

    const gen = join(ws, 'src-ts', 'modules', 'generated')
    const names = existsSync(gen) ? readdirSync(gen) : []
    expect(names.some((n) => n.includes('files') && n.endsWith('.ts'))).toBe(true)
    expect(names.some((n) => n.includes('inbox') && n.endsWith('.ts'))).toBe(true)

    const ft = JSON.parse(readFileSync(join(ws, '.svelte-d', 'fallthrough.json'), 'utf8'))
    const restEnt = ft.entries.find((e: { kitRel: string }) =>
      e.kitRel.replace(/\\/g, '/').includes('files/[...path]/+page.svelte')
    )
    expect(restEnt).toBeTruthy()
    expect(restEnt.srcD).toBe('src-d/routes/files/_path_/page.d')

    const man = JSON.parse(readFileSync(join(ws, '.svelte-d', 'manifest.json'), 'utf8'))
    expect(man.fail).toBe(0)
    expect(man.host).toBeGreaterThanOrEqual(6)
  })

  test('kit-routes CLI lists /files/* and /inbox', () => {
    const r = runCli(['kit-routes', '--ws', workspaceDir()])
    expect(r.status).toBe(0)
    expect(r.stdout).toContain('/files/*')
    expect(r.stdout).toContain('/inbox')
  })
})
