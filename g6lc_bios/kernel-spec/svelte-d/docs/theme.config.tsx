// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import type { DocsThemeConfig } from 'nextra-theme-docs'

const config: DocsThemeConfig = {
  logo: (
    <span style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
      <span
        aria-hidden
        style={{
          display: 'inline-flex',
          alignItems: 'center',
          justifyContent: 'center',
          width: '1.65rem',
          height: '1.65rem',
          borderRadius: '0.5rem',
          fontSize: '0.72rem',
          fontWeight: 700,
          color: '#fff',
          background:
            'linear-gradient(135deg, hsl(18 90% 52%), hsl(32 88% 48%))',
        }}
      >
        sd
      </span>
      <span style={{ fontWeight: 650, letterSpacing: '-0.01em' }}>svelte-d</span>
    </span>
  ),
  color: {
    hue: 18,
    saturation: 88,
  },
  project: {
    link: 'https://github.com/etcimon/svelte-d',
  },
  docsRepositoryBase: 'https://github.com/etcimon/svelte-d/tree/master/docs',
  footer: {
    content: <span>MIT © {new Date().getFullYear()} Etienne Cimon</span>,
  },
  sidebar: {
    defaultMenuCollapseLevel: 1,
    toggleButton: true,
  },
  toc: {
    backToTop: true,
    title: 'On this page',
  },
  navigation: {
    prev: true,
    next: true,
  },
  darkMode: true,
  nextThemes: {
    defaultTheme: 'light',
  },
  search: {
    placeholder: 'Search svelte-d…',
  },
}

export default config
