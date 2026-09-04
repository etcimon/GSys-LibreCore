// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Mirrors source/svelte_d/fallthrough.d — keep the two in lockstep.
// Guiding principle: kit syntax falls through to libwasm / vibe.0
// in a roughly equivalent structure inside svelte-engine-ws.

export type Fallthrough = {
  kitRel: string
  kind: string
  cell: 'wasm' | 'host' | 'both' | string
  runtime: string
  srcSvelte: string
  srcD: string
  srcTs: string
  host: string
}

export function normalizeKitRel(p: string): string {
  let s = p.replace(/\\/g, '/')
  while (s.startsWith('/')) s = s.slice(1)
  if (s.startsWith('src-svelte/')) s = s.slice('src-svelte/'.length)
  else if (s.startsWith('src/')) s = s.slice('src/'.length)
  else {
    const from = s.indexOf('src-svelte/')
    if (from >= 0) s = s.slice(from + 'src-svelte/'.length)
  }
  return s
}

export function identFromRel(rel: string): string {
  let s = ''
  for (const c of rel) {
    if (/[A-Za-z0-9]/.test(c)) s += c
    else s += '_'
  }
  if (!s.length) s = 'mod'
  if (/^[0-9]/.test(s)) s = 'm_' + s
  return s
}

/** Kit `[slug]` / `[[lang]]` / `[...path]` → dest `_slug_` / `_lang_` / `_path_`. */
export function sanitizeDestSeg(s: string): string {
  if (s.length >= 5 && s.startsWith('[[') && s.endsWith(']]'))
    return '_' + s.slice(2, -2) + '_'
  if (s.length >= 6 && s.startsWith('[...') && s.endsWith(']'))
    return '_' + s.slice(4, -1) + '_'
  if (s.length >= 3 && s.startsWith('[') && s.endsWith(']'))
    return '_' + s.slice(1, -1) + '_'
  return s
}

export function sanitizeDestDir(dir: string): string {
  return dir
    .replace(/\\/g, '/')
    .split('/')
    .filter((p) => p && p !== '.')
    .map(sanitizeDestSeg)
    .join('/')
}

function posix(...parts: string[]): string {
  return parts
    .filter((p) => p && p !== '.' && p !== '')
    .join('/')
    .replace(/\\/g, '/')
    .replace(/\/+/g, '/')
}

function dStem(base: string): string {
  let n = base.replace(/\.[^.]+$/, '')
  if (n.startsWith('+')) n = n.slice(1)
  return n.replace(/\./g, '_')
}

/** Map one bun-project or kit-relative path onto svelte-engine-ws cells. */
export function mapKitPath(kitRel: string): Fallthrough {
  const rel = normalizeKitRel(kitRel)
  const slash = rel.lastIndexOf('/')
  const base = slash >= 0 ? rel.slice(slash + 1) : rel
  const dir = sanitizeDestDir(slash >= 0 ? rel.slice(0, slash) : '')
  const srcSvelte = posix('src-svelte', rel)
  const empty = (): Fallthrough => ({
    kitRel: rel,
    kind: 'unknown',
    cell: 'wasm',
    runtime: '',
    srcSvelte,
    srcD: '',
    srcTs: '',
    host: '',
  })

  if (base === '+page.svelte') {
    return {
      kitRel: rel,
      kind: 'page',
      cell: 'wasm',
      runtime: 'libwasm+jsExports',
      srcSvelte,
      srcD: posix('src-d', dir, 'page.d'),
      srcTs: posix('src-ts/modules/generated', identFromRel(rel) + '.ts'),
      host: '',
    }
  }
  if (base === '+layout.svelte') {
    return {
      kitRel: rel,
      kind: 'layout',
      cell: 'wasm',
      runtime: 'libwasm+jsExports',
      srcSvelte,
      srcD: posix('src-d', dir, 'layout.d'),
      srcTs: posix('src-ts/modules/generated', identFromRel(rel) + '.ts'),
      host: '',
    }
  }
  if (base === '+error.svelte') {
    return {
      kitRel: rel,
      kind: 'error',
      cell: 'wasm',
      runtime: 'libwasm',
      srcSvelte,
      srcD: posix('src-d', dir, 'error.d'),
      srcTs: '',
      host: '',
    }
  }
  if (base.startsWith('+page.server.')) {
    return {
      kitRel: rel,
      kind: 'page_server',
      cell: 'host',
      runtime: 'vibe.0',
      srcSvelte,
      srcD: '',
      srcTs: '',
      host: posix('webserver/source/generated', dir, 'page_server.d'),
    }
  }
  if (base.startsWith('+layout.server.')) {
    return {
      kitRel: rel,
      kind: 'layout_server',
      cell: 'host',
      runtime: 'vibe.0',
      srcSvelte,
      srcD: '',
      srcTs: '',
      host: posix('webserver/source/generated', dir, 'layout_server.d'),
    }
  }
  if (base.startsWith('+server.')) {
    return {
      kitRel: rel,
      kind: 'endpoint',
      cell: 'host',
      runtime: 'vibe.0',
      srcSvelte,
      srcD: '',
      srcTs: '',
      host: posix('webserver/source/generated', dir, 'server.d'),
    }
  }
  if (base.startsWith('hooks.server.')) {
    return {
      kitRel: rel,
      kind: 'hooks',
      cell: 'host',
      runtime: 'vibe.0',
      srcSvelte,
      srcD: '',
      srcTs: '',
      host: 'webserver/source/generated/hooks.d',
    }
  }
  if (base.endsWith('.svelte')) {
    const ext = extPackageRel(rel)
    if (ext) {
      return {
        kitRel: rel,
        kind: 'ext_component',
        cell: 'wasm',
        runtime: 'libwasm+jsExports',
        srcSvelte: posix('src-svelte/ext', ext.pkg, ext.rest),
        srcD: posix('src-d/ext', ext.pkg, sanitizeDestDir(dirOf(ext.rest)), dStem(base) + '.d'),
        srcTs: posix('src-ts/modules/generated', identFromRel('ext/' + ext.pkg + '/' + ext.rest) + '.ts'),
        host: '',
      }
    }
    return {
      kitRel: rel,
      kind: 'component',
      cell: 'wasm',
      runtime: 'libwasm+jsExports',
      srcSvelte,
      srcD: posix('src-d', dir, dStem(base) + '.d'),
      srcTs: posix('src-ts/modules/generated', identFromRel(rel) + '.ts'),
      host: '',
    }
  }
  if (rel.replace(/\\/g, '/').startsWith('public/')) {
    return {
      kitRel: rel,
      kind: 'static',
      cell: 'host',
      runtime: 'vibe.0-static',
      srcSvelte: rel.replace(/\\/g, '/'),
      srcD: '',
      srcTs: '',
      host: '',
    }
  }
  if (base.endsWith('.d')) {
    return {
      kitRel: rel,
      kind: 'd',
      cell: 'wasm',
      runtime: 'libwasm',
      srcSvelte,
      srcD: posix('src-d', sanitizeDestDir(rel)),
      srcTs: '',
      host: '',
    }
  }
  if (base.endsWith('.ts') || base.endsWith('.js')) {
    return {
      kitRel: rel,
      kind: 'ts_helper',
      cell: 'wasm',
      runtime: 'src-ts',
      srcSvelte: '',
      srcD: '',
      srcTs: posix('src-ts/modules/helpers', sanitizeDestDir(rel)),
      host: '',
    }
  }
  if (base.endsWith('.scss') || base.endsWith('.sass') || base.endsWith('.css')) {
    const dest = rel.replace(/\\/g, '/').startsWith('styles/')
      ? rel.replace(/\\/g, '/')
      : posix('styles', sanitizeDestDir(rel))
    return {
      kitRel: rel,
      kind: 'style',
      cell: 'wasm',
      runtime: 'vite-css',
      srcSvelte: '',
      srcD: '',
      srcTs: dest,
      host: '',
    }
  }
  return empty()
}

function dirOf(rel: string): string {
  const s = rel.replace(/\\/g, '/')
  const i = s.lastIndexOf('/')
  return i < 0 ? '' : s.slice(0, i)
}

/** `node_modules/svelte-grid/src/Grid.svelte` or `@scope/pkg/...`. */
function extPackageRel(
  rel: string
): { pkg: string; rest: string } | null {
  let s = rel.replace(/\\/g, '/')
  if (s.startsWith('node_modules/')) s = s.slice('node_modules/'.length)
  else return null
  if (s.startsWith('@')) {
    const slash = s.indexOf('/')
    if (slash < 0) return null
    const slash2 = s.indexOf('/', slash + 1)
    if (slash2 < 0) return { pkg: s.slice(0, slash) + '/' + s.slice(slash + 1), rest: '' }
    return { pkg: s.slice(0, slash2), rest: s.slice(slash2 + 1) }
  }
  const slash = s.indexOf('/')
  if (slash < 0) return { pkg: s, rest: '' }
  return { pkg: s.slice(0, slash), rest: s.slice(slash + 1) }
}

type KitSeg = { text: string; optional: boolean }

function kitSeg(part: string): KitSeg | null {
  if (!part || part === '.') return null
  if (part.startsWith('(') && part.endsWith(')')) return null
  if (part.startsWith('[[') && part.endsWith(']]') && part.length >= 4) {
    return { text: ':' + part.slice(2, -2), optional: true }
  }
  if (part.startsWith('[') && part.endsWith(']')) {
    const inner = part.slice(1, -1)
    return { text: inner.startsWith('...') ? '*' : ':' + inner, optional: false }
  }
  return { text: part, optional: false }
}

function joinSegs(segs: string[]): string {
  return segs.length ? '/' + segs.join('/') : '/'
}

function expandOptional(parts: KitSeg[]): string[] {
  const acc: string[] = []
  const rec = (i: number, cur: string[]) => {
    if (i === parts.length) {
      acc.push(joinSegs(cur))
      return
    }
    if (parts[i].optional) {
      rec(i + 1, cur)
      rec(i + 1, [...cur, parts[i].text])
    } else rec(i + 1, [...cur, parts[i].text])
  }
  rec(0, [])
  return acc
}

function kitParts(kitRel: string): KitSeg[] | null {
  let rel = normalizeKitRel(kitRel)
  if (rel.startsWith('routes/')) rel = rel.slice('routes/'.length)
  const slash = rel.lastIndexOf('/')
  const base = slash >= 0 ? rel.slice(slash + 1) : rel
  if (base !== '+page.svelte' && base !== '+layout.svelte') return null
  const dir = slash >= 0 ? rel.slice(0, slash) : ''
  if (!dir || dir === '.') return []
  const parts: KitSeg[] = []
  for (const part of dir.split('/')) {
    const s = kitSeg(part)
    if (s) parts.push(s)
  }
  return parts
}

/** SvelteKit file → full libwasm URLRouter pattern (`[slug]` → `:slug`, `[[opt]]` → `:opt`). */
export function kitToPattern(kitRel: string): string {
  const ps = kitToPatterns(kitRel)
  return ps.length ? ps[ps.length - 1] : ''
}

/** Same path → every registration. `[[optional]]` expands to omit + include. */
export function kitToPatterns(kitRel: string): string[] {
  const parts = kitParts(kitRel)
  if (parts === null) return []
  if (!parts.length) return ['/']
  return expandOptional(parts)
}
