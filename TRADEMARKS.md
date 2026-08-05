# Trademarks and the GSys die mark

This file governs use of the **GSys** marks with GSys LibreCore. It is a
trademark document. It grants no copyright or patent rights; those come from
`LICENSE.CERN-OHL-S` or `LICENSE.GSys-Commercial`.

> Requires review by qualified counsel, and a trademark clearance search on
> "LibreCore", before publication. See `AGENTS-todo.md`.

## 1. The marks

| Mark | Register | Owner |
|---|---|---|
| `GSys` | code prefix, die mark, short brand | GlobecSys Inc. |
| `GlobecSys` | corporate name | GlobecSys Inc. |
| `GSys LibreCore` | full product name | GlobecSys Inc. |
| `LibreCore` | reader shorthand | GlobecSys Inc. |
| GSys logo | figurative mark, incl. the miniature die mark | GlobecSys Inc. |

`G6LC` is the code identifier prefix. It is used in module, package, file and
macro names and is not asserted as a trademark.

## 2. Why a separate grant is needed

`CERN-OHL-S-2.0` §8.2 provides that You "shall not use any of the name
(including acronyms and abbreviations), image, or logo by which the Licensor or
CERN is known, except where needed to comply with section 3, or where the use is
otherwise allowed by law."

So the copyright licence alone does **not** let you put the GSys logo on your
chip. Section 3 below grants that affirmatively — and conditions it.

## 3. The compliance-badge grant

GlobecSys Inc. grants a worldwide, royalty-free, non-exclusive, non-transferable
licence to apply the **GSys mark and the miniature GSys die mark** to a Product
incorporating Covered Source, **conditioned on all of**:

1. **Disclosure.** You satisfy `CERN-OHL-S-2.0` §4 for that Product — each
   recipient receives the Complete Source or is notified of its Source Location.
2. **Marking.** You satisfy the marking requirements of `NOTICE` §2, so the
   Source Location travels with the silicon.
3. **Reciprocity.** Modifications you Convey are licensed under
   `CERN-OHL-S-2.0` per §3.3(d).
4. **Accuracy.** You do not use the marks so as to suggest endorsement,
   certification, or that GlobecSys Inc. or Etienne Cimon originated your
   Product or its non-LibreCore parts.
5. **Self-certification and audit.** On written request, and not more than once
   per twelve months absent good-faith suspicion of breach, you provide a
   written statement identifying the LibreCore version used, whether Covered
   Source was modified, and the Source Location at which any modifications were
   published.

The grant terminates automatically if any condition fails, and revives on cure
within 30 days, mirroring `CERN-OHL-S-2.0` §8.5.

**The mark means one thing: this silicon is inspectable.** That is the entire
point of granting it. Condition 5 is what makes the claim checkable, because
copyright alone gives the Licensor no audit right — `CERN-OHL-S-2.0` §6 provides
none and §8.6 expressly excludes third-party beneficiary rights.

## 4. Commercial licensees

A `LICENSE.GSys-Commercial` licensee who takes marking relief
(that document, §3.3) does not receive the §3 badge grant, may not apply the
GSys marks to the Product, and may not describe the Product as source-available
or inspectable. Use of the marks by a commercial licensee, if any, is fixed in
the executed agreement.

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
  GlobecSys Inc. membership is a prerequisite to commercial RISC-V branding and
  is tracked in `AGENTS-todo.md`.
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
