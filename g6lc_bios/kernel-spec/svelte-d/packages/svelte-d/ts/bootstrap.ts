// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Mirrors source/svelte_d/bootstrap.d — keep the two in lockstep.
// Kit features are accommodated in svelte-engine / libwasm / vibe.0.
// Compile integrates the current engine as svelte-engine-ws.

import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

export type Surface = {
  path: string
  role: string
  runtime: string
}

export type Accommodate = {
  feature: string
  land: string
  runtime: string
  ws: string
}

export const requiredSurfaces: Surface[] = [
  { path: 'src-d/app.d', role: 'libwasm-root', runtime: 'libwasm' },
  { path: 'src-d/pglite.d', role: 'persistence', runtime: 'libwasm' },
  { path: 'src-d/dock.d', role: 'dynamic-ui', runtime: 'libwasm' },
  { path: 'src-ts/modules/index.ts', role: 'jsExports', runtime: 'libwasm' },
  { path: 'src-ts/modules/libwasm.ts', role: 'wasm-glue', runtime: 'libwasm' },
  { path: 'src-svelte/routes/+page.svelte', role: 'kit-source', runtime: 'source' },
  { path: 'webserver/source/app.d', role: 'vibe0-host', runtime: 'vibe.0' },
  { path: 'webserver/dub.sdl', role: 'host-cell', runtime: 'vibe.0' },
  { path: 'dub.sdl', role: 'wasm-cell', runtime: 'libwasm' },
]

export const accommodateFeatures: Accommodate[] = [
  {
    feature: 'markup/elements/components',
    land: 'svelte-engine/src-d',
    runtime: 'libwasm',
    ws: 'src-d',
  },
  {
    feature: 'script lang=d',
    land: 'svelte-engine/src-d',
    runtime: 'libwasm',
    ws: 'src-d',
  },
  {
    feature: 'script lang=ts / jsExports',
    land: 'svelte-engine/src-ts',
    runtime: 'libwasm',
    ws: 'src-ts/modules',
  },
  {
    feature: 'this.update / dynamic UI',
    land: 'svelte-engine/src-d',
    runtime: 'libwasm',
    ws: 'src-d',
  },
  {
    feature: 'routes +page/+layout',
    land: 'svelte-engine/src-svelte',
    runtime: 'libwasm',
    ws: 'src-svelte + src-d',
  },
  {
    feature: '+page.server / +server / load / actions',
    land: 'svelte-engine/webserver',
    runtime: 'vibe.0',
    ws: 'webserver',
  },
  {
    feature: 'persistence / PgLite',
    land: 'svelte-engine/src-d/pglite.d',
    runtime: 'libwasm',
    ws: 'src-d/pglite.d',
  },
  {
    feature: 'Lodash chains / execute!T',
    land: 'svelte-engine/src-d + libwasm.lodash',
    runtime: 'libwasm',
    ws: 'src-d',
  },
  {
    feature: 'bindings Document/Window/console',
    land: 'svelte-engine/src-d + libwasm.bindings',
    runtime: 'libwasm',
    ws: 'src-d',
  },
  {
    feature: 'types Handle/Eval/JSON/VarType',
    land: 'svelte-engine/src-d + libwasm.types',
    runtime: 'libwasm',
    ws: 'src-d',
  },
  {
    feature: 'kit routes / URLRouter',
    land: 'svelte-engine + libwasm.router',
    runtime: 'libwasm',
    ws: 'src-d/kit_router.d',
  },
  {
    feature: '$app / $env static',
    land: 'svelte-engine/.env + generated kit enums',
    runtime: 'libwasm+vibe.0',
    ws: 'src-d/kit + webserver/source/generated/kit',
  },
  {
    feature: 'kit admin PG/Redis/JSON',
    land: 'svelte-engine/webserver helpers connectDB/connectCache',
    runtime: 'vibe.0',
    ws: 'webserver + routes/admin',
  },
  {
    feature: 'NodeDef / NamedNode / @prop / @callback / compile!',
    land: 'svelte-engine/src-d + libwasm.dom',
    runtime: 'libwasm',
    ws: 'src-d',
  },
  {
    feature: '{#each} list events / HTMLArray / inject!',
    land: 'svelte-engine/src-d + libwasm.array',
    runtime: 'libwasm',
    ws: 'src-d',
  },
  {
    feature: 'HMR dumpApp/loadApp',
    land: 'svelte-engine + libwasm',
    runtime: 'libwasm',
    ws: 'src-ts + src-d',
  },
  {
    feature: 'new kit syntax',
    land: 'update svelte-engine; titled libwasm or vibe.0 seam if needed',
    runtime: 'engine-first',
    ws: 'svelte-engine-ws',
  },
]

export function missingSurfaces(root: string): string[] {
  return requiredSurfaces.filter((s) => !existsSync(join(root, s.path))).map((s) => s.path)
}

export function verifyBootstrap(ws: string): {
  ok: boolean
  missing: string[]
  document: Record<string, unknown> | null
} {
  const missing = missingSurfaces(ws)
  const p = join(ws, '.svelte-d', 'bootstrap.json')
  let document: Record<string, unknown> | null = null
  if (existsSync(p)) {
    document = JSON.parse(readFileSync(p, 'utf8')) as Record<string, unknown>
  }
  return { ok: missing.length === 0, missing, document }
}
