// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

/** UDAs / mixins that compose a libwasm compile!() graph. */
export const domUdas = [
  'NodeDef',
  'NamedNode',
  'child',
  'prop',
  'attr',
  'style',
  'callback',
  'connect',
  'inject',
  'Slot',
  'UnorderedList',
  'HTMLArray',
  'ArrayItemEvents',
  'assignEventListeners',
  'visible',
] as const

export function extractDomUdas(src: string): string[] {
  const found: string[] = []
  const checks: [string, string][] = [
    ['NodeDef', 'mixin NodeDef'],
    ['child', '@child'],
    ['prop', '@prop'],
    ['attr', '@attr'],
    ['style', '@style'],
    ['callback', '@callback'],
    ['connect', '@connect'],
    ['inject', '@inject'],
    ['Slot', 'mixin Slot'],
    ['UnorderedList', 'UnorderedList!'],
    ['HTMLArray', 'HTMLArray'],
    ['ArrayItemEvents', 'ArrayItemEvents'],
    ['assignEventListeners', 'assignEventListeners'],
    ['visible', '@visible'],
  ]
  for (const [name, needle] of checks) {
    if (src.includes(needle) && !found.includes(name)) found.push(name)
  }
  return found
}
