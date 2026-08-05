# Contributing to GSys LibreCore

Thank you for considering a contribution. This document explains the one thing
that is unusual about this project — **the licensing split** — and then the
ordinary mechanics.

## 1. Read this first: the split

Which agreement you need depends entirely on *what* you touch.

| You are changing | Licence | You must sign |
|---|---|---|
| **tier T** — `build-platform/`, `sv-timing/`, `verif/` scripting, `docs/`, `corev-mb/lib/` | **MIT**, inbound = outbound | **Nothing.** Just a DCO `Signed-off-by:` line |
| **tier R** — LibreCore-original RTL and reference device trees | **CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial** | A CLA — `CLA/ICLA.md` or `CLA/ECLA.md` |
| **tier U** — upstream/third-party files | unchanged, theirs | Nothing, but see §4 |
| **tier F** — `corev_apu/fpga/src/bootrom/` | GPL-2.0-or-later | Nothing, but see §5 |

`.licensing-tiers` is the authoritative path map. `AGENTS-licensing.md` is the
governing policy.

**Most contributions are tier T and need no paperwork.** Please don't let the
CLA section deter you if you're fixing the build platform or the docs.

## 2. Why tier R needs a CLA — stated plainly

LibreCore is dual-licensed. The open path (`CERN-OHL-S-2.0`) is free for
everyone forever. The commercial path exists so that parties who cannot satisfy
strong reciprocity — typically because they integrate proprietary soft IP, or
because a foundry NDA forbids publishing PDK adaptation — can pay for a closed
licence instead. Royalties fund the work.

Selling that second licence requires holding sufficient rights in the material
being licensed. If a contribution arrived with no agreement, the project could
not include it in a commercial licence, and would have to either drop it or stop
offering the commercial path.

So the bargain, stated without euphemism:

- **You keep your copyright.** We ask for a licence, not an assignment. You may
  continue to use and relicense your own work however you wish
  (`CLA/ICLA.md` §2.1(a)).
- **You grant the right to sublicense**, which is what makes the commercial path
  possible (§2.1(b)).
- **The outbound licence is bound.** We cannot take your contribution
  proprietary-only; it must always remain available under `CERN-OHL-S-2.0`
  (§2.3). This is a promise to you, and it is the reason the CLA is not a blank
  cheque.
- **Your consideration is acknowledgement.** You are listed in `CONTRIBUTORS`.
  There is no revenue share and no other benefit (§6).

That last point is a real asymmetry: the project may earn commercial revenue on
work you contributed for free. We would rather say so here than have you
discover it later. If that trade is not acceptable to you, contribute to tier T
instead, or fork under `CERN-OHL-S-2.0` — which costs you nothing and requires
nobody's permission.

We deliberately chose a **licence** CLA over a copyright **assignment**.
Assignment is the most common reason companies refuse to upstream, and companies
upstreaming is what we want.

## 3. What happens if you just fork

Nothing bad, and no obligation to us. If you fork and Convey a Product,
`CERN-OHL-S-2.0` §3.3(d) requires your modifications to be licensed under the
same terms and §4 requires you to provide the Complete Source or its Source
Location. You owe us no fee, no notification and no CLA. Reciprocity to the
public and contribution to this repository are different things; only the latter
needs a CLA.

## 4. Touching tier U (upstream) files

Many core files belong to ETH Zurich, Thales, CEA and others. You may modify
them, but:

- **Never** alter or remove a copyright line, an `SPDX-License-Identifier`, an
  author attribution, or `NOTICE` content. Apache-2.0 §4(c) and Solderpad §4
  make retention a condition of our licence; removing them is a licence breach.
  The licensing check enforces this as `E-UPSTREAMWRITE`.
- **Do** add a `Modified by:` line stating what you changed (Apache-2.0 §4(b)).
- Prefer adding a new file over editing an upstream one. It keeps ownership
  clean and preserves our ability to rebase on upstream CVA6.

## 5. Touching tier F (the GPL bootrom)

`corev_apu/fpga/src/bootrom/` contains U-Boot-derived GPL code and is conveyed
as a **separate work**. Do not copy code out of it into `core/` or
`corev_apu/src/`, and do not add GPL-licensed files to the bootrom link set
without updating that directory's `LICENSE.GPL-2.0-or-later` and `README.md`.
The licensing check enforces this as `E-GPLLINK`.

## 6. Mechanics

1. Read `AGENTS.md` §0 — the SoC/tape-out prime directive. It is not optional
   and it is the difference between a merged patch and a rejected one.
2. Sign off every commit: `git commit -s` (Developer Certificate of Origin).
3. For tier R, submit the CLA once; it covers all future contributions.
4. Run the gates before opening a PR:
   ```
   ./build.sh verify          # lint sweep + formal + sim + synth smoke
   ./build.sh diag run        # compartmentalised diagnostics
   ```
   If your host lacks the toolchain: `./build.sh probe` then
   `./build.sh tools install sim`.
5. Update the traceability rows your change implicates — `AGENTS-specs-to-impl.md`,
   `AGENTS-specs-to-tests.md`, `AGENTS-specs-coverage.md`,
   `AGENTS-dts-validation.md`. Required by `AGENTS.md` §0.6.
6. New file? The header must match your tier. See `AGENTS-licensing.md` §Header
   convention. Do not invent a licence.

## 7. Naming

New code uses the `g6lc_` prefix. Prose says "GSys LibreCore" on first mention
and "LibreCore" thereafter. `CVA6` is retained only where it is factually
correct: upstream attribution, device-tree fallback compatible strings, upstream
CI, and heritage documentation. See `AGENTS-branding.md`.

## 8. Contact

Commercial licensing, CLA submission and trademark questions:
open an issue at the Source Location given in `NOTICE` §1, or contact the rights
holder listed in `.active-contributor`.

> Contact routing is provisional pending publication; see `AGENTS-todo.md`.
