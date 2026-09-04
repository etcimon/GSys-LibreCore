// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  compileWorkspace,
  dropWorkspace,
  extractDomUdas,
  mapKitPath,
  parseSvelte,
  templateDir,
  workspaceDir,
} from 'svelte-d'

function compiled(rel: string) {
  return join(workspaceDir(), rel)
}

describe('multi-file official graph via import svelte-d', () => {
  test('engine fixtures exist (Panel + AppShell)', () => {
    const tpl = templateDir()
    expect(existsSync(join(tpl, 'src-svelte', 'lib', 'Panel.svelte'))).toBe(true)
    expect(existsSync(join(tpl, 'src-svelte', 'lib', 'AppShell.svelte'))).toBe(true)
  })

  test('drop + compile writes both libwasm structs and hangs them on App', () => {
    expect(dropWorkspace({ force: true }).status).toBe(0)
    const c = compileWorkspace(workspaceDir())
    expect(c.status).toBe(0)

    const panel = readFileSync(compiled('src-d/lib/Panel.d'), 'utf8')
    expect(panel).toContain('module lib.Panel')
    expect(panel).toContain('struct Panel')
    expect(panel).toContain('mixin Slot!"done"')
    expect(panel).toContain('this.emit(done)')
    expect(panel).toContain('@connect!"finishButton.click"')
    expect(panel).toContain('finish();')
    expect(panel).toContain('@prop!"textContent" string title')
    expect(panel).toContain('@prop!"value"')
    expect(panel).toContain('@style!"on" bool on')
    expect(panel).toContain('mixin Slot!"default_"')
    expect(panel).toContain('text = "fallback"')
    const pudas = extractDomUdas(panel)
    expect(pudas).toContain('NodeDef')
    expect(pudas).toContain('Slot')
    expect(pudas).toContain('connect')
    expect(pudas).toContain('prop')

    const shell = readFileSync(compiled('src-d/lib/AppShell.d'), 'utf8')
    expect(shell).toContain('module lib.AppShell')
    expect(shell).toContain('import lib.Panel')
    expect(shell).toContain('@child Panel panel')
    expect(shell).toContain('@visible!"panel"')
    expect(shell).toContain('bool ready')
    expect(shell).toContain('panel.title = who')
    expect(shell).toContain('@connect!"panel.done"')
    expect(shell).toContain('go();')
    expect(shell).toContain('Handle panelRef')
    expect(shell).toContain('panelRef = panel.node.handle.handle')
    expect(shell).toContain('UnorderedList!Item items')
    expect(shell).toContain('setVisible!"panel"')
    const sudas = extractDomUdas(shell)
    expect(sudas).toContain('visible')
    expect(sudas).toContain('child')
    expect(sudas).toContain('connect')
    expect(sudas).toContain('UnorderedList')

    const app = readFileSync(compiled('src-d/app.d'), 'utf8')
    expect(app).toContain('import lib.Panel')
    expect(app).toContain('@child Panel panel')
    expect(app).toContain('import lib.AppShell')
    expect(app).toContain('@child AppShell appShell')
  })
})
