# AGENTS licensing policy (governance — read before editing any code)

This file governs how an agent applies **license headers, attribution, and license selection** when it
edits files in this repository. It is referenced prioritarily from `AGENTS.md` (see its section 0.4).
It is driven by three repo-root config files — `.active-contributor`, `.licensing-policy`, and
`.licensing-tiers`.

**GSys LibreCore is dual-licensed.** LibreCore-original RTL is offered under
`CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial`; tooling and docs under `MIT`; upstream material keeps
its own terms unchanged. The commercial path exists so that parties who cannot satisfy strong
reciprocity can pay instead. **That business model is only lawful if the project actually holds the
rights it purports to license — which is what most of this document exists to protect.**

## Priority

This policy is **co-equal** with the other standing workflow disciplines:

1. Keeping `agents/spec/INDEX.md` spec statuses updated.
2. Logging todos in `AGENTS-todo.md`.
3. **This licensing policy.**
4. Traceability upkeep (`AGENTS.md` §0.6).

All are applied **at most passes, depending on applicability**. A pass that edits code *must* run the
licensing pass. None of them overrides the SoC prime directive (`AGENTS.md` section 0).

## Scope — tier-directed, not in/out

The previous model had a binary in-scope/out-of-scope test that excluded all documentation. **That
model is retired.** Every file now resolves to a **tier** via `.licensing-tiers`:

| Tier | Meaning | Outbound license | Root text |
|---|---|---|---|
| **R** | LibreCore-original RTL + reference device trees | `CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial` | `LICENSE.CERN-OHL-S`, `LICENSE.GSys-Commercial` |
| **T** | build platform, timing tooling, verification scripting, docs | `MIT` | `LICENSE.MIT` |
| **U** | upstream / third-party | **unchanged — preserve verbatim** | `LICENSE`, `LICENSE.SiFive`, `LICENSE.Berkeley`, per-subtree |
| **F** | FPGA zero-stage bootrom (separate work) | `GPL-2.0-or-later` | `corev_apu/fpga/src/bootrom/LICENSE.GPL-2.0-or-later` |
| **P** | third-party NDA / foundry PDK material | `LicenseRef-Proprietary` | `LICENSE.Proprietary` |

`.licensing-tiers` resolution: **last matching glob wins**; the default rule is `U **`, so anything
unclassified is treated as someone else's property and left alone. That default is deliberate and
must not be changed.

**Markdown and documentation** (`DOCS_UNDER_TIER`) follow their tier but take **no inline header** —
the license is conveyed by the root `LICENSE.*` files plus `NOTICE`. This keeps `AGENTS*.md` and
`agents/**` under the project license without polluting them with per-file boilerplate.

## Required config files + error behavior

Before making an edit the agent MUST verify all three config files exist at the repo root:

- `.active-contributor` — one non-comment line: `Full Name <optional-email>`.
- `.licensing-policy` — directive lines; uncommenting enables a directive.
- `.licensing-tiers` — the path→tier manifest.

**Error conditions — the agent must HALT and report, never silently proceed:**

| Code | Condition |
|---|---|
| `E-NOCONTRIB` | `.active-contributor` missing → copy `.active-contributor.example` and set the name. |
| `E-NOPOLICY` | `.licensing-policy` missing → copy `.licensing-policy.example`. |
| `E-NOTIERMAP` | `TIER_DIRECTED_LICENSING` enabled but `.licensing-tiers` (`TIER_MAP`) missing. |
| `E-NOTIER` | File matches no tier rule and no fallback is enabled. |
| `E-TIERCONFLICT` | File's declared SPDX contradicts its manifest tier, **or a file declares more than one `SPDX-License-Identifier`**. |
| `E-UPSTREAMWRITE` | An edit would alter or remove a copyright line, an `SPDX-License-Identifier`, an author attribution, or `NOTICE` content in a tier-U file. |
| `E-DEMINIMIS` | A tier-R outbound license would be applied to a third-party file whose contributed delta is below `DE_MINIMIS_MIN_ADDED_LINES`. |
| `E-GPLLINK` | A GPL-headered file entered a link set outside tier F, or a GPL-2.0-only file entered any link set with Apache/CERN-OHL material. |
| `E-NOCLA` | A tier-R contribution lacks a CLA record (`CLA_REQUIRED_TIERS`). |
| `E-MULTISELECT` | More than one `SELECT_*` directive enabled. |

`E-UPSTREAMWRITE` is the most important guard in this file. Apache-2.0 §4(c) and Solderpad §4 make
notice retention a **condition** of our license to the upstream work; stripping an "ETH Zurich" or
"Thales DIS" line is a license breach, not a rebrand.

## Codebase license catalog

| License (SPDX) | Source of record | Character | Contributor protection |
|---|---|---|---|
| **`CERN-OHL-S-2.0`** | `LICENSE.CERN-OHL-S` | **Strongly reciprocal hardware** license. §4 conditions *Making and Conveying a Product* on Complete Source — reciprocity reaches the die, not just the RTL. §1.7(b)(i) requires an Available Component be a *physical part*, so proprietary soft IP cannot be excluded from Complete Source. | Strongest: royalty-free patent grant over Products (§7.1), patent retaliation (§7.2), warranty disclaimer (§6.1), liability exclusion (§6.2) |
| **`LicenseRef-GSys-Commercial`** | `LICENSE.GSys-Commercial` | Royalty-bearing closed-modification / closed-product alternative. Offer document only; rights arise on a signed agreement. | Negotiated |
| **`MIT`** | `LICENSE.MIT` | Maximally permissive software license; no patent grant. | Weak (no patent clause) |
| **Solderpad** `Apache-2.0 WITH SHL-2.1` / `SHL-2.0` / `SHL-0.51` | `LICENSE`, `core/cache_subsystem/hpdcache/LICENSE`, pervasive headers | Permissive **hardware** license wrapping Apache-2.0. SHL-2.1 §2 grants an express **sublicense** right and rights "as if the Rights did not exist"; SHL permits treating the Work as plain Apache-2.0. | Strong: Apache §3 patent grant survives (SHL replaces only §2), §7/§8 disclaimers |
| **`Apache-2.0`** | `LICENSE.SiFive` | Permissive software license. §4 final paragraph permits different terms "for any such Derivative Works as a whole" — the clause that makes outbound CERN-OHL possible. | Strong |
| **`BSD-3-Clause`** | `LICENSE.Berkeley` | Fewest obligations; **no** patent grant. | Weaker |
| **`GPL-2.0-or-later` / `GPL-2.0`** | `corev_apu/fpga/src/bootrom/LICENSE.GPL-2.0-or-later` | Copyleft. **`GPL-2.0-only` is incompatible** with Apache-2.0 and is not a CERN-OHL "Compatible Licence". | Strong copyleft |

### Outbound compatibility — why relicensing to CERN-OHL-S is lawful

Permissive→reciprocal is a **one-way street that works**, and it is explicit at both ends:

- **Inbound.** Apache-2.0 §4 final paragraph: *"You may add Your own copyright statement to Your
  modifications and may provide additional or different license terms and conditions for use,
  reproduction, or distribution of Your modifications, **or for any such Derivative Works as a
  whole**, provided Your use, reproduction, and distribution of the Work otherwise complies with the
  conditions stated in this License."* Apache has **no "no further restrictions" clause** (unlike
  GPLv2 §6), which is what permits the outbound change. SHL-2.1 §2 goes further still, granting an
  express sublicense right.
- **Outbound.** `CERN-OHL-S-2.0` §1.2(c) defines a *Compatible Licence* as one which "permits You to
  treat the Source to which it applies as licensed under CERN-OHL-S". Apache-2.0 and every Solderpad
  version qualify, so upstream files are lawful **Available Components** under §1.7(a).
- **Patents don't break.** SHL replaces only Apache §2, so Apache §3's patent grant survives and
  flows directly from each upstream Contributor to each downstream recipient, alongside CERN-OHL-S
  §7.1 from LibreCore.

**Two consequences to accept knowingly:**
1. Tier-R files can **no longer be contributed upstream** to OpenHW CVA6 unless a parallel permissive
   grant is retained.
2. Reciprocity binds **only the LibreCore delta**. Upstream CVA6 remains permissive and can always be
   fetched pristine. This is stated plainly in `LICENSE.GSys-Commercial` §4.2 rather than hidden.

## Ownership cases (apply per file, before choosing a header)

| Case | Situation | Action |
|---|---|---|
| **A** | Active contributor is **sole** copyright holder (net-new file) | Relicense freely. A copyright owner is not bound by licenses they granted to others. Any prior grant remains irrevocable for versions already published — note it, don't pretend otherwise. |
| **B** | Third-party file **substantially modified** by the contributor | Offer the *whole* under the tier-R expression per Apache §4, **retaining all upstream notices verbatim**. Add a provenance block. Requires passing the de minimis audit. |
| **C** | Third-party file, unmodified or **trivially** modified | **Tier U. Do not touch the license.** |

### The de minimis rule (`DE_MINIMIS_GUARD`)

Copyright protects original expression. Relicensing an 806-line third-party file on the strength of
39 added lines is an overreach: if the delta does not clear the originality threshold, the outbound
offer over "the whole" is unenforceable **and** misrepresents the license of someone else's work.
Under `-S`-only the entire royalty thesis rests on §4 reaching the Product, so a successful challenge
to a chokepoint file does not trim the strategy — it collapses it.

**Audit procedure** before relicensing any Case B file:

```sh
git diff --numstat <upstream-merge-base> -- <file>
git show <upstream-merge-base>:<file> | wc -l
```

Require the added-line count to exceed `DE_MINIMIS_MIN_ADDED_LINES` **and** to represent a
non-trivial fraction of the file, and record the measurement.

**Measured 2026 against upstream `a962460`:**

| File | Added | Deleted | Upstream lines | Verdict |
|---|---|---|---|---|
| `core/frontend/frontend.sv` | +347 | −12 | 557 | tier R |
| `corev_apu/src/ariane.sv` | +288 | −78 | 136 | tier R |
| `core/csr_regfile.sv` | +321 | −8 | 2979 | tier R |
| `core/perf_counters.sv` | +176 | −38 | 201 | tier R |
| `core/decoder.sv` | +127 | −26 | 1932 | tier R |
| `core/frontend/ras.sv` | +92 | −32 | 71 | tier R |
| `core/cache_subsystem/g6lc_icache.sv` | +93 | −30 | 527 | tier R |
| `core/frontend/g6lc_bp_gshare.sv` | +139 | 0 | 0 (new, `bht.sv` derivative) | tier R |
| 5× `g6lc64_*_config_pkg.sv` | +251…270 | 0 | 0 (new, Thales template derivative) | tier R |
| **`core/include/ariane_pkg.sv`** | **+39** | −7 | 806 | **EXCLUDED — de minimis (4.8%)** |
| **`corev_apu/clint/clint.sv`** | **+8** | −1 | 264 | **EXCLUDED — de minimis** |

The two exclusions are recorded in `.licensing-tiers` as tier U with a comment. **Do not "fix" them.**
`ariane_pkg.sv` is imported by nearly every module in the core, which makes it the most tempting and
the most dangerous file to over-claim.

## Resolution algorithm (per file)

1. **Tier resolve.** Match the path in `.licensing-tiers` (last match wins). No match and no
   fallback → `E-NOTIER`.
2. **Config presence.** Verify the three config files → `E-NOCONTRIB` / `E-NOPOLICY` / `E-NOTIERMAP`.
3. **Tier U gate.** If tier U: preserve the declared license verbatim. Content edits are permitted;
   license/copyright/attribution edits are `E-UPSTREAMWRITE`. Add a `Modified by:` line
   (Apache §4(b)) if `ADD_CONTRIBUTOR_NAME`.
4. **Ownership case.** Classify A / B / C. Case C ⇒ treat as tier U regardless of the manifest.
5. **De minimis.** For Case B, run the audit. Below threshold ⇒ `E-DEMINIMIS`, downgrade to tier U.
6. **Apply the tier header.** Exactly **one** `SPDX-License-Identifier` per file (`E-TIERCONFLICT`
   otherwise).
7. **Attribution.** Add the active contributor, preserving existing authors.
8. **Link-set check.** If the edit changes a compile/link set, run the GPL check (`E-GPLLINK`).

## Header conventions

**Tier R, Case A** (sole authorship):
```systemverilog
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
```

**Tier R, Case A, previously published permissively** — state it, don't erase it:
```systemverilog
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
```

**Tier R, Case B** — upstream notice block retained **verbatim and first**, *including its own
`SPDX-License-Identifier`, which must never be removed or replaced* (`E-UPSTREAMWRITE`); then a
provenance block stating the outbound offer via the **non-SPDX** `Outbound-License:` tag:
```systemverilog
// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); ... [UNCHANGED, DO NOT EDIT] ...
//
// Author: Florian Zaruba, ETH Zurich
// Modified by: Etienne Cimon
//
// ---- Licensing provenance (see LICENSE, LICENSE.CERN-OHL-S, NOTICE) ----------
// The original work of the copyright holders named above remains licensed under
// the Solderpad Hardware License as stated above, and that grant is unaffected.
// Modifications (c) 2026 Etienne Cimon: <one-line description per Apache 4(b)>.
// Etienne Cimon offers this file AS A WHOLE under the dual licence below.
// Expressed as a non-SPDX tag because SPDX has no operator for "whole is X,
// portions remain Y"; the machine-readable form is in REUSE.toml.
// Outbound-License: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
```

**Tier T**:
```typescript
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
```

**Markdown / docs**: no header. Conveyed by root `LICENSE.*` + `NOTICE`.

### SPDX expressiveness limit — and how this repo resolves it

SPDX has **no operator** for "the whole is CERN-OHL-S, portions remain Solderpad". `AND` means both
apply to the whole; `OR` means licensee's choice. Neither is accurate for Case B, and **stacking two
bare `SPDX-License-Identifier` tags in one file is ambiguous** — a scanner picks one arbitrarily.

The resolution actually in force. **Every file ends up with exactly one SPDX tag**, but which one
depends on whether the upstream notice declares an SPDX identifier at all:

1. **Upstream notice HAS an `SPDX-License-Identifier`** (the 5 Thales config packages, `SHL-2.0`):
   keep the upstream tag in its original position, untouched — removing it is `E-UPSTREAMWRITE`. The
   outbound offer is then stated as `Outbound-License:`, deliberately **not** an SPDX tag, so no
   scanner mis-reads it as the file's declared licence.
2. **Upstream notice is PROSE ONLY with no SPDX tag** (the 8 ETH Zurich / University of Bologna
   files, prose Solderpad notices): there is no upstream tag to displace, so the outbound offer *is*
   the file's single `SPDX-License-Identifier`. This is unambiguous and strictly better than prose —
   the file would otherwise carry no machine-readable licence at all. The prose upstream notice above
   it is untouched and still governs the upstream portions.
3. The **authoritative machine-readable** statement in both cases lives in **`REUSE.toml`** at the
   repo root, whose `[[annotations]]` blocks name the outbound licence, both copyright holders, and
   (in `SPDX-FileComment`) the retained upstream grant.

Never *add* an SPDX tag to a file that already has one, and never *remove* one. Case 1 and case 2 are
distinguished by inspection, not assumption.

`REUSE.toml` also pins the two **de minimis exclusions** as tier U so a scanner or a future agent
cannot silently "promote" them, and pins the GPL bootrom files including the `GPL-2.0-only` one.

Consequently the `E-TIERCONFLICT` "more than one SPDX identifier" check must be evaluated on
`SPDX-License-Identifier` tags only, and must ignore:
- `Outbound-License:` lines (not SPDX tags);
- occurrences inside **string literals of code generators** — e.g.
  `build-platform/src/tooling/motherboard.ts` and `sv-timing/crates/sv-timing-emit/src/lib.rs` emit
  headers into generated files and legitimately contain several.

## Current active configuration

Authoritative source: `.licensing-policy` and `.licensing-tiers`. **If this text ever diverges from
them, they win.**

- `.active-contributor` → **Etienne Cimon**
- `.licensing-policy` → `DEFAULT_TO_FILE_LICENSE` + `TIER_DIRECTED_LICENSING` +
  `TIER_MAP=.licensing-tiers` + `LICENSE_TIER_R=CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial` +
  `LICENSE_TIER_T=MIT` + `LICENSE_TIER_F=GPL-2.0-or-later` + `LICENSE_TIER_P=LicenseRef-Proprietary` +
  `DOCS_UNDER_TIER` + `CLA_REQUIRED_TIERS=R` + `ADD_CONTRIBUTOR_NAME` + `DE_MINIMIS_GUARD` +
  `SELECT_MOST_PERMISSIVE` (fallback).

## Invariants (must hold after any edit)

- A tier-U file's license, copyright, attribution and `NOTICE` content are **never** altered — this
  includes its `SPDX-License-Identifier`, even in a Case B file being relicensed outbound.
- Exactly **one** `SPDX-License-Identifier` tag per file (excluding code-generator string literals).
  Where the upstream notice already declares one, the Case B outbound offer uses `Outbound-License:`
  + `REUSE.toml` and never a second SPDX tag; where the upstream notice is prose-only, the outbound
  offer *is* that single tag. See "SPDX expressiveness limit" above.
- `REUSE.toml` stays in sync with `.licensing-tiers`; the de minimis exclusions are pinned in both.
- No `GPL-2.0-only` material in any link set containing Apache/CERN-OHL material; tier F stays a
  separate work and its default build stays GPL-free.
- No tier-R claim over a third-party file that fails the de minimis audit.
- Tier R contributions have a CLA record; tier T needs none.
- `CERN-OHL-S-2.0` and `GPL-2.0-or-later` license texts are **verbatim** — CERN permits use "in
  unmodified form only". Project-specific requirements go in `NOTICE` and `TRADEMARKS.md`, which is
  exactly what `CERN-OHL-S-2.0` §4 ("If specified in a Notice…") contemplates.
