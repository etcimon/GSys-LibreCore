// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import type { AppProps } from 'next/app'
import 'nextra-theme-docs/style.css'
import '../styles/globals.css'

export default function App({ Component, pageProps }: AppProps) {
  return <Component {...pageProps} />
}
