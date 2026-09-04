// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Mirrors source/svelte_d/lodash_api.d — scan libwasm.lodash.d as text.

import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { findLibwasmRoot, findRiscvDev } from './paths.ts'

/** Representative libwasm Lodash methods exercised by lang=d fixtures. */
export const lodashCore = [
  'Lodash',
  'compact',
  'uniq',
  'map',
  'filter',
  'find',
  'join',
  'size',
  'take',
  'defaultTo',
  'attempt',
  'invoke',
  'get',
  'toLower',
  'trim',
  'execute',
] as const

export function libwasmLodashPath(root = findRiscvDev()): string {
  return join(findLibwasmRoot(root), 'source', 'libwasm', 'lodash.d')
}

export function scanLodashCatalog(src: string): string[] {
  const names = new Set<string>()
  const p = 'auto ref '
  let i = 0
  while (i < src.length) {
    const j = src.indexOf(p, i)
    if (j < 0) break
    let k = j + p.length
    const start = k
    while (k < src.length && /[A-Za-z0-9_]/.test(src[k])) k++
    if (k > start && k < src.length && src[k] === '(') {
      const name = src.slice(start, k)
      if (name !== 'initialize' && name !== 'this') names.add(name)
    }
    i = k + 1
  }
  if (src.includes('execute(')) names.add('execute')
  return [...names].sort()
}

export function loadLodashCatalog(root = findRiscvDev()): string[] {
  const p = libwasmLodashPath(root)
  if (!existsSync(p)) throw new Error('libwasm lodash.d missing at ' + p)
  return scanLodashCatalog(readFileSync(p, 'utf8'))
}

export function lodashMethodsUsed(dsrc: string, catalog: string[]): string[] {
  const used: string[] = []
  const re = /\.([A-Za-z_][A-Za-z0-9_]*)\s*[(!]/g
  let m: RegExpExecArray | null
  while ((m = re.exec(dsrc))) {
    const name = m[1]
    if (catalog.includes(name) && !used.includes(name)) used.push(name)
  }
  if (dsrc.includes('Lodash(') && !used.includes('Lodash')) used.unshift('Lodash')
  return used
}
