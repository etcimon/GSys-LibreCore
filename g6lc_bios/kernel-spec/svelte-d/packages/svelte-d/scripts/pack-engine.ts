// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Copy the svelte-engine *runtime bootstrap* into this package so a
// `node_modules/svelte-d` install can drop/compile without a sibling
// checkout. Canonical dest is svelte-d/svelte-engine; templates/engine
// stays as the legacy name. Skips build artifacts, node_modules, wasm/exe,
// and app-only admin routes.
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const pkg = resolve(here, '..')
const dests = [join(pkg, 'svelte-engine'), join(pkg, 'templates', 'engine')]

function findEngine(start: string): string {
  let p = start
  for (let i = 0; i < 10; i++) {
    const cand = join(p, 'svelte-engine')
    if (existsSync(join(cand, 'AGENTS.md')) || existsSync(join(cand, 'dub.sdl')))
      return cand
    const parent = dirname(p)
    if (parent === p) break
    p = parent
  }
  throw new Error('cannot find svelte-engine to pack')
}

function skipPart(name: string): boolean {
  const b = name.toLowerCase()
  if (
    b === 'node_modules' ||
    b === '.dub' ||
    b === '.git' ||
    b === '.svelte-d' ||
    b === 'prisma' ||
    b === 'integrations' ||
    b === 'generatesourcemap.py' ||
    b === 'capacitor.config.json'
  )
    return true
  if (
    b.endsWith('.exe') ||
    b.endsWith('.pdb') ||
    b.endsWith('.obj') ||
    b.endsWith('.lib') ||
    b.endsWith('.wasm')
  )
    return true
  return false
}

function skipRel(rel: string): boolean {
  const parts = rel.split(/[\\/]/)
  if (parts.some(skipPart)) return true
  const posix = rel.replace(/\\/g, '/')
  if (posix.startsWith('src-svelte/routes/admin')) return true
  if (posix.startsWith('webserver/certs')) return true
  if (posix.startsWith('webserver/prisma')) return true
  if (posix === 'webserver/3dify.json' || posix.endsWith('/3dify.json')) return true
  if (posix.endsWith('comfyapi.d') || posix.endsWith('workflow_api.json')) return true
  if (posix === 'generateSourceMap.py' || posix.endsWith('/generateSourceMap.py'))
    return true
  if (posix === 'capacitor.config.json' || posix.endsWith('/capacitor.config.json'))
    return true
  return false
}

function walkCopy(fromDir: string, out: string, engineRoot: string) {
  mkdirSync(out, { recursive: true })
  for (const name of readdirSync(fromDir)) {
    const from = join(fromDir, name)
    const rel = relative(engineRoot, from)
    if (skipRel(rel) || skipPart(name)) continue
    const to = join(out, name)
    const st = statSync(from)
    if (st.isDirectory()) walkCopy(from, to, engineRoot)
    else cpSync(from, to)
  }
}

const src = findEngine(resolve(pkg, '..', '..'))
for (const dest of dests) {
  if (resolve(src) === resolve(dest)) {
    console.log('skip packing', dest, '(same as source)')
    continue
  }
  if (existsSync(dest)) rmSync(dest, { recursive: true, force: true })
  walkCopy(src, dest, src)
  writeFileSync(
    join(dest, '.svelte-d-bootstrap'),
    'svelte-d packaged svelte-engine bootstrap\n'
  )
  console.log('packed', src, '->', dest)
}
