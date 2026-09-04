// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { existsSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { findLibwasmRoot, findRiscvDev } from './paths.ts'

export const coreTypes = [
  'Handle',
  'Eval',
  'JsHandle',
  'JSON',
  'VarType',
  'entering',
  'leaving',
] as const

export const coreBindings = [
  'Document',
  'Window',
  'Console',
  'Location',
  'History',
  'Fetch',
] as const

export const routerNames = [
  'URLRouter',
  'RouterEvent',
  'registerRoutes',
  'navigateTo',
  'setBasePath',
  'router',
  'entering',
] as const

export function libwasmRoot(root = findRiscvDev()): string {
  return findLibwasmRoot(root)
}

export function loadBindingsCatalog(root = findRiscvDev()): string[] {
  const dir = join(libwasmRoot(root), 'source', 'libwasm', 'bindings')
  if (!existsSync(dir)) return []
  return readdirSync(dir)
    .filter((f) => f.endsWith('.d') && f !== 'package.d')
    .map((f) => f.slice(0, -2))
    .sort()
}

export function serveSurfaces(ws: string) {
  return {
    index: existsSync(join(ws, 'index.html')),
    vite: existsSync(join(ws, 'vite.config.js')),
    mainTs: existsSync(join(ws, 'src-ts', 'main.ts')),
    wasm:
      existsSync(join(ws, 'public', 'svelte-engine.wasm')) ||
      existsSync(join(ws, 'public', 'svelte-engine-raw.wasm')),
    kitRouter: existsSync(join(ws, 'src-d', 'kit_router.d')),
    bindingsD: existsSync(join(ws, 'src-d', 'lib', 'BindingsDemo.d')),
    typesD: existsSync(join(ws, 'src-d', 'lib', 'TypesDemo.d')),
    slugPage: existsSync(join(ws, 'src-d', 'routes', '_slug_', 'page.d')),
    hostExe:
      existsSync(join(ws, 'webserver', 'svelte-engine-server.exe')) ||
      existsSync(join(ws, 'webserver', 'svelte-engine-server')),
    pageServer: existsSync(
      join(ws, 'webserver', 'source', 'generated', 'routes', 'page_server.d')
    ),
  }
}
