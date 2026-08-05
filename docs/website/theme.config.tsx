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
          fontSize: '0.85rem',
          fontWeight: 700,
          color: '#fff',
          background:
            'linear-gradient(135deg, hsl(255 72% 58%), hsl(295 72% 60%))',
        }}
      >
        G6
      </span>
      <span style={{ fontWeight: 650, letterSpacing: '-0.01em' }}>
        GSys LibreCore Docs
      </span>
    </span>
  ),
  color: {
    hue: 255,
    saturation: 72,
  },
  project: {
    link: 'https://github.com/etcimon/cva6',
  },
  chat: {
    link: 'https://github.com/etcimon/cva6/discussions',
  },
  docsRepositoryBase: 'https://github.com/etcimon/cva6/tree/master/docs/website',
  banner: {
    key: 'librecore-modern-docs',
    content: (
      <span>
        GSys LibreCore — a source-available RISC-V core and agentic build platform, derived from
        OpenHW CVA6. Explore the layered architecture.
      </span>
    ),
    dismissible: true,
  },
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
    placeholder: 'Search docs...',
  },
}

export default config
