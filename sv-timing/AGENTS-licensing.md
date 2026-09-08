# AGENTS-licensing — sv-timing package

> Companion to [`AGENTS.md`](AGENTS.md). When nested in CVA6V-EC, also honor repo-root
> `AGENTS-licensing.md`, `.active-contributor`, and `.licensing-policy`.

## First-party code

| Kind | Policy |
|---|---|
| Net-new `.rs`, `.py`, `.ts` under first-party trees | `SPDX-License-Identifier: MIT` + copyright Etienne Cimon (concise header) |
| `AGENTS*.md`, `architecture/**`, `*.md` docs | No SPDX required |
| Full proprietary text | Monorepo `LICENSE.Proprietary` when present |

## sv-parser submodule (Rust fork)

| Kind | Policy |
|---|---|
| `crates/sv-parser/**` | **MIT OR Apache-2.0** (dalance + etcimon/g6lc) — never rewrite headers, never CERN-OHL |
| `LICENSE.NOTICE-sv-parser` | Pointer written by `refresh_sv_parser.py` |
| Customizations | Land on the fork (`g6lc` branch), not as overlay patches here |

## Corrected emit

Machine-generated header on every emitted file. **Do not commit** corrected trees by default.
If a human commits one under monorepo policy, use full proprietary header.

## Agent rule

On missing monorepo licensing config while editing first-party code in a monorepo checkout:
halt and report (per root `AGENTS-licensing.md`). Standalone extracts of this package should
still keep proprietary headers consistent unless a separate project license is established.
