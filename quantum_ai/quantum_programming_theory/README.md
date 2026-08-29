# Quantum Computing conversation — HTML edition

Rebuilt from the Grok export
`148_Quantum_Computing_Qubits,_Challenges,_Progress.html`.

## Open

Open `index.html` in a browser (needs network for the KaTeX and three.js CDNs).

```
python3 -m http.server 8765 --directory .
```

## Rebuild

```
python3 build.py
```

Reads the original attachment and writes `index.html`.

## Figures

Three scripts, one physics model. `js/qtheory.js` is the **single source of
truth** — the Prime/Ortho state model, the Bloch/Stokes mapping, and the gate
registry — and the other two only draw, so the animated and static figures
cannot drift apart.

| file | what it draws |
|---|---|
| `js/qtheory.js` | no DOM, no three.js: state model + 16-gate registry. Everything below reads from it. |
| `js/bloch.js` | the animated spheres (`<div class="bloch-stage" data-demo="…">`) plus the live ψ(t) panel |
| `js/gate-figure.js` | the **static** before/after/diff cards, the gate atlases, and the click-through modal |

The state is the thread's own Prime/Ortho split, not decoration:

| | |
|---|---|
| Prime = \|0⟩ | horizontal mode, amplitude √P, `√P sin³(ωt)`, +Z |
| Ortho = \|1⟩ | vertical mode, amplitude √Q, `√Q sin³(ωt+φ)`, −Z |
| Bloch vector | `r = (2√(PQ) cos φ, 2√(PQ) sin φ, P − Q)`, so P = cos²(θ/2) |

### Animated — `js/bloch.js`

Gates are rigid rotations of `r` about the axis the thread names, run as
looping programmes: `precess` (free propagation / Rz), `hadamard` (π about
(x̂+ẑ)/√2), `rx`, `ry`, `rz`, `xflip` (Pauli-X), `sphase` (S). The panel under
each ball plots the two cycle terms, the envelope `|E| = √(Prime²+Ortho²)`,
which space owns each slice of the cycle, and the polarisation figure the pair
sweeps in the transverse plane.

### Static — `js/gate-figure.js`

Answers the other question: not *what does a qubit do* but *what did this
operation change*. Every figure is readable without watching anything.

- **Gate cards.** A dim dashed ghost for the input, a bright arrow for the
  output, an amber arc for the rotation between them, a cyan dashed line for the
  axis it turns about, and bars comparing P before/after. Laid out as an atlas by
  `atlas_for()` in `build.py`: the single-qubit set in the "Quick Reference
  Guide" chapter, the reversible multi-qubit set in the "Classical Reversible
  Operations" chapter.
- **The modal.** Opened by clicking any dotted-underlined gate name (auto-linked
  in prose and in the first column of every gate table) or a card's `open ▸`.
  Adds a selectable input state, a θ slider for Rx/Ry/Rz, the 2×2 matrix, the
  action on the basis, and a **replay/scrub** control whose animation is a
  *difference*: the ghost never moves, the arc grows, and the numbers track it.
- **Multi-qubit gates get no arrow.** CZ, CNOT, SWAP and Toffoli are drawn as a
  basis-amplitude diff instead, with each qubit's purity |r| reported before and
  after. When it falls below 1 the gate has entangled the pair and neither qubit
  has a state of its own — which is *why* the arrow picture is abandoned rather
  than stretched. CZ and CNOT on the same |+⟩⊗|0⟩ input make the contrast: one
  stays separable, one collapses both arrows to the centre of the ball.

### Validation

```
node test/bloch-vs-quantum-theory.mjs
```

Builds textbook complex-amplitude quantum mechanics from scratch — 2×2 and 2ⁿ×2ⁿ
unitaries, ρ = |ψ⟩⟨ψ|, Pauli traces, partial traces, RK4 integration of
iħ∂ₜ|ψ⟩ = H|ψ⟩, Jones vectors and Stokes parameters — and checks `qtheory.js`
against it (85 checks). The oracle self-checks first, so a bug in the reference
cannot pass the subject.

Established there: `r` is exactly the Bloch/Stokes vector of |ψ⟩ = √P|0⟩ + √Q e^{iφ}|1⟩;
`pqFromR` returns the Born-rule populations and arg(α\*β); every gate's (axis, angle)
is the true SU(2)→SO(3) image of its matrix — including the check that the arc a
figure *draws* is the same rotation its table *reports*; each programme tracks
Schrödinger evolution to ~1e-15 and stays normalised and pure; CNOT|+0⟩ is a Bell
pair with both reduced Bloch vectors at the origin.

The suite is mutation-tested: injected faults in the axis constants, gate
matrices, rotation maths, permutations, reduced-density signs and phase-wrap
convention are all caught. The only known survivors are provably *equivalent*
mutants — deleting the `acos` and P/Q clamps changes nothing, because IEEE-754
`sqrt` is correctly rounded so a normalised `|z| ≤ 1` always (checked over 2×10⁶
adversarial vectors).

Two places where the thread contradicts itself, and what the code does:

- **Pole convention.** "Crucial geometric fact" puts vertical polarisation on
  +Z, while the visual cheat-sheet puts `|0⟩ = sin³` on the north pole. The
  code follows the cheat-sheet, which is also what `r_z = P − Q` forces.
- **The Ortho carrier.** `cos³` already carries a built-in quarter-cycle
  stagger, so charging a further φ onto it double-counts that quarter cycle and
  lands linear light on ±Y and circular light on ±X — the opposite of the
  thread's own Bloch table. The stagger is absorbed into φ and Ortho is carried
  as `√Q sin³(ωt+φ) ≡ √Q cos³(ωt+φ−π/2)`, so φ = 0 is +45° linear (+X) and
  φ = ±π/2 is right/left circular (±Y). Relatedly, Prime and Ortho are
  orthogonal *spatial* modes and do not add as scalars — the naive sum
  `√P sin³ + √Q sin³(·+φ)` vanishes identically for −45° linear light — so the
  panel shows them as components of the transverse field with the `|E|`
  envelope.

One rendering bug fixed along the way: two Grover-section formulas wrote
`\text{target_cipher}`, and a bare `_` is illegal in KaTeX text mode, so with
`throwOnError: false` they rendered as red error text. `repair_math()` already
carried the correct `target\_cipher` escape but could never fire — an earlier
line renamed `\text{mCZ}` to `\mathrm{mCZ}` before the regex looking for
`\text{mCZ}` ran. Both the ordering and a general `\text{…}` underscore escape
are now in place.

## What’s in the thread

73 turns: qubit timelines (2021–2025), programmer primitives, photonic
optics, Euclidean wave pictures, QRC C interface, qRAM vs cryo-DRAM,
on-site measurement dumps, cycle-function exclusivity.
