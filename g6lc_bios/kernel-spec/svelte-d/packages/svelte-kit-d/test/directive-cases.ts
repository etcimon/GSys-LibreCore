// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// ComboSurf class: / style: / on:|once / {...spread} / use:
// plus ComboCss / ComboForm / ComboNext dests.

export type DirectiveCase = {
  id: string
  dest: string
  needles: string[]
  note: string
}

export const DIRECTIVE_CASES: DirectiveCase[] = [
  {
    id: 'on',
    dest: 'ComboSurf',
    needles: ['@style!"on" bool on', '@style!"dir-on"'],
    note: 'class:on={on}; Ping writes this.update.on',
  },
  {
    id: 'style',
    dest: 'ComboSurf',
    needles: ['style = "color:" ~ tone', '@style!"dir-style"'],
    note: 'style:color={tone}',
  },
  {
    id: 'once',
    dest: 'ComboSurf',
    needles: ['_once_click', 'if (_once_click) return'],
    note: 'on:click|once={ping}',
  },
  {
    id: 'spread',
    dest: 'ComboSurf',
    needles: ['// spread rest', 'applySpread(rest)', '@style!"dir-spread"'],
    note: '{...rest} {...extra}',
  },
  {
    id: 'use',
    dest: 'ComboSurf',
    needles: ['focus(', '@style!"dir-use"'],
    note: 'use:focus onMount',
  },
  {
    id: 'css',
    dest: 'ComboCss',
    needles: ['applyTag(tag)', 'applySpread(rest)', ' !important'],
    note: 'ComboCss svelte:element + style:|important + spread',
  },
  {
    id: 'formonce',
    dest: 'ComboForm',
    needles: ['_once_click', 'if (_once_click) return'],
    note: 'ComboForm on:click|once',
  },
]
