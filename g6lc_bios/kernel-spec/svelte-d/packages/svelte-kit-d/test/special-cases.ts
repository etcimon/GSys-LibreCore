// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// ComboSurf svelte:element / fragment / component / window / document / body
// plus ComboNext / ComboWide dests.

export type SpecialCase = {
  id: string
  dest: string
  needles: string[]
  boot?: number
  note: string
}

export const SPECIAL_CASES: SpecialCase[] = [
  {
    id: 'static',
    dest: 'ComboSurf',
    needles: ['mixin NodeDef!"section"', '@style!"spec-static"'],
    boot: 1,
    note: '<svelte:element this="section">',
  },
  {
    id: 'dyn',
    dest: 'ComboSurf',
    needles: ['applyTag(tag)', '@style!"spec-dyn"'],
    boot: 1,
    note: '<svelte:element this={tag}>',
  },
  {
    id: 'frag',
    dest: 'ComboSurf',
    needles: ['@style!"spec-frag"'],
    boot: 1,
    note: '<svelte:fragment> kids only, no wrapper',
  },
  {
    id: 'comp',
    dest: 'ComboSurf',
    needles: ['import lib.ClickField', '@child ClickField clickField'],
    note: '<svelte:component this={ClickField}>',
  },
  {
    id: 'win',
    dest: 'ComboMore',
    needles: ['on_svelte_window_keydown', 'window()'],
    note: '<svelte:window> on ComboMore',
  },
  {
    id: 'doc',
    dest: 'ComboWide',
    needles: ['on_svelte_document_visibilitychange', 'document()'],
    note: '<svelte:document> on ComboWide',
  },
  {
    id: 'body',
    dest: 'ComboWide',
    needles: ['on_svelte_body_mouseenter'],
    note: '<svelte:body> on ComboWide',
  },
  {
    id: 'next',
    dest: 'ComboNext',
    needles: ['mixin NodeDef!"section"', 'import lib.ClickField', 'focus(section0.node.handle.handle)'],
    note: 'ComboNext static element + use: + fragment + component',
  },
]
