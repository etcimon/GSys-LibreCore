# Names, brand, and third-party trademarks

This file states how the project is named. It grants no copyright or patent
rights; those come from `LICENSE.CERN-OHL-S` or `LICENSE.GSys-Commercial`.

**GSys is not a trademark.** `GSys`, `GSys LibreCore`, `LibreCore`, and the
GSys die legend are a **brand owned by Etienne Cimon**. They are identifiers
and an inspectability legend, not registered or common-law marks asserted by
this project.

**Multimedia Protection Inc.** is the contracting entity for the GSys Commercial
License. It does not own the GSys brand.

**GlobecSys Inc.** is a separate corporation. Its corporate name is not the GSys brand.

> Requires review by qualified counsel before publication. See `AGENTS-todo.md`.

## 1. The names

| Name | Role | Status |
|---|---|---|
| `GSys` | short brand, die legend | Brand of Etienne Cimon. **Not a trademark.** |
| `GSys LibreCore` | full product name | Brand of Etienne Cimon. **Not a trademark.** |
| `LibreCore` | reader shorthand | Brand of Etienne Cimon. **Not a trademark.** |
| GSys die legend | inspectability badge on silicon | Permission in §3 is brand/attribution use, not a trademark licence. |
| `G6LC` | code identifier prefix | Module/package/file/macro names only. **Not a trademark.** |
| `GlobecSys` | corporate name of GlobecSys Inc. | Distinct from GSys. GlobecSys Inc. is a separate corporation. |

## 2. Why a separate grant is needed

`CERN-OHL-S-2.0` §8.2 provides that You "shall not use any of the name
(including acronyms and abbreviations), image, or logo by which the Licensor or
CERN is known, except where needed to comply with section 3, or where the use is
otherwise allowed by law."

So the copyright licence alone does **not** let you put the GSys die legend on
your chip. Section 3 below permits that use of the brand — and conditions it.
That permission is not a trademark licence.

## 3. Permission to apply the GSys die legend

Etienne Cimon permits worldwide, royalty-free, non-exclusive, non-transferable
use of the **GSys brand and die legend** on a Product incorporating Covered
Source, **conditioned on all of**:

1. **Disclosure.** You satisfy `CERN-OHL-S-2.0` §4 for that Product — each
   recipient receives the Complete Source or is notified of its Source Location.
2. **Marking.** You satisfy the marking requirements of `NOTICE` §2, so the
   Source Location travels with the silicon.
3. **Reciprocity.** Modifications you Convey are licensed under
   `CERN-OHL-S-2.0` per §3.3(d).
4. **Accuracy.** You do not use the GSys brand or die legend so as to suggest
   endorsement, certification, or that Etienne Cimon or Multimedia Protection
   Inc. originated your Product or its non-LibreCore parts.
5. **Self-certification and audit.** On written request, and not more than once
   per twelve months absent good-faith suspicion of breach, you provide a
   written statement identifying the LibreCore version used, whether Covered
   Source was modified, and the Source Location at which any modifications were
   published.

The permission terminates automatically if any condition fails, and revives on
cure within 30 days, mirroring `CERN-OHL-S-2.0` §8.5.

**The die legend means one thing: this silicon is inspectable.** That is the
entire point of permitting it. Condition 5 is what makes the claim checkable,
because copyright alone gives the Licensor no audit right — `CERN-OHL-S-2.0` §6
provides none and §8.6 expressly excludes third-party beneficiary rights.

## 4. Commercial licensees

A `LICENSE.GSys-Commercial` licensee who takes marking relief
(that document, §3.3) does not receive the §3 permission, may not apply the
GSys brand or die legend to the Product, and may not describe the Product as
source-available or inspectable. Use of the GSys brand by a commercial
licensee, if any, is fixed in the executed agreement.

## 5. Permitted use without any grant

Nominative and descriptive use is unaffected. You may always, without
permission, state truthfully that a product "is based on GSys LibreCore", "is
derived from GSys LibreCore", or "is compatible with GSys LibreCore", provided
the statement is accurate and does not imply endorsement. Rewriting or removing
copyright, attribution or licence notices is never permitted — see
`CERN-OHL-S-2.0` §3.1 and Apache-2.0 §4(c).

## 6. Third-party marks — not ours to grant

Nothing here grants rights in marks we do not own.

- **`CVA6`, `CORE-V`, `OpenHW`** are marks of the **OpenHW Group**. Neither
  Apache-2.0 §6 nor Solderpad §6 grants trademark rights, which is precisely why
  this project is renamed. Do not brand a product "CVA6". Historical and factual
  references to CVA6 derivation are retained deliberately — see
  `docs/heritage.md`.
- **`RISC-V`** is a registered trademark of **RISC-V International**. Commercial
  use of the RISC-V name or logo is restricted to member organisations party to
  the RISC-V International Membership Agreement, and the "RISC-V Compatible"
  programme has been retired pending the successor certification programme.
  Membership of the party that commercially uses the RISC-V name or logo is a
  prerequisite to that use and is tracked in `AGENTS-todo.md`. That is not a
  GSys trademark claim: GSys is not a trademark.
- **`Ariane`**, **`PULP`**, and the marks of ETH Zurich, University of Bologna,
  Thales, CEA, Univ. Grenoble Alpes, Inria, TIMA, SiFive, lowRISC and PlanV
  remain with their owners.

## 7. Identification registers

Do not ship silicon claiming another vendor's identity. `mvendorid` value
`0x602` is the OpenHW Group's JEDEC identifier and `marchid` value `0x3` is
allocated to CV32A60X; neither may be used to identify a GSys LibreCore product.
A GlobecSys JEDEC manufacturer ID and a RISC-V International architecture ID are
required before commercial release, and are tracked as release blockers in
`AGENTS-todo.md`.
