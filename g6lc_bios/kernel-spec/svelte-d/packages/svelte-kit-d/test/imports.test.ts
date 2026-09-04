// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { compileWorkspace, dropWorkspace, workspaceDir } from 'svelte-d'

describe('lang=d Phobos + host third-party imports', () => {
  test('PhobosDemo lifts std.* to the wasm module header', () => {
    const ws = workspaceDir()
    if (!existsSync(join(ws, 'src-d', 'app.d'))) {
      expect(dropWorkspace({ dest: ws, force: existsSync(ws) }).status).toBe(0)
    }
    expect(compileWorkspace(ws).status).toBe(0)
    const p = join(ws, 'src-d', 'lib', 'PhobosDemo.d')
    expect(existsSync(p)).toBe(true)
    const src = readFileSync(p, 'utf8')
    expect(src).toContain('module lib.PhobosDemo')
    expect(src).toContain('import std.algorithm : sum;')
    expect(src).toContain('import std.conv : to;')
    expect(src).toContain('import std.range : iota;')
    expect(src).toContain('struct PhobosDemo')
    expect(src).toContain('iota(1, 5).sum')
    expect(src).toContain('to!string(s)')
    expect(src.indexOf('import std.algorithm')).toBeLessThan(src.indexOf('nothrow:'))
    expect(src.indexOf('import std.algorithm')).toBeLessThan(src.indexOf('struct PhobosDemo'))
    expect(src).not.toContain('import std.file')
    expect(src).not.toContain('import vibe.')
  })

  test('rejects kernel Phobos and host packages in lang=d', () => {
    const ws = workspaceDir()
    const src = readFileSync(join(ws, 'src-d', 'lib', 'PhobosDemo.d'), 'utf8')
    expect(src).not.toMatch(/rejected import std\.(algorithm|conv|range)/)
  })
})
