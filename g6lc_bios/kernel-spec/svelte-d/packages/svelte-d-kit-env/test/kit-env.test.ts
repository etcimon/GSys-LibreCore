// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  compileWorkspace,
  dropWorkspace,
  extractDomUdas,
  runCli,
  workspaceDir,
} from 'svelte-d'

describe('kit-env compile: $app/$env enums, cookies/redirect, no private leak', () => {
  test('drop + compile writes kit enums and account IR + AccountPageServer', () => {
    expect(dropWorkspace({ force: true }).status).toBe(0)
    expect(compileWorkspace(workspaceDir()).status).toBe(0)
    const ws = workspaceDir()

    const wEnv = readFileSync(join(ws, 'src-d', 'kit', 'app_environment.d'), 'utf8')
    expect(wEnv).toContain('module kit.app_environment')
    expect(wEnv).toContain('enum bool browser = true')
    expect(wEnv).toContain('enum bool server = false')
    expect(wEnv).toContain('enum bool dev = true')

    const wPaths = readFileSync(join(ws, 'src-d', 'kit', 'app_paths.d'), 'utf8')
    expect(wPaths).toContain('module kit.app_paths')
    expect(wPaths).toContain('enum string base = ""')
    expect(wPaths).toContain('enum string assets = ""')

    const wNav = readFileSync(join(ws, 'src-d', 'kit', 'app_navigation.d'), 'utf8')
    expect(wNav).toContain('module kit.app_navigation')
    expect(wNav).toContain('void gotoUrl(string href)')
    expect(wNav).toContain('router().navigateTo(href)')
    expect(wNav).not.toContain('void goto(')

    const hNav = readFileSync(
      join(ws, 'webserver', 'source', 'generated', 'kit', 'app_navigation.d'),
      'utf8'
    )
    expect(hNav).toContain('module generated.kit.app_navigation')
    expect(hNav).toContain('void gotoUrl(string href)')
    expect(hNav).not.toContain('import libwasm')

    const wPub = readFileSync(join(ws, 'src-d', 'kit', 'env_static_public.d'), 'utf8')
    expect(wPub).toContain('module kit.env_static_public')
    expect(wPub).toContain('enum string PUBLIC_APP_NAME = "svelte-engine"')
    expect(wPub).not.toContain('SECRET_TOKEN')

    expect(existsSync(join(ws, 'src-d', 'kit', 'env_static_private.d'))).toBe(false)

    const hEnv = readFileSync(
      join(ws, 'webserver', 'source', 'generated', 'kit', 'app_environment.d'),
      'utf8'
    )
    expect(hEnv).toContain('module generated.kit.app_environment')
    expect(hEnv).toContain('enum bool browser = false')
    expect(hEnv).toContain('enum bool server = true')

    const hPriv = readFileSync(
      join(ws, 'webserver', 'source', 'generated', 'kit', 'env_static_private.d'),
      'utf8'
    )
    expect(hPriv).toContain('module generated.kit.env_static_private')
    expect(hPriv).toContain('enum string SECRET_TOKEN = "dev-secret"')
    expect(hPriv).not.toContain('PUBLIC_APP_NAME')

    const page = readFileSync(join(ws, 'src-d', 'routes', 'account', 'page.d'), 'utf8')
    expect(page).toContain('module routes.account.page')
    expect(page).toContain('import kit.app_environment')
    expect(page).toContain('import kit.app_paths')
    expect(page).toContain('import kit.env_static_public')
    expect(page).toContain('PUBLIC_APP_NAME')
    expect(page).toContain('import lib.Panel')
    expect(page).toContain('@child Panel panel')
    expect(page).toContain('@visible!"panel"')
    expect(page).toContain('document().title("Account")')
    expect(page).not.toContain('env_static_private')
    expect(page).not.toContain('SECRET_TOKEN')
    expect(extractDomUdas(page)).toContain('child')

    const host = readFileSync(
      join(ws, 'webserver', 'source', 'generated', 'routes', 'account', 'page_server.d'),
      'utf8'
    )
    expect(host).toContain('class AccountPageServer')
    expect(host).toContain('import generated.kit.env_static_private')
    expect(host).toContain('import generated.kit.app_environment')
    expect(host).toContain('req.cookies.get("who")')
    expect(host).toContain('res.redirect("/inbox")')
    expect(host).toContain('res.headers["X-Svelte-D"]')
    expect(host).toContain('res.setCookie("cell"')
    expect(host).toContain('SECRET_TOKEN')
    expect(host).not.toContain('import libwasm')

    const happ = readFileSync(join(ws, 'webserver', 'source', 'app.d'), 'utf8')
    expect(happ).toContain('registerWebInterface(new AccountPageServer')

    const kr = readFileSync(join(ws, 'src-d', 'kit_router.d'), 'utf8')
    expect(kr).toContain('@entering!"/account"')

    const ir = join(ws, '.svelte-d', 'ir', 'kit_env.json')
    expect(existsSync(ir)).toBe(true)
    expect(JSON.parse(readFileSync(ir, 'utf8')).kind).toBe('KitEnv')
  })

  test('kit-routes CLI lists /account', () => {
    const r = runCli(['kit-routes', '--ws', workspaceDir()])
    expect(r.status).toBe(0)
    expect(r.stdout).toContain('/account')
  })
})
