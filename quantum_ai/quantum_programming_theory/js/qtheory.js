// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * QTheory — the single source of truth for the qubit model used by every figure
 * on this page. Both js/bloch.js (the animated spheres) and js/gate-figure.js
 * (the static before/after cards and the gate modal) consume this file, so the
 * physics cannot drift between them.
 *
 * Nothing here touches the DOM or three.js. Vectors are plain [x, y, z] arrays,
 * complex numbers are [re, im] pairs. Validated against textbook
 * complex-amplitude quantum mechanics by test/bloch-vs-quantum-theory.mjs.
 *
 * ── the Prime / Ortho language of the thread ──────────────────────────────
 *
 *   Prime space = |0⟩ = horizontal mode, real amplitude √P, carrier sin³(ωt)
 *   Ortho space = |1⟩ = vertical   mode, real amplitude √Q, carrier sin³(ωt+φ)
 *   P + Q = 1, φ is the relative phase (the quarter-cycle stagger)
 *
 *   r = ( 2√(PQ)·cos φ,  2√(PQ)·sin φ,  P − Q )
 *
 * which is exactly the Bloch vector of |ψ⟩ = √P|0⟩ + √Q e^{iφ}|1⟩, and also the
 * Stokes vector (S₂, S₃, S₁) of the Jones vector (√P, √Q e^{iφ}):
 *
 *   +Z = |0⟩ Prime (horizontal)     −Z = |1⟩ Ortho (vertical)
 *   ±X = ±45° linear (φ = 0, π)     ±Y = right/left circular (φ = ±π/2)
 *
 * Two corrections were needed to make the thread's own formula agree with its
 * own Bloch table; both are implemented here and explained at orthoAmp().
 */
var QTheory = (function () {
  "use strict";

  var TAU = Math.PI * 2;
  var EX = [1, 0, 0];
  var EY = [0, 1, 0];
  var EZ = [0, 0, 1];
  var H_AXIS = [Math.SQRT1_2, 0, Math.SQRT1_2];

  /* ------------------------------------------------------------- vec3 ---- */

  function vadd(a, b) { return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]; }
  function vscale(a, s) { return [a[0] * s, a[1] * s, a[2] * s]; }
  function vdot(a, b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
  function vcross(a, b) {
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
      a[0] * b[1] - a[1] * b[0]];
  }
  function vlen(a) { return Math.sqrt(vdot(a, a)); }
  function vnorm(a) {
    var l = vlen(a);
    return l > 0 ? vscale(a, 1 / l) : [0, 0, 1];
  }
  function vdist(a, b) {
    return vlen([a[0] - b[0], a[1] - b[1], a[2] - b[2]]);
  }
  function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }

  /* Rotate v about `axis` by `ang` (right-hand rule). This is the SO(3) image
     of the SU(2) gate exp(−i·ang·(n̂·σ⃗)/2). */
  function rodrigues(v, axis, ang) {
    var k = vnorm(axis);
    var c = Math.cos(ang), s = Math.sin(ang);
    return vadd(vadd(vscale(v, c), vscale(vcross(k, v), s)),
      vscale(k, vdot(k, v) * (1 - c)));
  }

  /* --------------------------------------------------------- complex ----- */

  function cadd(a, b) { return [a[0] + b[0], a[1] + b[1]]; }
  function cmul(a, b) {
    return [a[0] * b[0] - a[1] * b[1], a[0] * b[1] + a[1] * b[0]];
  }
  function cconj(a) { return [a[0], -a[1]]; }
  function cabs2(a) { return a[0] * a[0] + a[1] * a[1]; }
  function cabs(a) { return Math.sqrt(cabs2(a)); }
  function carg(a) { return Math.atan2(a[1], a[0]); }
  function cexp(t) { return [Math.cos(t), Math.sin(t)]; }
  function cscale(a, s) { return [a[0] * s, a[1] * s]; }

  /* --------------------------------------------------- the state model --- */

  function rFromPQ(P, phi) {
    var Q = 1 - P;
    var a = 2 * Math.sqrt(Math.max(0, P * Q));
    return [a * Math.cos(phi), a * Math.sin(phi), P - Q];
  }

  /* Read the Prime/Ortho split back off a Bloch vector. */
  function pqFromR(r) {
    var n = vnorm(r);
    return {
      P: clamp((1 + n[2]) / 2, 0, 1),
      Q: clamp((1 - n[2]) / 2, 0, 1),
      phi: Math.atan2(n[1], n[0]),
      theta: Math.acos(clamp(n[2], -1, 1))
    };
  }

  /* |ψ⟩ = √P|0⟩ + √Q e^{iφ}|1⟩ as [α, β]. */
  function ketFromPQ(P, phi) {
    return [[Math.sqrt(clamp(P, 0, 1)), 0],
      cscale(cexp(phi), Math.sqrt(clamp(1 - P, 0, 1)))];
  }

  /* Bloch vector of a ket, r_i = Tr(ρσ_i). */
  function rFromKet(ket) {
    var ab = cmul(cconj(ket[0]), ket[1]);
    return [2 * ab[0], 2 * ab[1], cabs2(ket[0]) - cabs2(ket[1])];
  }

  /* A displayable state: populations, phase, angles, Bloch vector.
     `phiDefined` is false at the poles, where the relative phase of a vanishing
     amplitude is meaningless and must not be printed as if it were zero. */
  function stateFromKet(ket) {
    var P = cabs2(ket[0]), Q = cabs2(ket[1]);
    var nrm = Math.sqrt(P + Q) || 1;
    var k = [cscale(ket[0], 1 / nrm), cscale(ket[1], 1 / nrm)];
    P = cabs2(k[0]); Q = cabs2(k[1]);
    var ab = cmul(cconj(k[0]), k[1]);
    var defined = cabs(k[0]) > 1e-9 && cabs(k[1]) > 1e-9;
    return {
      ket: k,
      P: clamp(P, 0, 1),
      Q: clamp(Q, 0, 1),
      phi: defined ? carg(ab) : 0,
      phiDefined: defined,
      theta: 2 * Math.atan2(Math.sqrt(clamp(Q, 0, 1)), Math.sqrt(clamp(P, 0, 1))),
      r: rFromKet(k)
    };
  }

  function stateFromPQ(P, phi) { return stateFromKet(ketFromPQ(P, phi)); }

  /* -------------------------------------------- the cycle wave function -- */

  /* Prime rides the bare cycle function; Ortho rides the same shape a relative
     phase φ later.

     Ortho is written sin³(ωt+φ) and not cos³(ωt+φ) deliberately. The thread's
     cos³ already carries a built-in quarter-cycle stagger, so charging a further
     φ onto it double-counts that quarter cycle and puts linear light on ±Y and
     circular light on ±X — the exact opposite of the "Crucial geometric fact"
     table. Absorbing the stagger into φ restores the table: φ = 0 is +45° linear
     (both modes in phase, +X) and φ = ±π/2 is right/left circular (±Y).
     Identically √Q·cos³(ωt + φ − π/2). */
  function primeAmp(P, wt) {
    var s = Math.sin(wt);
    return Math.sqrt(Math.max(0, P)) * s * s * s;
  }
  function orthoAmp(Q, wt, phi) {
    var s = Math.sin(wt + phi);
    return Math.sqrt(Math.max(0, Q)) * s * s * s;
  }

  /* Prime and Ortho are orthogonal *spatial* modes (horizontal vs vertical), so
     they do not add as scalars — √P sin³ + √Q sin³(·+φ) vanishes identically for
     −45° linear light. The meaningful scalar is the transverse field magnitude. */
  function fieldMag(P, Q, wt, phi) {
    var a = primeAmp(P, wt), b = orthoAmp(Q, wt, phi);
    return Math.sqrt(a * a + b * b);
  }

  /* Name the polarisation, per the "Crucial geometric fact" table. */
  function polName(st) {
    if (st.Q < 0.004) return "horizontal linear";
    if (st.P < 0.004) return "vertical linear";
    var bal = Math.abs(st.P - st.Q) < 0.004;
    var ph = ((st.phi % TAU) + TAU) % TAU;
    function near(a) {
      return Math.abs(((ph - a + Math.PI) % TAU + TAU) % TAU - Math.PI) < 0.02;
    }
    if (near(0)) return bal ? "+45° linear" : "elliptical · in phase";
    if (near(Math.PI)) return bal ? "−45° linear" : "elliptical · antiphase";
    if (near(Math.PI / 2)) return bal ? "right circular" : "right elliptical";
    if (near(3 * Math.PI / 2)) return bal ? "left circular" : "left elliptical";
    return "elliptical";
  }

  /* ------------------------------------------------ named basis states --- */

  var BASIS = [
    { id: "0", label: "|0⟩", note: "Prime · horizontal", P: 1, phi: 0 },
    { id: "1", label: "|1⟩", note: "Ortho · vertical", P: 0, phi: 0 },
    { id: "+", label: "|+⟩", note: "+45° linear", P: 0.5, phi: 0 },
    { id: "-", label: "|−⟩", note: "−45° linear", P: 0.5, phi: Math.PI },
    { id: "R", label: "|R⟩", note: "right circular", P: 0.5, phi: Math.PI / 2 },
    { id: "L", label: "|L⟩", note: "left circular", P: 0.5, phi: -Math.PI / 2 },
    { id: "ell", label: "elliptical", note: "P = 0.75, φ = 40°", P: 0.75, phi: 40 * Math.PI / 180 }
  ];

  function basisState(id) {
    for (var i = 0; i < BASIS.length; i++) {
      if (BASIS[i].id === id) return stateFromPQ(BASIS[i].P, BASIS[i].phi);
    }
    return stateFromPQ(1, 0);
  }

  /* Nearest named state, for labelling an outcome. */
  function nameState(st) {
    var best = null, bestD = Infinity;
    for (var i = 0; i < BASIS.length - 1; i++) {
      var d = vdist(st.r, rFromPQ(BASIS[i].P, BASIS[i].phi));
      if (d < bestD) { bestD = d; best = BASIS[i]; }
    }
    return bestD < 1e-6 ? best.label : null;
  }

  /* ----------------------------------------------------- 1-qubit gates --- */

  function m1(a, b, c, d) { return [[a, b], [c, d]]; }
  var R = function (x) { return [x, 0]; }; /* real */
  var Iu = function (x) { return [0, x]; }; /* imaginary */
  var S1 = Math.SQRT1_2;

  /* exp(−i·ang·(n̂·σ⃗)/2) as a 2×2 complex matrix. */
  function rotMatrix(n, ang) {
    var k = vnorm(n);
    var c = Math.cos(ang / 2), s = Math.sin(ang / 2);
    return m1(
      [c, -s * k[2]], [-s * k[1], -s * k[0]],
      [s * k[1], -s * k[0]], [c, s * k[2]]
    );
  }

  function applyM1(M, ket) {
    return [
      cadd(cmul(M[0][0], ket[0]), cmul(M[0][1], ket[1])),
      cadd(cmul(M[1][0], ket[0]), cmul(M[1][1], ket[1]))
    ];
  }

  /* ----------------------------------------------------- 2-qubit gates --- */
  /* Basis order |q1 q0⟩ = |00⟩, |01⟩, |10⟩, |11⟩ with q1 the control. */

  function applyM(M, vec) {
    var out = [];
    for (var i = 0; i < M.length; i++) {
      var acc = [0, 0];
      for (var j = 0; j < M.length; j++) acc = cadd(acc, cmul(M[i][j], vec[j]));
      out.push(acc);
    }
    return out;
  }

  function permMatrix(n, map) {
    var M = [];
    for (var i = 0; i < n; i++) {
      M.push([]);
      for (var j = 0; j < n; j++) M[i].push([0, 0]);
    }
    for (var k = 0; k < n; k++) M[map[k]][k] = [1, 0];
    return M;
  }

  function diagMatrix(diag) {
    var n = diag.length, M = [];
    for (var i = 0; i < n; i++) {
      M.push([]);
      for (var j = 0; j < n; j++) M[i].push(i === j ? diag[i] : [0, 0]);
    }
    return M;
  }

  /* Reduced Bloch vector of one qubit of a 2-qubit state. Its length is the
     purity of that qubit: |r| = 1 is a pure single-qubit state, |r| = 0 is
     maximally mixed, which is exactly what an entangling gate produces and what
     the thread calls "the centre of the ball". */
  function reducedBloch(vec, which) {
    /* Partial trace over the other qubit. State index is q1*2 + q0, so keeping
       q1 sums over the low bit and keeping q0 sums over the high bit.
       rho[i][j] = sum_k psi_i,k * conj(psi_j,k). */
    var rho = [[[0, 0], [0, 0]], [[0, 0], [0, 0]]];
    for (var i = 0; i < 2; i++) {
      for (var j = 0; j < 2; j++) {
        var acc = [0, 0];
        for (var k = 0; k < 2; k++) {
          var ai = which === 1 ? (i * 2 + k) : (k * 2 + i);
          var aj = which === 1 ? (j * 2 + k) : (k * 2 + j);
          acc = cadd(acc, cmul(vec[ai], cconj(vec[aj])));
        }
        rho[i][j] = acc;
      }
    }
    /* r_i = Tr(rho sigma_i); with rho_ij = psi_i psi_j* this is
       (2 Re rho01, -2 Im rho01, rho00 - rho11). The length of r is the purity
       of this qubit: 1 = pure, 0 = maximally mixed, which is what an entangling
       gate leaves behind and what the thread calls the centre of the ball. */
    return [2 * rho[0][1][0], -2 * rho[0][1][1],
      rho[0][0][0] - rho[1][1][0]];
  }

  function purity2(vec, which) { return vlen(reducedBloch(vec, which)); }

  /* --------------------------------------------------- gate registry ----- */
  /* Text fields are quoted from the thread's own tables ("Ultimate
     One-Line-Per-Gate Quantum Cheat Sheet", "Quick Reference Guide", and the
     per-gate explanations) so the figures say what the document says. */

  var GATES = {
    I: {
      id: "I", symbol: "I", name: "Identity", kind: "1q", cat: "trivial",
      axis: EZ, angle: 0, matrix: m1(R(1), R(0), R(0), R(1)),
      qiskit: "qc.id(q)", bloch: "No change — the state vector stays put.",
      c: "x = x;",
      cycle: "ψ(t) = √P sin³(ωt) + √Q sin³(ωt+φ) → unchanged",
      why: "A wire. Trivially reversible: the output determines the input.",
      demo: "+", aliases: []
    },
    X: {
      id: "X", symbol: "X", name: "Pauli-X", kind: "1q", cat: "flip",
      axis: EX, angle: Math.PI, matrix: m1(R(0), R(1), R(1), R(0)),
      qiskit: "qc.x(q)",
      bloch: "180° rotation about X: north ↔ south, |0⟩ ↔ |1⟩.",
      c: "x ^= 1;",
      cycle: "sin³(ωt) ↔ cos³(ωt) — Prime and Ortho amplitudes swap",
      why: "The quantum NOT. Bijective (0↔1), so it is its own inverse: "
        + "XOR 1 twice returns the original bit.",
      demo: "0", aliases: ["Pauli-X", "X gate", "bit flip", "bit-flip"]
    },
    Y: {
      id: "Y", symbol: "Y", name: "Pauli-Y", kind: "1q", cat: "flip",
      axis: EY, angle: Math.PI, matrix: m1(R(0), Iu(-1), Iu(1), R(0)),
      qiskit: "qc.y(q)",
      bloch: "180° rotation about Y: |0⟩ → i|1⟩, |1⟩ → −i|0⟩ — a flip that "
        + "carries a phase.",
      c: "x ^= 1; phase_flip();",
      cycle: "sin³ → i cos³,  cos³ → −i sin³",
      why: "Y = iXZ up to global phase — bit flip and phase flip at once. No "
        + "single classical instruction, because of the i.",
      demo: "0", aliases: ["Pauli-Y", "Y gate"]
    },
    Z: {
      id: "Z", symbol: "Z", name: "Pauli-Z", kind: "1q", cat: "phase",
      axis: EZ, angle: Math.PI, matrix: m1(R(1), R(0), R(0), R(-1)),
      qiskit: "qc.z(q)",
      bloch: "180° rotation about Z: the poles are fixed, the equator is "
        + "carried to its opposite point.",
      c: "if (x == 1) sign = -sign;",
      cycle: "sin³ → sin³,  cos³ → −cos³ — only the Ortho amplitude is negated",
      why: "Diagonal, so it never moves population — it only writes phase. "
        + "Invisible on |0⟩ and |1⟩, decisive on a superposition.",
      demo: "+", aliases: ["Pauli-Z", "Z gate", "phase flip", "phase-flip"]
    },
    H: {
      id: "H", symbol: "H", name: "Hadamard", kind: "1q", cat: "super",
      axis: H_AXIS, angle: Math.PI,
      matrix: m1(R(S1), R(S1), R(S1), R(-S1)),
      qiskit: "qc.h(q)",
      bloch: "180° about (x̂+ẑ)/√2 — which carries the Z pole to the X "
        + "equator, the rotation the thread calls “Z → X”.",
      c: "“try 0 and 1 at once”",
      cycle: "sin³ → (sin³ + cos³)/√2,  cos³ → (sin³ − cos³)/√2",
      why: "Creates the balanced superposition every algorithm starts from. "
        + "H² = I, so it also folds the interference back.",
      demo: "0", aliases: ["Hadamard", "H gate"]
    },
    S: {
      id: "S", symbol: "S", name: "Phase (S)", kind: "1q", cat: "phase",
      axis: EZ, angle: Math.PI / 2, matrix: m1(R(1), R(0), R(0), Iu(1)),
      qiskit: "qc.s(q)",
      bloch: "+90° rotation about Z.",
      c: "if (x == 1) phase += \u03c0/2;",
      cycle: "cos³(ωt) → i sin³(ωt) — a quarter-cycle delay on Ortho",
      why: "The quarter-wave plate. Populations are untouched; only the "
        + "Prime/Ortho stagger φ moves, turning linear light circular.",
      demo: "+", aliases: ["S gate", "phase gate"]
    },
    Sdg: {
      id: "Sdg", symbol: "S†", name: "Phase adjoint (S†)", kind: "1q", cat: "phase",
      axis: EZ, angle: -Math.PI / 2, matrix: m1(R(1), R(0), R(0), Iu(-1)),
      qiskit: "qc.sdg(q)",
      bloch: "−90° rotation about Z.",
      c: "if (x == 1) phase -= \u03c0/2;",
      cycle: "cos³(ωt) → −i sin³(ωt)",
      why: "The inverse of S; S†S = I.",
      demo: "+", aliases: ["S†", "S-dagger"]
    },
    T: {
      id: "T", symbol: "T", name: "Phase (T)", kind: "1q", cat: "phase",
      axis: EZ, angle: Math.PI / 4,
      matrix: m1(R(1), R(0), R(0), cexp(Math.PI / 4)),
      qiskit: "qc.t(q)",
      bloch: "+45° rotation about Z.",
      c: "if (x == 1) phase += \u03c0/4;",
      cycle: "cos³(ωt) → e^{iπ/4} sin³(ωt)",
      why: "The gate that makes the set universal: no amount of H and S can "
        + "produce a π/4 phase.",
      demo: "+", aliases: ["T gate"]
    },
    Tdg: {
      id: "Tdg", symbol: "T†", name: "Phase adjoint (T†)", kind: "1q", cat: "phase",
      axis: EZ, angle: -Math.PI / 4,
      matrix: m1(R(1), R(0), R(0), cexp(-Math.PI / 4)),
      qiskit: "qc.tdg(q)",
      bloch: "−45° rotation about Z.",
      c: "if (x == 1) phase -= \u03c0/4;",
      cycle: "cos³(ωt) → e^{−iπ/4} sin³(ωt)",
      why: "The inverse of T.",
      demo: "+", aliases: ["T†", "T-dagger"]
    },
    Rx: {
      id: "Rx", symbol: "Rx(θ)", name: "X rotation", kind: "1q", cat: "rot",
      axis: EX, angle: Math.PI / 2, param: true,
      qiskit: "qc.rx(θ, q)",
      bloch: "Rotation by θ about X — tilts the vector in the Y–Z plane.",
      c: "partial bit flip (no classical analogue)",
      cycle: "ψ → cos(θ/2) sin³ − i sin(θ/2) cos³",
      why: "A continuously tunable bit flip: θ = π is X. The knob variational "
        + "algorithms actually turn.",
      demo: "0", aliases: ["Rx", "RX"]
    },
    Ry: {
      id: "Ry", symbol: "Ry(θ)", name: "Y rotation", kind: "1q", cat: "rot",
      axis: EY, angle: Math.PI / 2, param: true,
      qiskit: "qc.ry(θ, q)",
      bloch: "Rotation by θ about Y — tilts the vector in the X–Z plane.",
      c: "controlled bit + phase flip",
      cycle: "ψ → cos(θ/2) sin³ + sin(θ/2) cos³",
      why: "Real-valued rotation, so it moves population with no phase — the "
        + "most common gate in QAOA and VQE.",
      demo: "0", aliases: ["Ry", "RY"]
    },
    Rz: {
      id: "Rz", symbol: "Rz(θ)", name: "Z rotation", kind: "1q", cat: "rot",
      axis: EZ, angle: Math.PI / 2, param: true,
      qiskit: "qc.rz(θ, q)",
      bloch: "Rotation by θ about Z — pure phase, the vector stays on its "
        + "latitude.",
      c: "if (x == 1) phase += θ;",
      cycle: "cos³(ωt) → e^{iθ} cos³(ωt)",
      why: "A thin glass plate. Free propagation of circular light is this "
        + "gate running continuously.",
      demo: "+", aliases: ["Rz", "RZ"]
    },

    /* ---- multi-qubit: no single-qubit Bloch picture exists ---- */
    CZ: {
      id: "CZ", symbol: "CZ", name: "Controlled-Z", kind: "nq", nq: 2,
      cat: "entangle",
      matrixN: diagMatrix([R(1), R(1), R(1), R(-1)]),
      qiskit: "qc.cz(c, t)",
      bloch: "If the control is |1⟩, apply Z to the target: |11⟩ → −|11⟩ and "
        + "nothing else moves.",
      c: "if (c && t) sign = -sign;",
      cycle: "|11⟩ → −|11⟩, all other basis terms unchanged",
      why: "Symmetric in its two qubits, and the natural gate for a photonic "
        + "beam splitter — a conditional minus sign is all it writes.",
      demo2: "+0", aliases: ["CZ", "Controlled-Z"]
    },
    CNOT: {
      id: "CNOT", symbol: "CNOT", name: "Controlled-NOT", kind: "nq", nq: 2,
      cat: "entangle",
      matrixN: permMatrix(4, [0, 1, 3, 2]),
      qiskit: "qc.cx(c, t)",
      bloch: "If the control is |1⟩, apply X to the target.",
      c: "if (c) t ^= 1;",
      cycle: "sin³_c ⊗ ψ_t → sin³_c ⊗ ψ_t;  cos³_c ⊗ ψ_t → cos³_c ⊗ Xψ_t",
      why: "Classical XOR made reversible — and, fed a superposed control, the "
        + "gate that creates a Bell pair.",
      demo2: "+0", aliases: ["CNOT", "Controlled-NOT", "CCNOT-free"]
    },
    SWAP: {
      id: "SWAP", symbol: "SWAP", name: "Swap", kind: "nq", nq: 2, cat: "wiring",
      matrixN: permMatrix(4, [0, 2, 1, 3]),
      qiskit: "qc.swap(a, b)",
      bloch: "Exchanges the two qubits — no rotation, the states change places.",
      c: "tmp = a; a = b; b = tmp;",
      cycle: "sin³_a ⊗ cos³_b ↔ cos³_a ⊗ sin³_b",
      why: "Pure wiring, but it costs three CNOTs on hardware that cannot "
        + "route arbitrarily.",
      demo2: "01", aliases: ["SWAP"]
    },
    Toffoli: {
      id: "Toffoli", symbol: "CCNOT", name: "Toffoli", kind: "nq", nq: 3,
      cat: "entangle",
      /* |q2 q1 q0⟩, q2 and q1 control, q0 target: |110⟩ ↔ |111⟩ */
      matrixN: permMatrix(8, [0, 1, 2, 3, 4, 5, 7, 6]),
      qiskit: "qc.ccx(c1, c2, t)",
      bloch: "Flips the target only when both controls are |1⟩ — one row of the "
        + "table moves, and its partner moves back.",
      c: "if (c1 && c2) t ^= 1;",
      cycle: "|110⟩ ↔ |111⟩, all six other basis terms unchanged",
      why: "Classical AND made reversible: read the target as an output and it "
        + "computes c1 ∧ c2 while keeping the inputs, so nothing is erased. "
        + "Universal for classical reversible computing, and the reason "
        + "arithmetic fits in a quantum circuit at all.",
      demo2: "110", aliases: ["Toffoli", "CCNOT", "CCX"]
    }
  };

  var GATE_ORDER = ["I", "X", "Y", "Z", "H", "S", "Sdg", "T", "Tdg",
    "Rx", "Ry", "Rz", "CZ", "CNOT", "SWAP", "Toffoli"];

  function gateList() {
    return GATE_ORDER.map(function (id) { return GATES[id]; });
  }

  /* Matrix of a gate, honouring the θ of a parametric rotation. */
  function gateMatrix(gate, angle) {
    if (gate.matrix) return gate.matrix;
    return rotMatrix(gate.axis, angle == null ? gate.angle : angle);
  }

  /* Apply a 1-qubit gate to a state, returning the new state. */
  function applyGate(gate, st, angle) {
    return stateFromKet(applyM1(gateMatrix(gate, angle), st.ket));
  }

  /* ------------------------------------------------- 2-qubit demo states - */

  /* Basis kets |q_{n-1} … q_0⟩ in index order. */
  function basisLabels(nq) {
    var out = [], n = 1 << nq;
    for (var i = 0; i < n; i++) {
      var s = "";
      for (var b = nq - 1; b >= 0; b--) s += ((i >> b) & 1);
      out.push("|" + s + "⟩");
    }
    return out;
  }

  function basisVec(nq, bits) {
    var n = 1 << nq, v = [];
    for (var i = 0; i < n; i++) v.push([0, 0]);
    v[parseInt(bits, 2)] = [1, 0];
    return v;
  }

  /* Named multi-qubit inputs. `+` marks a qubit put in superposition first,
     which is what turns CNOT from a copy into an entangler. */
  var MULTI_Q = {
    "00": { nq: 2, label: "|00⟩", vec: basisVec(2, "00") },
    "01": { nq: 2, label: "|01⟩", vec: basisVec(2, "01") },
    "10": { nq: 2, label: "|10⟩", vec: basisVec(2, "10") },
    "11": { nq: 2, label: "|11⟩", vec: basisVec(2, "11") },
    "+0": { nq: 2, label: "|+⟩⊗|0⟩", vec: [R(S1), R(0), R(S1), R(0)] },
    "++": { nq: 2, label: "|+⟩⊗|+⟩", vec: [R(0.5), R(0.5), R(0.5), R(0.5)] },
    "110": { nq: 3, label: "|110⟩", vec: basisVec(3, "110") },
    "111": { nq: 3, label: "|111⟩", vec: basisVec(3, "111") },
    "100": { nq: 3, label: "|100⟩", vec: basisVec(3, "100") },
    "++0": {
      nq: 3, label: "|+⟩⊗|+⟩⊗|0⟩",
      vec: [R(0.5), R(0), R(0.5), R(0), R(0.5), R(0), R(0.5), R(0)]
    }
  };

  function multiInputs(nq) {
    return Object.keys(MULTI_Q).filter(function (k) {
      return MULTI_Q[k].nq === nq;
    });
  }

  function applyGateN(gate, vec) { return applyM(gate.matrixN, vec); }

  /* --------------------------------------------------------- the diff ---- */

  /* What actually changed, in words and numbers. This is the substance of the
     before/after figure: a gate that writes only phase must be seen to leave
     the populations alone, and a gate that does nothing to |0⟩ must be seen to
     do nothing. */
  function diff1q(before, after) {
    var eps = 5e-7;
    var moved = vdist(before.r, after.r);
    var dP = after.P - before.P;
    var dPhi = (before.phiDefined && after.phiDefined)
      ? wrapPi(after.phi - before.phi) : null;
    var rows = [
      { key: "P", label: "P  (Prime, |0⟩)", from: fmt3(before.P), to: fmt3(after.P),
        delta: signed(dP), changed: Math.abs(dP) > eps },
      { key: "Q", label: "Q  (Ortho, |1⟩)", from: fmt3(before.Q), to: fmt3(after.Q),
        delta: signed(after.Q - before.Q), changed: Math.abs(after.Q - before.Q) > eps },
      { key: "theta", label: "θ  (polar)", from: deg(before.theta), to: deg(after.theta),
        delta: signedDeg(after.theta - before.theta),
        changed: Math.abs(after.theta - before.theta) > eps },
      { key: "phi", label: "φ  (relative phase)",
        from: before.phiDefined ? deg(before.phi) : "—",
        to: after.phiDefined ? deg(after.phi) : "—",
        delta: dPhi == null ? "—" : signedDeg(dPhi),
        changed: dPhi != null && Math.abs(dPhi) > eps },
      { key: "pol", label: "polarisation", from: polName(before), to: polName(after),
        delta: "", changed: polName(before) !== polName(after) }
    ];
    var notes = [];
    if (moved < eps) {
      notes.push("The Bloch vector does not move: this gate is invisible on "
        + "this input. Try another input state.");
    }
    if (Math.abs(dP) < eps && moved > eps) {
      notes.push("Populations unchanged — the gate wrote pure phase, so a "
        + "measurement in the |0⟩/|1⟩ basis cannot tell the difference.");
    }
    if (Math.abs(dP) > eps && dPhi != null && Math.abs(dPhi) < eps) {
      notes.push("Phase unchanged — the gate moved population only.");
    }
    return { rows: rows, moved: moved, notes: notes };
  }

  /* Wrap to (−π, +π], i.e. half-open at the *negative* end. A phase change of
     exactly π is equally +180° and −180°; reporting +180° matches how the thread
     describes Z ("180° rotation around Z") instead of contradicting it. */
  function wrapPi(d) {
    var v = ((d % TAU) + TAU) % TAU;
    return v > Math.PI ? v - TAU : v;
  }
  function fmt3(v) { return (Math.abs(v) < 5e-4 ? 0 : v).toFixed(3); }
  function signed(v) {
    if (Math.abs(v) < 5e-4) return "0";
    return (v > 0 ? "+" : "−") + Math.abs(v).toFixed(3);
  }
  function deg(rad) {
    var d = rad * 180 / Math.PI;
    d = ((d % 360) + 360) % 360;
    if (Math.abs(d) < 5e-3 || Math.abs(d - 360) < 5e-3) d = 0;
    return d.toFixed(1) + "°";
  }
  function signedDeg(rad) {
    var d = rad * 180 / Math.PI;
    if (Math.abs(d) < 5e-3) return "0°";
    return (d > 0 ? "+" : "−") + Math.abs(d).toFixed(1) + "°";
  }

  /* ------------------------------------------------- gate programmes ----- */
  /* Looping animations for js/bloch.js: each stage is a named rotation (or a
     hold) of the state vector, so the animation is a real gate sequence. */

  var PROGRAMS = {
    precess: {
      start: { P: 0.75, phi: 0 },
      stages: [{ axis: EZ, ang: TAU, dur: 7.2, name: "free propagation · Rz(ωt)" }]
    },
    hadamard: {
      start: { P: 1, phi: 0 },
      stages: [
        { hold: true, dur: 0.7, name: "|0⟩ Prime · P=1, Q=0" },
        { axis: H_AXIS, ang: Math.PI, dur: 1.7, name: "H · π about (x̂+ẑ)/√2" },
        { hold: true, dur: 1.1, name: "|+⟩ · P=Q=½, φ=0" },
        { axis: H_AXIS, ang: Math.PI, dur: 1.7, name: "H · back to |0⟩" }
      ]
    },
    rx: {
      start: { P: 1, phi: 0 },
      stages: [{ axis: EX, ang: TAU, dur: 6.4, name: "Rx(θ) · quarter+half-wave plates" }]
    },
    ry: {
      start: { P: 1, phi: 0 },
      stages: [{ axis: EY, ang: TAU, dur: 6.4, name: "Ry(θ) · rotation in the X–Z plane" }]
    },
    rz: {
      start: { P: 0.5, phi: 0 },
      stages: [{ axis: EZ, ang: TAU, dur: 6.0, name: "Rz(θ) · thin glass plate" }]
    },
    xflip: {
      start: { P: 1, phi: 0 },
      stages: [
        { hold: true, dur: 0.6, name: "|0⟩ = sin³(ωt)" },
        { axis: EX, ang: Math.PI, dur: 1.5, name: "X · swap sin³ ⇄ cos³" },
        { hold: true, dur: 0.6, name: "|1⟩ = cos³(ωt)" },
        { axis: EX, ang: Math.PI, dur: 1.5, name: "X · swap back" }
      ]
    },
    sphase: {
      start: { P: 0.5, phi: 0 },
      stages: [
        { hold: true, dur: 0.6, name: "|+⟩ · φ=0" },
        { axis: EZ, ang: Math.PI / 2, dur: 1.2, name: "S · +quarter-cycle delay" },
        { hold: true, dur: 0.8, name: "|R⟩ · φ=π/2, right circular" },
        { axis: EZ, ang: Math.PI / 2, dur: 1.2, name: "S · φ=π" },
        { hold: true, dur: 0.6, name: "|−⟩ · φ=π" },
        { axis: EZ, ang: Math.PI, dur: 1.8, name: "Z · φ back to 0" }
      ]
    }
  };

  function compileProgram(spec) {
    var stages = [];
    var r = rFromPQ(spec.start.P, spec.start.phi);
    var total = 0;
    for (var i = 0; i < spec.stages.length; i++) {
      var s = spec.stages[i];
      stages.push({
        r0: r.slice(), axis: s.axis || EZ, ang: s.hold ? 0 : s.ang,
        dur: s.dur, name: s.name, t0: total
      });
      total += s.dur;
      if (!s.hold) r = rodrigues(r, s.axis, s.ang);
    }
    return { stages: stages, total: total };
  }

  function sampleProgram(prog, t) {
    var u = ((t % prog.total) + prog.total) % prog.total;
    for (var i = 0; i < prog.stages.length; i++) {
      var s = prog.stages[i];
      if (u < s.t0 + s.dur || i === prog.stages.length - 1) {
        var f = s.dur > 0 ? clamp((u - s.t0) / s.dur, 0, 1) : 0;
        return { r: vnorm(rodrigues(s.r0, s.axis, s.ang * f)), name: s.name };
      }
    }
    return { r: prog.stages[0].r0.slice(), name: "" };
  }

  return {
    TAU: TAU, EX: EX, EY: EY, EZ: EZ, H_AXIS: H_AXIS,
    vadd: vadd, vscale: vscale, vdot: vdot, vcross: vcross, vlen: vlen,
    vnorm: vnorm, vdist: vdist, clamp: clamp, rodrigues: rodrigues,
    cadd: cadd, cmul: cmul, cconj: cconj, cabs: cabs, cabs2: cabs2,
    carg: carg, cexp: cexp, cscale: cscale,
    rFromPQ: rFromPQ, pqFromR: pqFromR, ketFromPQ: ketFromPQ,
    rFromKet: rFromKet, stateFromKet: stateFromKet, stateFromPQ: stateFromPQ,
    primeAmp: primeAmp, orthoAmp: orthoAmp, fieldMag: fieldMag,
    polName: polName, nameState: nameState,
    BASIS: BASIS, basisState: basisState,
    GATES: GATES, GATE_ORDER: GATE_ORDER, gateList: gateList,
    gateMatrix: gateMatrix, rotMatrix: rotMatrix, applyM1: applyM1,
    applyGate: applyGate,
    MULTI_Q: MULTI_Q, multiInputs: multiInputs, basisLabels: basisLabels,
    basisVec: basisVec, applyGateN: applyGateN,
    applyM: applyM, reducedBloch: reducedBloch, purity2: purity2,
    diff1q: diff1q, wrapPi: wrapPi, fmtDeg: deg, fmt3: fmt3,
    PROGRAMS: PROGRAMS, compileProgram: compileProgram,
    sampleProgram: sampleProgram
  };
})();

if (typeof module !== "undefined" && module.exports) module.exports = QTheory;
