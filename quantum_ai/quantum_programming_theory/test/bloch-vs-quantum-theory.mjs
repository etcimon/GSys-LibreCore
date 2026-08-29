// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * Validate js/qtheory.js against textbook (complex-amplitude) quantum mechanics.
 *
 *   node test/bloch-vs-quantum-theory.mjs
 *
 * js/qtheory.js is the shared physics core behind every figure on the page: the
 * animated spheres (js/bloch.js) and the static before/after gate cards and
 * modal (js/gate-figure.js) both read from it, so validating it validates both.
 *
 * The model deliberately works in a real-valued language: a Prime/Ortho
 * population split (P, Q) plus a relative phase φ, with gates applied as
 * Rodrigues rotations of the Bloch vector. Nothing in it uses a complex number.
 * This file is the independent check that the language is nevertheless orthodox
 * quantum mechanics, so it builds the standard machinery from scratch —
 *
 *   |ψ⟩ = α|0⟩ + β|1⟩,  α,β ∈ ℂ,  |α|² + |β|² = 1
 *   ρ = |ψ⟩⟨ψ|,   r_i = Tr(ρ σ_i)
 *   gates as 2×2 unitaries,  U(n̂,a) = exp(−i a n̂·σ⃗ / 2) = cos(a/2) I − i sin(a/2) n̂·σ⃗
 *   iħ ∂|ψ⟩/∂t = H|ψ⟩ with H = (ħΩ/2) n̂·σ⃗
 *   Jones vector (α, β) → Stokes parameters → the polarisation ellipse
 *
 * — and compares. The reference implementation is self-checked first (§0), so a
 * bug in the oracle cannot silently pass the subject.
 *
 * §7 is the interesting one: the sin³/cos³ "cycle function" is a *pedagogical
 * overlay*, which the thread itself concedes. So §7 asserts only the invariants
 * the animation actually relies on (a straight figure exactly for linear light,
 * correct handedness, correct axis orientation at the cardinal phases) and
 * *measures* the deviation elsewhere instead of pretending it is zero.
 */
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SUBJECT = path.join(HERE, "..", "js", "qtheory.js");

/* ------------------------------------------------------- tiny test harness */

let failures = 0;
let checks = 0;
function section(title) {
  console.log("\n" + title);
}
function ok(name, cond, detail) {
  checks++;
  if (cond) console.log("  ok    " + name + (detail ? "   " + detail : ""));
  else {
    failures++;
    console.log("  FAIL  " + name + (detail ? "   " + detail : ""));
  }
}
function note(text) {
  console.log("        · " + text);
}

/* ------------------------------------------- §  reference implementation   */
/* Complex arithmetic. */
const C = (re, im = 0) => ({ re, im });
const cadd = (a, b) => C(a.re + b.re, a.im + b.im);
const csub = (a, b) => C(a.re - b.re, a.im - b.im);
const cmul = (a, b) => C(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re);
const cconj = (a) => C(a.re, -a.im);
const cabs2 = (a) => a.re * a.re + a.im * a.im;
const cexp = (t) => C(Math.cos(t), Math.sin(t)); /* e^{it} */
const cscale = (a, s) => C(a.re * s, a.im * s);

/* 2x2 complex matrices as [[a,b],[c,d]]. */
const mmul = (M, N) => [
  [cadd(cmul(M[0][0], N[0][0]), cmul(M[0][1], N[1][0])),
   cadd(cmul(M[0][0], N[0][1]), cmul(M[0][1], N[1][1]))],
  [cadd(cmul(M[1][0], N[0][0]), cmul(M[1][1], N[1][0])),
   cadd(cmul(M[1][0], N[0][1]), cmul(M[1][1], N[1][1]))],
];
const dagger = (M) => [
  [cconj(M[0][0]), cconj(M[1][0])],
  [cconj(M[0][1]), cconj(M[1][1])],
];
const mapply = (M, v) => [
  cadd(cmul(M[0][0], v[0]), cmul(M[0][1], v[1])),
  cadd(cmul(M[1][0], v[0]), cmul(M[1][1], v[1])),
];

const I2 = [[C(1), C(0)], [C(0), C(1)]];
const SX = [[C(0), C(1)], [C(1), C(0)]];
const SY = [[C(0), C(0, -1)], [C(0, 1), C(0)]];
const SZ = [[C(1), C(0)], [C(0), C(-1)]];

/* U(n,a) = cos(a/2) I - i sin(a/2) (n.sigma) — the SU(2) rotation by a about n. */
function rot(n, a) {
  const c = Math.cos(a / 2), s = Math.sin(a / 2);
  const nx = n[0], ny = n[1], nz = n[2];
  /* n.sigma = [[nz, nx - i ny], [nx + i ny, -nz]] */
  const ns = [[C(nz), C(nx, -ny)], [C(nx, ny), C(-nz)]];
  const out = [[C(0), C(0)], [C(0), C(0)]];
  for (let i = 0; i < 2; i++) {
    for (let j = 0; j < 2; j++) {
      const idc = cscale(I2[i][j], c);
      /* -i s (n.sigma) */
      const t = cmul(C(0, -s), ns[i][j]);
      out[i][j] = cadd(idc, t);
    }
  }
  return out;
}

/* Named gates, exactly as a textbook writes them. */
const GATES = {
  I: I2,
  X: SX,
  Y: SY,
  Z: SZ,
  H: [[C(Math.SQRT1_2), C(Math.SQRT1_2)], [C(Math.SQRT1_2), C(-Math.SQRT1_2)]],
  S: [[C(1), C(0)], [C(0), C(0, 1)]],
  T: [[C(1), C(0)], [C(0), cexp(Math.PI / 4)]],
};
/* The rotation angle each gate is claimed to be, up to global phase. The *axis*
   is deliberately not written here: it is taken from the subject's own constants
   (see AXIS below) and compared against these fixed textbook matrices, so an
   error in one of the subject's axis vectors is caught rather than assumed. */
const GATE_ANGLE = {
  I: 0,
  X: Math.PI,
  Y: Math.PI,
  Z: Math.PI,
  H: Math.PI,
  S: Math.PI / 2,
  T: Math.PI / 4,
};
/* Which of the subject's axis constants each gate must rotate about. */
const GATE_AXIS_KEY = { I: "z", X: "x", Y: "y", Z: "z", H: "h", S: "z", T: "z" };
/* Textbook reference axes, hardcoded so the programme contract in §4b does not
   depend on the subject's own constants. */
const REF_AXIS = {
  x: [1, 0, 0], y: [0, 1, 0], z: [0, 0, 1],
  h: [Math.SQRT1_2, 0, Math.SQRT1_2],
};

/* Bloch vector of a ket, via the density matrix: r_i = Tr(rho sigma_i). */
function blochFromKet(psi) {
  const [a, b] = psi;
  const ab = cmul(cconj(a), b); /* alpha* beta */
  return [2 * ab.re, 2 * ab.im, cabs2(a) - cabs2(b)];
}
/* Independent route: expectation value <psi|sigma_i|psi>. */
function expectation(psi, S) {
  const Sp = mapply(S, psi);
  const v = cadd(cmul(cconj(psi[0]), Sp[0]), cmul(cconj(psi[1]), Sp[1]));
  return v.re; /* Hermitian => real */
}
function ketFromAngles(theta, phi) {
  return [C(Math.cos(theta / 2)), cscale(cexp(phi), Math.sin(theta / 2))];
}
/* Stokes parameters of the Jones vector (alpha, beta). */
function stokes(psi) {
  const [a, b] = psi;
  const ab = cmul(cconj(a), b);
  return {
    S0: cabs2(a) + cabs2(b),
    S1: cabs2(a) - cabs2(b), /* H vs V        */
    S2: 2 * ab.re,           /* +/-45 linear  */
    S3: 2 * ab.im,           /* circular      */
  };
}

/* -------------------------------------------------- load the subject code  */
/* qtheory.js is DOM-free and three.js-free by design, so it loads in a bare
   context with no stubbing at all. */
function loadSubject() {
  const src = fs.readFileSync(SUBJECT, "utf8");
  const ctx = { Math, console, JSON, module: undefined };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(src, ctx);
  const S = ctx.QTheory;
  if (!S) throw new Error("qtheory.js did not define QTheory");
  const EXPORTS = [
    "rFromPQ", "pqFromR", "rodrigues", "primeAmp", "orthoAmp",
    "fieldMag", "polName", "compileProgram", "sampleProgram", "PROGRAMS",
    "EX", "EY", "EZ", "H_AXIS", "GATES", "GATE_ORDER", "gateMatrix",
    "applyGate", "stateFromPQ", "stateFromKet", "ketFromPQ", "rFromKet",
    "applyGateN", "reducedBloch", "MULTI_Q", "diff1q", "rotMatrix", "applyM1",
  ];
  for (const k of EXPORTS) {
    if (S[k] === undefined) {
      throw new Error("QTheory is missing '" + k + "' — was it renamed?");
    }
  }
  return S;
}

const S = loadSubject();
const TAU = Math.PI * 2;
/* QTheory speaks plain [x, y, z] arrays, so these are identities kept for
   readability at the call sites. */
const v3 = (a) => a.slice();
const arr = (v) => v.slice();
/* The subject's own axis constants. Every gate check below rotates about these
   and compares against a fixed textbook matrix, so these vectors are pinned by
   the comparison instead of being trusted. */
const AXIS = { x: arr(S.EX), y: arr(S.EY), z: arr(S.EZ), h: arr(S.H_AXIS) };
const maxAbs = (a, b) => Math.max(...a.map((x, i) => Math.abs(x - b[i])));
const wrapPi = (d) => Math.abs(((d + Math.PI) % TAU + TAU) % TAU - Math.PI);

console.log("Validating js/qtheory.js against textbook complex-amplitude QM");
console.log("subject: " + SUBJECT);

/* ======================================================================== */
section("[0] self-check the reference implementation (guard the oracle)");
{
  let worst = 0;
  for (const [name, U] of Object.entries(GATES)) {
    const P = mmul(dagger(U), U);
    worst = Math.max(worst,
      Math.abs(P[0][0].re - 1), Math.abs(P[1][1].re - 1),
      Math.abs(P[0][0].im), Math.abs(P[1][1].im),
      cabs2(P[0][1]), cabs2(P[1][0]));
    void name;
  }
  ok("every named gate is unitary (U†U = I)", worst < 1e-12,
    "max deviation " + worst.toExponential(2));

  let w2 = 0;
  for (let i = 0; i < 200; i++) {
    const n = [Math.sin(i), Math.cos(i * 1.7), Math.sin(i * 0.3)];
    const L = Math.hypot(...n);
    const nn = n.map((x) => x / L);
    const U = rot(nn, 0.3 + i * 0.017);
    const P = mmul(dagger(U), U);
    w2 = Math.max(w2, Math.abs(P[0][0].re - 1), Math.abs(P[1][1].re - 1),
      cabs2(P[0][1]), cabs2(P[1][0]));
  }
  ok("exp(−i a n·σ/2) is unitary for arbitrary (n, a)", w2 < 1e-12,
    "max deviation " + w2.toExponential(2));

  /* Two independent routes to the Bloch vector must agree. */
  let w3 = 0;
  for (let i = 0; i <= 30; i++) {
    for (let j = 0; j < 12; j++) {
      const psi = ketFromAngles((i / 30) * Math.PI, (j / 12) * TAU);
      const viaRho = blochFromKet(psi);
      const viaExp = [expectation(psi, SX), expectation(psi, SY), expectation(psi, SZ)];
      w3 = Math.max(w3, maxAbs(viaRho, viaExp));
    }
  }
  ok("Tr(ρσ) equals ⟨ψ|σ|ψ⟩", w3 < 1e-12, "max diff " + w3.toExponential(2));

  let w4 = 0;
  for (let i = 0; i <= 30; i++) {
    for (let j = 0; j < 12; j++) {
      const th = (i / 30) * Math.PI, ph = (j / 12) * TAU;
      const r = blochFromKet(ketFromAngles(th, ph));
      w4 = Math.max(w4, maxAbs(r, [
        Math.sin(th) * Math.cos(ph), Math.sin(th) * Math.sin(ph), Math.cos(th),
      ]));
    }
  }
  ok("Bloch vector of |ψ(θ,φ)⟩ is (sinθcosφ, sinθsinφ, cosθ)", w4 < 1e-12,
    "max diff " + w4.toExponential(2));
}

/* ======================================================================== */
section("[1] rFromPQ reproduces the Bloch vector of |ψ⟩ = √P|0⟩ + √Q e^{iφ}|1⟩");
{
  let worst = 0, worstAt = null;
  for (let i = 0; i <= 60; i++) {
    for (let j = 0; j < 24; j++) {
      const P = i / 60, phi = -Math.PI + (j / 24) * TAU;
      const psi = [C(Math.sqrt(P)), cscale(cexp(phi), Math.sqrt(1 - P))];
      const want = blochFromKet(psi);
      const got = arr(S.rFromPQ(P, phi));
      const e = maxAbs(got, want);
      if (e > worst) { worst = e; worstAt = { P, phi }; }
    }
  }
  ok("r = (2√(PQ)cosφ, 2√(PQ)sinφ, P−Q) == Tr(ρσ)", worst < 1e-12,
    "max diff " + worst.toExponential(2)
    + " at P=" + worstAt.P.toFixed(2) + ", φ=" + worstAt.phi.toFixed(2));
  note("the animation's real-valued split is the complex state's Bloch vector,");
  note("with no approximation — the two expressions are algebraically identical.");
}

/* ======================================================================== */
section("[2] pqFromR inverts it: Born-rule populations and the relative phase");
{
  let wP = 0, wPhi = 0;
  for (let i = 1; i < 60; i++) {
    for (let j = 0; j < 24; j++) {
      const th = (i / 60) * Math.PI, ph = -Math.PI + (j / 24) * TAU;
      const psi = ketFromAngles(th, ph);
      const st = S.pqFromR(v3(blochFromKet(psi)));
      /* Born rule: P = |<0|psi>|^2, Q = |<1|psi>|^2 */
      wP = Math.max(wP, Math.abs(st.P - cabs2(psi[0])), Math.abs(st.Q - cabs2(psi[1])));
      /* relative phase = arg(alpha* beta) */
      const ab = cmul(cconj(psi[0]), psi[1]);
      wPhi = Math.max(wPhi, wrapPi(st.phi - Math.atan2(ab.im, ab.re)));
      /* polar angle */
      wP = Math.max(wP, Math.abs(st.theta - th));
    }
  }
  ok("P = |⟨0|ψ⟩|², Q = |⟨1|ψ⟩|², θ recovered", wP < 1e-9,
    "max diff " + wP.toExponential(2));
  ok("φ = arg(α*β)", wPhi < 1e-9, "max diff " + wPhi.toExponential(2));
}

/* ======================================================================== */
section("[3] Rodrigues rotation == SU(2) evolution (the general theorem)");
{
  let worst = 0;
  for (let i = 0; i < 400; i++) {
    const n = [Math.sin(i * 1.1), Math.cos(i * 0.7), Math.sin(i * 2.3) + 0.3];
    const L = Math.hypot(...n);
    if (L < 1e-6) continue;
    const nn = n.map((x) => x / L);
    const a = -3 + (i % 40) * 0.17;
    const psi = ketFromAngles(0.2 + (i % 17) * 0.17, -2 + (i % 23) * 0.27);
    /* QM: evolve the ket, then read its Bloch vector. */
    const want = blochFromKet(mapply(rot(nn, a), psi));
    /* Subject: rotate the Bloch vector directly. */
    const got = arr(S.rodrigues(v3(blochFromKet(psi)), v3(nn), a));
    worst = Math.max(worst, maxAbs(got, want));
  }
  ok("rodrigues(r, n̂, a) == bloch(exp(−i a n̂·σ/2)|ψ⟩)", worst < 1e-12,
    "max diff " + worst.toExponential(2) + " over 400 random (n̂, a, ψ)");
  note("this is the SU(2) → SO(3) homomorphism; every gate below is a special case.");
}

/* ======================================================================== */
section("[3b] helper contracts (the defensive guards, which no gate input trips)");
{
  /* rodrigues normalises its axis, so a caller may pass an unnormalised one.
     Every call site in the animation passes a unit vector, which means the
     guard is invisible to every other check here — pin it directly. */
  let worst = 0;
  for (const scale of [0.05, 0.5, 3, 17]) {
    for (let i = 0; i < 60; i++) {
      const n = [Math.sin(i * 1.3), Math.cos(i * 0.9), Math.sin(i * 0.4) + 0.2];
      const L = Math.hypot(...n);
      const unit = n.map((x) => x / L);
      const a = -2.5 + i * 0.08;
      const r = v3(blochFromKet(ketFromAngles(0.4 + (i % 13) * 0.2, i * 0.21)));
      const viaUnit = arr(S.rodrigues(r, v3(unit), a));
      const viaScaled = arr(S.rodrigues(r, v3(unit.map((x) => x * scale)), a));
      worst = Math.max(worst, maxAbs(viaUnit, viaScaled));
    }
  }
  ok("rodrigues is invariant to axis scaling (it normalises)", worst < 1e-12,
    "max diff " + worst.toExponential(2) + " over scales 0.05–17");

  /* pqFromR clamps before acos. Feed it the poles and a dense sweep, including
     vectors whose normalisation can land just outside [-1, 1], and require
     finite in-range output rather than NaN. */
  let bad = 0, n = 0;
  const probes = [
    [0, 0, 1], [0, 0, -1], [0, 0, 1e300], [0, 0, -1e300],
    [1e-320, 0, 1], [0, 1e-320, -1],
  ];
  for (let i = 0; i <= 400; i++) {
    const t = (i / 400) * Math.PI;
    probes.push([Math.sin(t) * 1e-8, 0, Math.cos(t)]);
    probes.push([Math.sin(t), Math.cos(t) * 1e-9, Math.cos(t)]);
  }
  for (const p of probes) {
    const st = S.pqFromR(v3(p));
    n++;
    if (!Number.isFinite(st.theta) || !Number.isFinite(st.phi)
      || !Number.isFinite(st.P) || !Number.isFinite(st.Q)
      || st.P < 0 || st.P > 1 || st.Q < 0 || st.Q > 1) bad++;
  }
  ok("pqFromR never returns NaN and keeps P, Q ∈ [0,1] (acos is clamped)",
    bad === 0, n + " probes incl. the exact poles, " + bad + " bad");
  note("the acos and P/Q clamps are unreachable by construction: IEEE-754 sqrt is");
  note("  correctly rounded, so a normalised z satisfies |z| ≤ 1 exactly (checked");
  note("  over 2e6 adversarial vectors). Deleting them is an *equivalent mutant*,");
  note("  which no test can detect — they are kept as defence, not as live logic.");
}

/* ======================================================================== */
section("[4] each named gate matrix == the rotation the animation uses");
{
  /* Pin the subject's axis constants against the Pauli axes first. A π rotation
     cannot see an axis sign — R(n̂,π) = R(−n̂,π) — so the X/Y/Z gate checks below
     would pass with a flipped constant; the continuous families at the end, and
     this direct comparison, are what fix the sign. */
  for (const key of Object.keys(REF_AXIS)) {
    ok("axis constant '" + key + "' == " + JSON.stringify(REF_AXIS[key].map((v) => +v.toFixed(4))),
      maxAbs(AXIS[key], REF_AXIS[key]) < 1e-12,
      "subject has (" + AXIS[key].map((v) => v.toFixed(4)).join(", ") + ")");
  }

  for (const [name, U] of Object.entries(GATES)) {
    const a = GATE_ANGLE[name];
    const n = AXIS[GATE_AXIS_KEY[name]]; /* the subject's own constant */
    let worst = 0;
    for (let i = 0; i <= 24; i++) {
      for (let j = 0; j < 12; j++) {
        const psi = ketFromAngles((i / 24) * Math.PI, (j / 12) * TAU);
        const want = blochFromKet(mapply(U, psi));
        const got = arr(S.rodrigues(v3(blochFromKet(psi)), v3(n), a));
        worst = Math.max(worst, maxAbs(got, want));
      }
    }
    const axis = "(" + n.map((x) => x.toFixed(3)).join(", ") + ")";
    ok(name.padEnd(2) + " == rotation by " + (a * 180 / Math.PI).toFixed(0)
      + "° about " + axis, worst < 1e-12, "max diff " + worst.toExponential(2));
  }
  /* Continuous rotation families. The oracle's matrix is built from the textbook
     axis while the subject rotates about *its* constant, so an axis sign error
     shows up here even though the π-rotation checks above cannot see one. */
  for (const [name, key] of [["Rx", "x"], ["Ry", "y"], ["Rz", "z"]]) {
    let worst = 0;
    for (let i = 0; i <= 48; i++) {
      const t = (i / 48) * TAU;
      for (let j = 0; j < 8; j++) {
        const psi = ketFromAngles(0.3 + (j / 8) * 2.4, (j / 8) * TAU);
        const want = blochFromKet(mapply(rot(REF_AXIS[key], t), psi));
        const got = arr(S.rodrigues(v3(blochFromKet(psi)), v3(AXIS[key]), t));
        worst = Math.max(worst, maxAbs(got, want));
      }
    }
    ok(name + "(θ) == rotation by θ about its axis, ∀θ ∈ [0, 2π]", worst < 1e-12,
      "max diff " + worst.toExponential(2));
  }
  note("H is exp(−iπn̂·σ/2) up to the global phase i, which the Bloch vector");
  note("cannot see — so 'H = π about (x̂+ẑ)/√2' is exact, not an approximation.");
}

/* ======================================================================== */
section("[4b] each programme stage is the gate it claims to be");
{
  /* §5 below compares each programme against unitary evolution, but it reads
     the axis out of the programme itself, so it is self-consistent for *any*
     axis. This section supplies the missing constraint: the declared (axis,
     angle) of every stage must be the one the named gate requires, compared
     against REF_AXIS — the hardcoded Pauli axes — so this section does not
     depend on the subject at all. Verified by mutation: perturbing H_AXIS, an
     axis sign, an angle, or which axis a programme references fails here. */
  const CONTRACT = {
    precess: [{ axis: "z", ang: TAU }],
    hadamard: [{ hold: true }, { axis: "h", ang: Math.PI },
      { hold: true }, { axis: "h", ang: Math.PI }],
    rx: [{ axis: "x", ang: TAU }],
    ry: [{ axis: "y", ang: TAU }],
    rz: [{ axis: "z", ang: TAU }],
    xflip: [{ hold: true }, { axis: "x", ang: Math.PI },
      { hold: true }, { axis: "x", ang: Math.PI }],
    sphase: [{ hold: true }, { axis: "z", ang: Math.PI / 2 },
      { hold: true }, { axis: "z", ang: Math.PI / 2 },
      { hold: true }, { axis: "z", ang: Math.PI }],
  };
  const names = Object.keys(S.PROGRAMS);
  ok("every programme has a declared contract", names.every((n) => CONTRACT[n]),
    names.length + " programmes: " + names.join(", "));

  for (const name of names) {
    const stages = S.PROGRAMS[name].stages;
    const want = CONTRACT[name];
    let bad = [];
    if (stages.length !== want.length) bad.push("stage count");
    for (let i = 0; i < Math.min(stages.length, want.length); i++) {
      const g = stages[i], w = want[i];
      if (w.hold) {
        if (!g.hold) bad.push("stage " + i + " should be a hold");
        continue;
      }
      if (g.hold) { bad.push("stage " + i + " should rotate"); continue; }
      const axErr = maxAbs(arr(g.axis), REF_AXIS[w.axis]);
      if (axErr > 1e-12) {
        bad.push("stage " + i + " axis is (" + arr(g.axis).map((x) => x.toFixed(3))
          + "), expected " + w.axis + " = (" + REF_AXIS[w.axis].map((x) => x.toFixed(3)) + ")");
      }
      if (Math.abs(g.ang - w.ang) > 1e-12) {
        bad.push("stage " + i + " angle " + (g.ang * 180 / Math.PI).toFixed(2)
          + "°, expected " + (w.ang * 180 / Math.PI).toFixed(2) + "°");
      }
    }
    ok("'" + name + "' stages match their gate contract", bad.length === 0,
      bad.length ? bad.join("; ") : stages.length + " stages");
  }
}

/* ======================================================================== */
section("[5] gate programmes == Schrödinger evolution of the wavefunction");
{
  /* Integrate i dpsi/dt = (Omega/2)(n.sigma) psi with RK4 (hbar = 1) and compare
     the resulting Bloch trajectory with the animation's. Omega = 1, so after
     time t the state has rotated by angle t about n. */
  function tdse(psi0, n, Omega, T, steps) {
    const H = [[C(0), C(0)], [C(0), C(0)]];
    const ns = [[C(n[2]), C(n[0], -n[1])], [C(n[0], n[1]), C(-n[2])]];
    for (let i = 0; i < 2; i++) {
      for (let j = 0; j < 2; j++) H[i][j] = cscale(ns[i][j], Omega / 2);
    }
    /* dpsi/dt = -i H psi */
    const f = (p) => mapply(H, p).map((z) => cmul(C(0, -1), z));
    const addv = (p, q, s) => [cadd(p[0], cscale(q[0], s)), cadd(p[1], cscale(q[1], s))];
    let psi = psi0.slice();
    const h = T / steps;
    for (let k = 0; k < steps; k++) {
      const k1 = f(psi);
      const k2 = f(addv(psi, k1, h / 2));
      const k3 = f(addv(psi, k2, h / 2));
      const k4 = f(addv(psi, k3, h));
      psi = [
        cadd(psi[0], cscale(cadd(cadd(k1[0], cscale(k2[0], 2)),
          cadd(cscale(k3[0], 2), k4[0])), h / 6)),
        cadd(psi[1], cscale(cadd(cadd(k1[1], cscale(k2[1], 2)),
          cadd(cscale(k3[1], 2), k4[1])), h / 6)),
      ];
    }
    return psi;
  }

  /* Larmor precession: H = (Omega/2) sigma_z on an elliptical state. This is
     exactly the animation's `precess` programme. */
  {
    const P = 0.75;
    const psi0 = [C(Math.sqrt(P)), C(Math.sqrt(1 - P))];
    let worst = 0;
    for (let i = 1; i <= 24; i++) {
      const t = (i / 24) * TAU;
      const want = blochFromKet(tdse(psi0, [0, 0, 1], 1, t, 4000));
      const got = arr(S.rodrigues(v3(blochFromKet(psi0)), v3([0, 0, 1]), t));
      worst = Math.max(worst, maxAbs(got, want));
    }
    ok("TDSE under H = (ħΩ/2)σ_z traces the animation's latitude ring",
      worst < 1e-9, "max diff " + worst.toExponential(2));
  }
  /* Same for the Hadamard axis, the awkward one. */
  {
    const psi0 = [C(1), C(0)];
    const n = [Math.SQRT1_2, 0, Math.SQRT1_2];
    let worst = 0;
    for (let i = 1; i <= 24; i++) {
      const t = (i / 24) * Math.PI;
      const want = blochFromKet(tdse(psi0, n, 1, t, 4000));
      const got = arr(S.rodrigues(v3([0, 0, 1]), v3(n), t));
      worst = Math.max(worst, maxAbs(got, want));
    }
    ok("TDSE about (x̂+ẑ)/√2 traces the animation's H sweep", worst < 1e-9,
      "max diff " + worst.toExponential(2));
  }

  /* Now the compiled programmes themselves: walk each one and check every
     sampled instant against a ket evolved by the equivalent unitaries. */
  for (const name of Object.keys(S.PROGRAMS)) {
    const spec = S.PROGRAMS[name];
    const prog = S.compileProgram(spec);
    /* Rebuild the initial ket from the programme's declared (P, phi). */
    let psi = [C(Math.sqrt(spec.start.P)),
      cscale(cexp(spec.start.phi), Math.sqrt(1 - spec.start.P))];
    let worst = 0;
    let t0 = 0;
    for (const st of spec.stages) {
      const n = st.axis ? arr(st.axis) : [0, 0, 1];
      const ang = st.hold ? 0 : st.ang;
      for (let s = 0; s <= 8; s++) {
        const f = s / 8;
        /* Sample the subject at exactly the instant the oracle evolves to. The
           state is continuous across a stage boundary, so f = 1 is safe. */
        const tGlobal = t0 + f * st.dur;
        const want = blochFromKet(mapply(rot(n, ang * f), psi));
        const got = arr(S.sampleProgram(prog, tGlobal).r);
        worst = Math.max(worst, maxAbs(got, want));
      }
      psi = mapply(rot(n, ang), psi);
      t0 += st.dur;
    }
    /* And the loop must close as a physical state, not merely as a vector. */
    const closes = maxAbs(blochFromKet(psi), arr(S.sampleProgram(prog, 0).r));
    ok("programme '" + name + "' matches unitary evolution throughout",
      worst < 1e-8 && closes < 1e-8,
      "max diff " + worst.toExponential(2) + ", loop closes to " + closes.toExponential(2));
  }
}

/* ======================================================================== */
section("[6] Stokes parameters: the ball is the Poincaré sphere of the thread's table");
{
  /* The animation's axes are X = +/-45 linear, Y = circular, Z = H/V, so its
     Bloch vector should be the Stokes vector reordered as (S2, S3, S1). */
  let worst = 0;
  for (let i = 0; i <= 40; i++) {
    for (let j = 0; j < 16; j++) {
      const P = i / 40, phi = -Math.PI + (j / 16) * TAU;
      const psi = [C(Math.sqrt(P)), cscale(cexp(phi), Math.sqrt(1 - P))];
      const s = stokes(psi);
      worst = Math.max(worst, Math.abs(s.S0 - 1),
        maxAbs(arr(S.rFromPQ(P, phi)), [s.S2, s.S3, s.S1]));
    }
  }
  ok("r == (S₂, S₃, S₁) and S₀ = 1 (fully polarised, pure state)", worst < 1e-12,
    "max diff " + worst.toExponential(2));

  /* The six cardinal points, against the "Crucial geometric fact" table. */
  const TABLE = [
    ["+Z  |0⟩ Prime", 1.0, 0, "horizontal linear", { S1: +1 }],
    ["−Z  |1⟩ Ortho", 0.0, 0, "vertical linear", { S1: -1 }],
    ["+X  |+⟩", 0.5, 0, "+45° linear", { S2: +1 }],
    ["−X  |−⟩", 0.5, Math.PI, "−45° linear", { S2: -1 }],
    ["+Y  |R⟩", 0.5, Math.PI / 2, "right circular", { S3: +1 }],
    ["−Y  |L⟩", 0.5, -Math.PI / 2, "left circular", { S3: -1 }],
  ];
  for (const [label, P, phi, wantName, wantStokes] of TABLE) {
    const psi = [C(Math.sqrt(P)), cscale(cexp(phi), Math.sqrt(1 - P))];
    const s = stokes(psi);
    const key = Object.keys(wantStokes)[0];
    const stokesOk = Math.abs(s[key] - wantStokes[key]) < 1e-12;
    const gotName = S.polName(S.pqFromR(S.rFromPQ(P, phi)));
    ok(label.padEnd(15) + " → " + wantName,
      stokesOk && gotName === wantName,
      key + " = " + s[key].toFixed(0) + ", polName = '" + gotName + "'");
  }
}

/* ======================================================================== */
section("[7] cycle function vs the true Maxwell field (where the overlay holds)");
{
  /* The physical field of a Jones vector is E(t) = Re[(alpha, beta) e^{i w t}].
     The animation instead draws (sqrtP sin^3(wt), sqrtQ sin^3(wt + phi)). Both
     curves are compared as geometric figures: signed area (handedness and
     degeneracy) and second-moment orientation (the polarisation azimuth). */
  const N = 2000;
  function curve(pts) {
    let area = 0, mxx = 0, myy = 0, mxy = 0, minR = Infinity, maxR = 0;
    for (let i = 0; i < N; i++) {
      const [x, y] = pts[i];
      const [x2, y2] = pts[(i + 1) % N];
      area += x * y2 - x2 * y;
      mxx += x * x; myy += y * y; mxy += x * y;
      const R = Math.hypot(x, y);
      minR = Math.min(minR, R); maxR = Math.max(maxR, R);
    }
    mxx /= N; myy /= N; mxy /= N;
    /* principal axis azimuth from the second-moment matrix. `anisotropy` is the
       magnitude of the traceless part: it vanishes for a circular figure, whose
       azimuth is undefined, so a comparison must be skipped there rather than
       reading noise out of atan2 on denormals. */
    const azim = 0.5 * Math.atan2(2 * mxy, mxx - myy);
    const anisotropy = Math.hypot(mxx - myy, 2 * mxy) / (mxx + myy);
    return { area: area / 2, azim, anisotropy, minR, maxR };
  }
  /* Phase convention. The thread fixes it explicitly: at +Y the "Real part lags
     Imaginary part by exactly 90°", i.e. Prime lags Ortho, so Ortho *leads* by
     φ — which is what orthoAmp does. The matching Maxwell field is
     E(t) = Re[J e^{+iωt}], so E_ortho = √Q cos(ωt + φ). The oracle adopts that
     convention so the two are compared like for like. Under the opposite
     convention (e^{−iωt}, Ortho lagging) *both* circulations flip together, so
     every relative statement below is unchanged; only the absolute names
     "right"/"left" would swap, and those are the thread's to choose. */
  function trueField(P, phi) {
    const a = Math.sqrt(P), b = Math.sqrt(1 - P);
    const pts = [];
    for (let i = 0; i < N; i++) {
      const w = (i / N) * TAU;
      pts.push([a * Math.cos(w), b * Math.cos(w + phi)]);
    }
    return curve(pts);
  }
  function modelField(P, phi) {
    const pts = [];
    for (let i = 0; i < N; i++) {
      const w = (i / N) * TAU;
      pts.push([S.primeAmp(P, w), S.orthoAmp(1 - P, w, phi)]);
    }
    return curve(pts);
  }

  /* (a) Degeneracy: the figure collapses to a line exactly for linear light,
         i.e. exactly when S3 = 0. This is the property the animation's inset
         is read for, so it must be exact. */
  let bad = 0, checked = 0;
  for (let i = 1; i < 20; i++) {
    for (let j = 0; j < 16; j++) {
      const P = i / 20, phi = -Math.PI + (j / 16) * TAU;
      const S3 = stokes([C(Math.sqrt(P)), cscale(cexp(phi), Math.sqrt(1 - P))]).S3;
      const linear = Math.abs(S3) < 1e-12;
      const t = trueField(P, phi), m = modelField(P, phi);
      const tLine = Math.abs(t.area) < 1e-9, mLine = Math.abs(m.area) < 1e-9;
      checked++;
      if (tLine !== linear || mLine !== linear) bad++;
    }
  }
  ok("figure is degenerate ⟺ S₃ = 0, for both the true and model field",
    bad === 0, checked + " states, " + bad + " mismatches");

  /* (b) Handedness. Two statements, and only the second is convention-free.
         (i)  the model circulates the same way as the true field, in the
              convention the thread fixes — so the overlay does not invert
              handedness relative to Maxwell;
         (ii) |R⟩ and |L⟩ circulate oppositely, which no convention can change
              and is what makes the two poles physically distinct. */
  let hbad = 0, hchecked = 0;
  for (let i = 1; i < 20; i++) {
    for (let j = 0; j < 16; j++) {
      const P = i / 20, phi = -Math.PI + (j / 16) * TAU;
      const S3 = stokes([C(Math.sqrt(P)), cscale(cexp(phi), Math.sqrt(1 - P))]).S3;
      if (Math.abs(S3) < 1e-3) continue; /* linear: no circulation to compare */
      const t = trueField(P, phi), m = modelField(P, phi);
      hchecked++;
      if (Math.sign(m.area) !== Math.sign(t.area)) hbad++;
    }
  }
  ok("model circulates like the true field (overlay preserves handedness)",
    hbad === 0, hchecked + " elliptical states, " + hbad + " mismatches");

  const R = modelField(0.5, Math.PI / 2), L = modelField(0.5, -Math.PI / 2);
  const tR = trueField(0.5, Math.PI / 2), tL = trueField(0.5, -Math.PI / 2);
  ok("|R⟩ and |L⟩ circulate oppositely, in both model and true field",
    Math.sign(R.area) === -Math.sign(L.area)
    && Math.sign(tR.area) === -Math.sign(tL.area)
    && Math.sign(R.area) === Math.sign(tR.area),
    "model " + R.area.toFixed(3) + " / " + L.area.toFixed(3)
    + ", true " + tR.area.toFixed(3) + " / " + tL.area.toFixed(3));
  note("the absolute names follow the thread's stated convention (+Y = right,");
  note("  \"clockwise looking toward the source\"); under e^{−iωt} both signs");
  note("  flip together and the two poles simply exchange names.");

  /* (c) Azimuth: the standard result is tan(2ψ) = S₂/S₁. The model's cube
         envelope reproduces it wherever cos3φ = cosφ, i.e. at the cardinal
         phases. Assert there; measure elsewhere.

         A circular figure has no azimuth — its second-moment matrix is
         isotropic — so those states are skipped rather than compared. Without
         the guard the comparison reads atan2 noise off two ~1e-16 quantities
         and reports a spurious few degrees. */
  const AZIM_MIN_ANISOTROPY = 1e-6;
  let cardinalWorst = 0, cardinalN = 0, skipped = 0;
  for (const phi of [0, Math.PI / 2, Math.PI, -Math.PI / 2]) {
    for (let i = 1; i < 20; i++) {
      const P = i / 20;
      const t = trueField(P, phi), m = modelField(P, phi);
      if (t.anisotropy < AZIM_MIN_ANISOTROPY || m.anisotropy < AZIM_MIN_ANISOTROPY) {
        skipped++;
        continue;
      }
      cardinalN++;
      cardinalWorst = Math.max(cardinalWorst, wrapPi(2 * (m.azim - t.azim)) / 2);
    }
  }
  ok("polarisation azimuth exact at φ ∈ {0, ±π/2, π}", cardinalWorst < 1e-6,
    cardinalN + " states, max error "
    + (cardinalWorst * 180 / Math.PI).toExponential(2) + "°, "
    + skipped + " circular (azimuth undefined) skipped");

  let genWorst = 0, genAt = null;
  for (let i = 1; i < 20; i++) {
    for (let j = 0; j < 32; j++) {
      const P = i / 20, phi = -Math.PI + (j / 32) * TAU;
      const t = trueField(P, phi), m = modelField(P, phi);
      if (t.anisotropy < AZIM_MIN_ANISOTROPY) continue;
      const e = wrapPi(2 * (m.azim - t.azim)) / 2;
      if (e > genWorst) { genWorst = e; genAt = { P, phi }; }
    }
  }
  note("at intermediate phases the cube envelope tilts the azimuth by up to "
    + (genWorst * 180 / Math.PI).toFixed(2) + "°");
  note("  (worst at P=" + genAt.P.toFixed(2) + ", φ="
    + (genAt.phi * 180 / Math.PI).toFixed(0) + "°) — a known property of the");
  note("  sin³/cos³ overlay, which the thread's own corrigenda flags as");
  note("  pedagogical rather than the chip's native basis.");

  /* (d) Amplitude fidelity: for circular light the true |E| is constant. The
         cube model's is not — quantify rather than assert. */
  const tc = trueField(0.5, Math.PI / 2), mc = modelField(0.5, Math.PI / 2);
  ok("true |E| is constant for circular light (oracle sanity)",
    (tc.maxR - tc.minR) / tc.maxR < 1e-3,
    "ripple " + (100 * (tc.maxR - tc.minR) / tc.maxR).toFixed(3) + "%");
  note("model |E| for the same state varies by "
    + (100 * (mc.maxR - mc.minR) / mc.maxR).toFixed(1)
    + "% — this is why the panel plots |E| as an envelope");
  note("  rather than claiming a constant-amplitude circular field.");

  /* (e) fieldMag must be the Euclidean norm of the two components. */
  let fm = 0;
  for (let i = 0; i <= 40; i++) {
    const w = (i / 40) * TAU, P = 0.35, phi = 0.8;
    const a = S.primeAmp(P, w), b = S.orthoAmp(1 - P, w, phi);
    fm = Math.max(fm, Math.abs(S.fieldMag(P, 1 - P, w, phi) - Math.hypot(a, b)));
  }
  ok("fieldMag == √(Prime² + Ortho²)", fm < 1e-15, "max diff " + fm.toExponential(2));
}

/* ======================================================================== */
section("[8] conservation laws over a whole programme");
{
  for (const name of Object.keys(S.PROGRAMS)) {
    const prog = S.compileProgram(S.PROGRAMS[name]);
    let wNorm = 0, wPurity = 0;
    for (let i = 0; i <= 300; i++) {
      const r = S.sampleProgram(prog, (i / 300) * prog.total).r;
      const st = S.pqFromR(r);
      wNorm = Math.max(wNorm, Math.abs(st.P + st.Q - 1));
      /* purity Tr(rho^2) = (1 + |r|^2)/2 must stay 1 under unitary evolution */
      wPurity = Math.max(wPurity, Math.abs((1 + S.vdot(r, r)) / 2 - 1));
    }
    ok("'" + name + "': ⟨ψ|ψ⟩ = 1 and Tr(ρ²) = 1 (unitary, stays pure)",
      wNorm < 1e-9 && wPurity < 1e-9,
      "norm " + wNorm.toExponential(1) + ", purity " + wPurity.toExponential(1));
  }
}

/* ======================================================================== */
section("[9] the gate registry the figures render from");
{
  /* Two unitaries are the same gate iff they agree up to a global phase, which
     for 2x2 means |Tr(U†G)| = 2. This is the check that matters most for the
     figures: the registry's *matrix* produces the after-state numbers while its
     *(axis, angle)* draws the rotation arc, so if the two disagreed the picture
     would contradict the table beside it. */
  function traceDaggerProduct(U, G) {
    let t = C(0);
    for (let i = 0; i < 2; i++) {
      for (let k = 0; k < 2; k++) t = cadd(t, cmul(cconj(U[k][i]), G[k][i]));
    }
    return t;
  }
  const toC = (m) => m.map((row) => row.map(([re, im]) => C(re, im)));

  /* Independently written textbook rotation families (not QTheory's rotMatrix,
     which would make the comparison a tautology). */
  const REF = {
    Rx: (t) => [[C(Math.cos(t / 2)), C(0, -Math.sin(t / 2))],
      [C(0, -Math.sin(t / 2)), C(Math.cos(t / 2))]],
    Ry: (t) => [[C(Math.cos(t / 2)), C(-Math.sin(t / 2))],
      [C(Math.sin(t / 2)), C(Math.cos(t / 2))]],
    Rz: (t) => [[cexp(-t / 2), C(0)], [C(0), cexp(t / 2)]],
  };
  const FIXED = { I: GATES.I, X: GATES.X, Y: GATES.Y, Z: GATES.Z, H: GATES.H,
    S: GATES.S, T: GATES.T,
    Sdg: [[C(1), C(0)], [C(0), C(0, -1)]],
    Tdg: [[C(1), C(0)], [C(0), cexp(-Math.PI / 4)]] };

  const oneQ = S.GATE_ORDER.filter((id) => S.GATES[id].kind === "1q");
  let unit = 0;
  for (const id of oneQ) {
    const g = S.GATES[id];
    for (const th of [g.angle, 0.3, 1.1, -2.2]) {
      const U = toC(S.gateMatrix(g, g.param ? th : undefined));
      const P = mmul(dagger(U), U);
      unit = Math.max(unit, Math.abs(P[0][0].re - 1), Math.abs(P[1][1].re - 1),
        cabs2(P[0][1]), cabs2(P[1][0]));
      if (!g.param) break;
    }
  }
  ok("every registry matrix is unitary", unit < 1e-12,
    oneQ.length + " single-qubit gates, max deviation " + unit.toExponential(2));

  /* registry matrix == the textbook gate it is named after */
  let worstNamed = 0;
  for (const id of Object.keys(FIXED)) {
    const U = toC(S.gateMatrix(S.GATES[id]));
    const fid = Math.abs(Math.hypot(...Object.values(
      traceDaggerProduct(U, FIXED[id])))) / 2;
    const okd = Math.abs(fid - 1) < 1e-12;
    worstNamed = Math.max(worstNamed, Math.abs(fid - 1));
    if (!okd) ok("registry " + id + " == textbook " + id, false, "fidelity " + fid);
  }
  ok("registry I,X,Y,Z,H,S,T,S†,T† == their textbook matrices (up to phase)",
    worstNamed < 1e-12, "max |fidelity−1| = " + worstNamed.toExponential(2));

  let worstRot = 0;
  for (const id of ["Rx", "Ry", "Rz"]) {
    for (let i = 0; i <= 32; i++) {
      const t = -Math.PI + (i / 32) * TAU;
      const U = toC(S.gateMatrix(S.GATES[id], t));
      const f = Math.hypot(...Object.values(traceDaggerProduct(U, REF[id](t)))) / 2;
      worstRot = Math.max(worstRot, Math.abs(f - 1));
    }
  }
  ok("registry Rx(θ), Ry(θ), Rz(θ) == their textbook matrices, ∀θ",
    worstRot < 1e-12, "max |fidelity−1| = " + worstRot.toExponential(2));

  /* The (axis, angle) that draws the arc must be the same rotation. */
  let worstArc = 0, arcBad = [];
  for (const id of oneQ) {
    const g = S.GATES[id];
    let w = 0;
    for (let i = 0; i <= 16; i++) {
      for (let j = 0; j < 8; j++) {
        const st = S.stateFromPQ(i / 16, (j / 8) * TAU);
        const viaMatrix = S.applyGate(g, st).r;             /* what the numbers say */
        const viaArc = S.rodrigues(st.r, g.axis, g.angle);  /* what the picture draws */
        w = Math.max(w, maxAbs(viaMatrix, viaArc));
      }
    }
    if (w > 1e-12) arcBad.push(id + " (" + w.toExponential(1) + ")");
    worstArc = Math.max(worstArc, w);
  }
  ok("for every gate, matrix action == the (axis, angle) arc the figure draws",
    arcBad.length === 0, "max diff " + worstArc.toExponential(2)
    + (arcBad.length ? "  offenders: " + arcBad.join(", ") : ""));

  /* The thread's stated basis action for the rotation families. */
  {
    const th = 0.7;
    const rx = S.applyGate(S.GATES.Rx, S.basisState("0"), th);
    const ry = S.applyGate(S.GATES.Ry, S.basisState("0"), th);
    /* doc: Rx|0> = cos(θ/2)|0> − i sin(θ/2)|1>;  Ry|0> = cos(θ/2)|0> + sin(θ/2)|1> */
    const c = Math.cos(th / 2), s = Math.sin(th / 2);
    ok("Rx(θ)|0⟩ = cos(θ/2)|0⟩ − i·sin(θ/2)|1⟩  (thread's table)",
      Math.abs(rx.ket[0][0] - c) < 1e-12 && Math.abs(rx.ket[0][1]) < 1e-12
      && Math.abs(rx.ket[1][0]) < 1e-12 && Math.abs(rx.ket[1][1] + s) < 1e-12,
      "β = " + rx.ket[1].map((v) => v.toFixed(4)).join(" + ") + "i");
    ok("Ry(θ)|0⟩ = cos(θ/2)|0⟩ + sin(θ/2)|1⟩  (thread's table)",
      Math.abs(ry.ket[0][0] - c) < 1e-12 && Math.abs(ry.ket[1][0] - s) < 1e-12
      && Math.abs(ry.ket[1][1]) < 1e-12,
      "β = " + ry.ket[1].map((v) => v.toFixed(4)).join(" + ") + "i");
  }

  /* Two-qubit gates: unitarity, the basis permutation each claims, and the
     entanglement signature the figure is built to show. */
  const twoQ = S.GATE_ORDER.filter((id) => S.GATES[id].kind === "nq");
  let unit4 = 0;
  for (const id of twoQ) {
    const M = S.GATES[id].matrixN;
    const N = M.length;
    for (let i = 0; i < N; i++) {
      for (let j = 0; j < N; j++) {
        let acc = [0, 0];
        for (let k = 0; k < N; k++) {
          acc = S.cadd(acc, S.cmul(S.cconj(M[k][i]), M[k][j]));
        }
        unit4 = Math.max(unit4, Math.abs(acc[0] - (i === j ? 1 : 0)), Math.abs(acc[1]));
      }
    }
  }
  ok("every multi-qubit registry matrix is unitary", unit4 < 1e-12,
    twoQ.join(", ") + ", max deviation " + unit4.toExponential(2));

  const e = (i, n = 4) => Array.from({ length: n }, (_, k) => (k === i ? [1, 0] : [0, 0]));
  const asIndex = (v) => v.findIndex((c) => Math.abs(c[0]) > 0.5);
  const sign = (v, i) => Math.sign(v[i][0]);
  ok("CNOT: |00⟩→|00⟩, |01⟩→|01⟩, |10⟩→|11⟩, |11⟩→|10⟩  (if (c) t ^= 1)",
    [0, 1, 3, 2].every((want, i) =>
      asIndex(S.applyGateN(S.GATES.CNOT, e(i))) === want));
  ok("SWAP: |01⟩ ↔ |10⟩, |00⟩ and |11⟩ fixed  (tmp = a; a = b; b = tmp)",
    [0, 2, 1, 3].every((want, i) =>
      asIndex(S.applyGateN(S.GATES.SWAP, e(i))) === want));
  ok("CZ: only |11⟩ changes sign  (if (c && t) sign = -sign)",
    [0, 1, 2, 3].every((i) => {
      const out = S.applyGateN(S.GATES.CZ, e(i));
      return asIndex(out) === i && sign(out, i) === (i === 3 ? -1 : 1);
    }));
  ok("Toffoli: only |110⟩ ↔ |111⟩ move  (if (c1 && c2) t ^= 1)",
    [0, 1, 2, 3, 4, 5, 7, 6].every((want, i) =>
      asIndex(S.applyGateN(S.GATES.Toffoli, e(i, 8))) === want),
    "8×8 permutation, six basis kets fixed");
  /* Toffoli is the reversible AND: fed both controls in superposition, the
     target lands on c1 ∧ c2 for every input at once. */
  {
    const out = S.applyGateN(S.GATES.Toffoli, S.MULTI_Q["++0"].vec);
    const L = S.basisLabels(3);
    const live = out.map((c, i) => (Math.hypot(c[0], c[1]) > 1e-9 ? L[i] : null))
      .filter(Boolean);
    ok("Toffoli|++0⟩ computes AND in place: only the |11·⟩ branch flips",
      live.join(" ") === "|000⟩ |010⟩ |100⟩ |111⟩", live.join(" "));
  }

  /* The teaching point of the 2-qubit figure: CNOT on |+⟩⊗|0⟩ makes a Bell
     pair, and each qubit's own Bloch vector collapses to the centre of the ball
     — the thread's "completely mixed" point. Neither qubit has a state of its
     own any more, which is why no single-qubit arrow can depict this gate. */
  {
    const before = S.MULTI_Q["+0"].vec;
    const after = S.applyGateN(S.GATES.CNOT, before);
    const bell = [Math.SQRT1_2, 0, 0, Math.SQRT1_2];
    const amps = after.map((c) => Math.hypot(c[0], c[1]));
    ok("CNOT|+0⟩ = (|00⟩+|11⟩)/√2 — a Bell pair",
      Math.max(...amps.map((a, i) => Math.abs(a - bell[i]))) < 1e-12,
      "amplitudes " + amps.map((a) => a.toFixed(3)).join(", "));
    const rBefore = [S.reducedBloch(before, 1), S.reducedBloch(before, 0)];
    const rAfter = [S.reducedBloch(after, 1), S.reducedBloch(after, 0)];
    ok("before: both qubits pure (|r| = 1); after: both maximally mixed (|r| = 0)",
      Math.abs(S.vlen(rBefore[0]) - 1) < 1e-12
      && Math.abs(S.vlen(rBefore[1]) - 1) < 1e-12
      && S.vlen(rAfter[0]) < 1e-12 && S.vlen(rAfter[1]) < 1e-12,
      "|r| " + rBefore.map((r) => S.vlen(r).toFixed(3)).join("/") + " → "
      + rAfter.map((r) => S.vlen(r).toFixed(3)).join("/"));
    note("that collapse to the centre is why the 2-qubit cards show a basis-amplitude");
    note("  diff instead of an arrow: an entangled qubit has no arrow of its own.");
  }

  /* The purity checks above only constrain |r|, which is blind to the sign of an
     individual component. Pin the full vector on a *separable* state, where each
     qubit's reduced Bloch vector must equal its own single-qubit one — otherwise
     a flipped r_y would silently swap |R⟩ and |L⟩. */
  {
    const s2 = Math.SQRT1_2;
    /* |R⟩ on q1 ⊗ |0⟩ on q0, index = q1*2 + q0 */
    const vec = [[s2, 0], [0, 0], [0, s2], [0, 0]];
    const q1 = S.reducedBloch(vec, 1);
    const q0 = S.reducedBloch(vec, 0);
    ok("reducedBloch of |R⟩⊗|0⟩ gives (0,1,0) and (0,0,1) — signs included",
      maxAbs(q1, [0, 1, 0]) < 1e-12 && maxAbs(q0, [0, 0, 1]) < 1e-12,
      "q1 = (" + q1.map((v) => v.toFixed(3)) + "), q0 = ("
      + q0.map((v) => v.toFixed(3)) + ")");
    /* and the left-circular partner must come back with the opposite sign */
    const vecL = [[s2, 0], [0, 0], [0, -s2], [0, 0]];
    ok("reducedBloch of |L⟩⊗|0⟩ gives (0,−1,0) — handedness not flipped",
      maxAbs(S.reducedBloch(vecL, 1), [0, -1, 0]) < 1e-12);
    /* a state with r_x ≠ 0 as well, so no component's sign is left unconstrained */
    for (const [name, P, phi, want] of [
      ["|+⟩⊗|0⟩", 0.5, 0, [1, 0, 0]],
      ["|−⟩⊗|0⟩", 0.5, Math.PI, [-1, 0, 0]],
      ["elliptical⊗|0⟩", 0.75, 0.9, null],
    ]) {
      const k = S.ketFromPQ(P, phi);
      const v = [k[0], [0, 0], k[1], [0, 0]];
      const expect = want || S.rFromPQ(P, phi);
      ok("reducedBloch of " + name + " equals its own single-qubit vector",
        maxAbs(S.reducedBloch(v, 1), expect) < 1e-12,
        "(" + S.reducedBloch(v, 1).map((x) => x.toFixed(3)) + ")");
    }
  }

  /* The diff the cards print must agree with the physics. */
  {
    const d0 = S.diff1q(S.basisState("0"), S.applyGate(S.GATES.Z, S.basisState("0")));
    ok("diff(Z on |0⟩) reports no movement (the thread's “no visible change”)",
      d0.moved < 1e-9 && d0.notes.some((t) => /does not move/.test(t)),
      "|Δr| = " + d0.moved.toExponential(1));
    const dp = S.diff1q(S.basisState("+"), S.applyGate(S.GATES.Z, S.basisState("+")));
    const rowP = dp.rows.find((r) => r.key === "P");
    const rowPhi = dp.rows.find((r) => r.key === "phi");
    ok("diff(Z on |+⟩) reports ΔP = 0 but Δφ = 180°",
      !rowP.changed && rowPhi.changed && rowPhi.delta === "+180.0°",
      "ΔP " + rowP.delta + ", Δφ " + rowPhi.delta);
    const ds = S.diff1q(S.basisState("+"), S.applyGate(S.GATES.S, S.basisState("+")));
    ok("diff(S on |+⟩) reports ΔP = 0, Δφ = +90°, |+⟩ → right circular",
      !ds.rows.find((r) => r.key === "P").changed
      && ds.rows.find((r) => r.key === "phi").delta === "+90.0°"
      && ds.rows.find((r) => r.key === "pol").to === "right circular");
    /* A *negative* delta, which is the only thing that constrains the wrap
       convention: reporting −90° as +270° would be arithmetically defensible and
       badly misleading next to a gate the thread calls a −90° rotation. */
    const dsd = S.diff1q(S.basisState("+"), S.applyGate(S.GATES.Sdg, S.basisState("+")));
    ok("diff(S† on |+⟩) reports Δφ = −90° (not +270°), |+⟩ → left circular",
      dsd.rows.find((r) => r.key === "phi").delta === "−90.0°"
      && dsd.rows.find((r) => r.key === "pol").to === "left circular",
      "Δφ " + dsd.rows.find((r) => r.key === "phi").delta);
    const dtd = S.diff1q(S.basisState("+"), S.applyGate(S.GATES.Tdg, S.basisState("+")));
    ok("diff(T† on |+⟩) reports Δφ = −45°",
      dtd.rows.find((r) => r.key === "phi").delta === "−45.0°",
      "Δφ " + dtd.rows.find((r) => r.key === "phi").delta);
  }
}

/* ======================================================================== */
console.log("\n" + "-".repeat(72));
if (failures === 0) {
  console.log(checks + " checks passed — the animation's real-valued Prime/Ortho");
  console.log("model is textbook quantum mechanics in disguise.");
} else {
  console.log(failures + " of " + checks + " checks FAILED");
}
process.exit(failures === 0 ? 0 : 1);
