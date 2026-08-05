# AGENTS-licensing — sv-timing package

> Companion to [`AGENTS.md`](AGENTS.md). When nested in CVA6V-EC, also honor repo-root
> `AGENTS-licensing.md`, `.active-contributor`, and `.licensing-policy`.

## First-party code

| Kind | Policy |
|---|---|
| Net-new `.rs`, `.py`, `.ts` under first-party trees | `SPDX-License-Identifier: MIT` + copyright Etienne Cimon (concise header) |
| `AGENTS*.md`, `architecture/**`, `*.md` docs | No SPDX required |
| Full proprietary text | Monorepo `LICENSE.Proprietary` when present |

## Vendored sv-parser

| Kind | Policy |
|---|---|
| `crates/sv-parser/**` | **Upstream MIT OR Apache-2.0** — never rewrite headers |
| `LICENSE.NOTICE-sv-parser` | Pointer written by vendor script |
| Patches in `patches/sv-parser/` | Keep minimal; do not relicense |

## Corrected emit

Machine-generated header on every emitted file. **Do not commit** corrected trees by default.
If a human commits one under monorepo policy, use full proprietary header.

## Agent rule

On missing monorepo licensing config while editing first-party code in a monorepo checkout:
halt and report (per root `AGENTS-licensing.md`). Standalone extracts of this package should
still keep proprietary headers consistent unless a separate project license is established.
