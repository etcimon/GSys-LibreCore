// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * gate-figure.js — the static before/after/diff figures and the gate modal.
 *
 * The animated spheres in js/bloch.js answer "what does a qubit do?". These
 * figures answer the different question "what did this operation *change*?", so
 * they are static first: a dim ghost of the input state, a bright arrow for the
 * output, the rotation arc that carries one to the other, and a table of what
 * moved and what did not. Nothing has to be watched to be read.
 *
 * Three surfaces, one renderer:
 *   · gate cards      — compact static figures, laid out as an atlas in-article
 *   · the gate modal  — opened by clicking any dotted-underlined gate name, with
 *                       an input-state selector, a θ slider for the rotation
 *                       families, and a replay/scrub control whose animation is
 *                       a *difference*: the ghost never moves, the arc grows
 *   · basis diffs     — for CZ/CNOT/SWAP/Toffoli, which have no single-qubit
 *                       arrow at all, an amplitude table plus the collapse of
 *                       each qubit's own Bloch vector to the centre of the ball
 *
 * All physics comes from js/qtheory.js; this file only draws. The projection is
 * the same Z-up view the three.js scenes use, so the flat figures and the
 * animated balls agree.
 */
(function () {
  "use strict";
  if (typeof QTheory === "undefined") return;

  var Q = QTheory;
  var SVGNS = "http://www.w3.org/2000/svg";

  var COL = {
    before: "#7f9bb5",
    after: "#ff35d6",
    arc: "#ffd166",
    axis: "#35c9e8",
    x: "#ff5566",
    y: "#3dff8f",
    z: "#5ab0ff",
    ring: "rgba(190, 220, 240, 0.55)",
    ringBack: "rgba(150, 180, 205, 0.20)",
    ink: "#dfe8f2"
  };

  /* ------------------------------------------------------------ projection */
  /* Same view as the animated scenes: Z up, +Y to the right, +X toward the
     viewer's lower left. Orthographic, which is what a figure wants. */
  var VIEW = Q.vnorm([-0.949, -0.150, -0.276]);
  var RIGHT = Q.vnorm(Q.vcross(VIEW, [0, 0, 1]));
  var UPV = Q.vnorm(Q.vcross(RIGHT, VIEW));

  function px(p, o) {
    return [o.cx + Q.vdot(p, RIGHT) * o.r, o.cy - Q.vdot(p, UPV) * o.r];
  }
  function depth(p) { return -Q.vdot(p, VIEW); }

  /* --------------------------------------------------------- dom helpers - */

  function sv(name, attrs, parent) {
    var n = document.createElementNS(SVGNS, name);
    if (attrs) for (var k in attrs) n.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(n);
    return n;
  }
  function el(name, attrs, parent) {
    var n = document.createElement(name);
    if (attrs) {
      for (var k in attrs) {
        if (k === "text") n.textContent = attrs[k];
        else if (k === "html") n.innerHTML = attrs[k];
        else n.setAttribute(k, attrs[k]);
      }
    }
    if (parent) parent.appendChild(n);
    return n;
  }
  function clear(n) { while (n.firstChild) n.removeChild(n.firstChild); }

  function pathOf(pts, o) {
    var d = "";
    for (var i = 0; i < pts.length; i++) {
      var p = px(pts[i], o);
      d += (i ? " L " : "M ") + p[0].toFixed(2) + " " + p[1].toFixed(2);
    }
    return d;
  }

  /* Split a 3-D polyline into the runs in front of and behind the sphere, so a
     great circle reads as a sphere rather than a flat ellipse. */
  function splitDepth(pts) {
    var front = [], back = [], run = [], sign = null;
    for (var i = 0; i < pts.length; i++) {
      var s = depth(pts[i]) >= 0;
      if (sign === null) sign = s;
      if (s !== sign) {
        (sign ? front : back).push(run);
        run = [pts[i - 1] || pts[i]];
        sign = s;
      }
      run.push(pts[i]);
    }
    if (run.length > 1) (sign ? front : back).push(run);
    return { front: front, back: back };
  }

  function circlePts(normal, radius, n) {
    var nn = Q.vnorm(normal);
    var u = Q.vnorm(Q.vcross(nn, Math.abs(nn[2]) < 0.9 ? [0, 0, 1] : [0, 1, 0]));
    var v = Q.vnorm(Q.vcross(nn, u));
    var out = [];
    for (var i = 0; i <= n; i++) {
      var a = (i / n) * Q.TAU;
      out.push(Q.vadd(Q.vscale(u, Math.cos(a) * radius),
        Q.vscale(v, Math.sin(a) * radius)));
    }
    return out;
  }

  function arcPts(from, axis, ang, n) {
    var out = [];
    for (var i = 0; i <= n; i++) out.push(Q.rodrigues(from, axis, ang * (i / n)));
    return out;
  }

  /* ------------------------------------------------------- sphere figure - */
  /* Returns { node, update } so the same builder serves the static cards and
     the live modal. */
  function buildSphere(size, opts) {
    opts = opts || {};
    var pad = size * 0.13;
    var o = { cx: size / 2, cy: size / 2, r: size / 2 - pad };
    var svg = document.createElementNS(SVGNS, "svg");
    svg.setAttribute("viewBox", "0 0 " + size + " " + size);
    svg.setAttribute("class", "gq-sphere");
    svg.setAttribute("role", "img");

    var defs = sv("defs", null, svg);
    function marker(id, color, scale) {
      var m = sv("marker", {
        id: id, viewBox: "0 0 10 10", refX: "8.5", refY: "5",
        markerWidth: 6 * scale, markerHeight: 6 * scale, orient: "auto-start-reverse"
      }, defs);
      sv("path", { d: "M 0 0 L 10 5 L 0 10 z", fill: color }, m);
    }
    var uid = "gq" + (buildSphere.n = (buildSphere.n || 0) + 1);
    marker(uid + "b", COL.before, 1);
    marker(uid + "a", COL.after, 1.05);
    marker(uid + "c", COL.arc, 0.85);

    /* sphere body */
    sv("circle", {
      cx: o.cx, cy: o.cy, r: o.r, fill: "rgba(120,160,200,0.07)",
      stroke: "rgba(160,200,230,0.35)", "stroke-width": 1
    }, svg);

    /* great circles: equator bright, two meridians faint */
    [[[0, 0, 1], COL.ring, 1.1], [[0, 1, 0], COL.ringBack, 0.9],
      [[1, 0, 0], COL.ringBack, 0.9]].forEach(function (spec) {
      var parts = splitDepth(circlePts(spec[0], 1, 120));
      parts.back.forEach(function (run) {
        sv("path", {
          d: pathOf(run, o), fill: "none", stroke: spec[1],
          "stroke-width": spec[2] * 0.7, "stroke-dasharray": "1.5 3",
          opacity: 0.45
        }, svg);
      });
      parts.front.forEach(function (run) {
        sv("path", {
          d: pathOf(run, o), fill: "none", stroke: spec[1],
          "stroke-width": spec[2], "stroke-dasharray": "2 3"
        }, svg);
      });
    });

    /* axes + letters */
    [["x", [1, 0, 0], "X"], ["y", [0, 1, 0], "Y"], ["z", [0, 0, 1], "Z"]]
      .forEach(function (a) {
        var A = a[1], c = COL[a[0]];
        var p0 = px(Q.vscale(A, -1.16), o), p1 = px(Q.vscale(A, 1.16), o);
        sv("line", {
          x1: p0[0], y1: p0[1], x2: p1[0], y2: p1[1], stroke: c,
          "stroke-width": 0.9, opacity: 0.7
        }, svg);
        var lp = px(Q.vscale(A, 1.31), o);
        var t = sv("text", {
          x: lp[0], y: lp[1], fill: c, "font-size": size * 0.075,
          "text-anchor": "middle", "dominant-baseline": "middle",
          "font-weight": "700", class: "gq-axis-label"
        }, svg);
        t.textContent = a[2];
      });

    /* pole markers for |0> and |1> */
    [[[0, 0, 1], "|0⟩"], [[0, 0, -1], "|1⟩"]].forEach(function (p) {
      var q = px(p[0], o);
      sv("circle", { cx: q[0], cy: q[1], r: 2.1, fill: "#ffffff", opacity: 0.85 }, svg);
    });

    /* dynamic layers, drawn in back-to-front order */
    var gAxis = sv("g", { class: "gq-rotaxis" }, svg);
    var gArc = sv("g", { class: "gq-arc" }, svg);
    var gBefore = sv("g", { class: "gq-before" }, svg);
    var gAfter = sv("g", { class: "gq-after" }, svg);
    var gLabels = sv("g", { class: "gq-vlabels" }, svg);

    function vector(g, vec, color, marker, dashed, width) {
      var p1 = px(vec, o);
      sv("line", {
        x1: o.cx, y1: o.cy, x2: p1[0], y2: p1[1], stroke: color,
        "stroke-width": width || 2, "marker-end": "url(#" + marker + ")",
        "stroke-dasharray": dashed ? "3 2.5" : "",
        opacity: dashed ? 0.85 : 1
      }, g);
      sv("circle", { cx: p1[0], cy: p1[1], r: dashed ? 2 : 2.8, fill: color }, g);
      return p1;
    }

    function label(text, vec, color) {
      var p = px(Q.vscale(Q.vnorm(vec), 1.0), o);
      var out = Q.vdot(vec, RIGHT) >= 0 ? 1 : -1;
      var t = sv("text", {
        x: p[0] + out * size * 0.045, y: p[1] - size * 0.035,
        fill: color, "font-size": size * 0.068,
        "text-anchor": out > 0 ? "start" : "end",
        "dominant-baseline": "middle", "font-weight": "600"
      }, gLabels);
      t.textContent = text;
      return t;
    }

    /* `progress` in [0,1] scrubs the rotation; 1 is the finished gate. */
    function update(st) {
      clear(gAxis); clear(gArc); clear(gBefore); clear(gAfter); clear(gLabels);
      var before = st.before, axis = st.axis, ang = st.angle;
      var prog = st.progress == null ? 1 : st.progress;
      var cur = ang ? Q.rodrigues(before, axis, ang * prog) : before.slice();

      /* the axis the operation turns about */
      if (opts.showAxis !== false && ang) {
        var a0 = px(Q.vscale(axis, -1.12), o), a1 = px(Q.vscale(axis, 1.12), o);
        sv("line", {
          x1: a0[0], y1: a0[1], x2: a1[0], y2: a1[1], stroke: COL.axis,
          "stroke-width": 1.3, "stroke-dasharray": "5 3", opacity: 0.8
        }, gAxis);
      }

      /* the arc: the whole rotation faint, the part already travelled solid */
      if (ang) {
        var full = splitDepth(arcPts(before, axis, ang, 72));
        full.front.concat(full.back).forEach(function (run) {
          sv("path", {
            d: pathOf(run, o), fill: "none", stroke: COL.arc,
            "stroke-width": 1, "stroke-dasharray": "2 3", opacity: 0.45
          }, gArc);
        });
        if (prog > 0.001) {
          var done = splitDepth(arcPts(before, axis, ang * prog, 64));
          var last = null;
          done.front.concat(done.back).forEach(function (run) {
            last = sv("path", {
              d: pathOf(run, o), fill: "none", stroke: COL.arc,
              "stroke-width": 2.1, "stroke-linecap": "round"
            }, gArc);
          });
          if (last) last.setAttribute("marker-end", "url(#" + uid + "c)");
        }
      }

      /* before: a ghost that never moves — the reference for the difference */
      vector(gBefore, before, COL.before, uid + "b", true, 1.6);
      vector(gAfter, cur, COL.after, uid + "a", false, 2.2);

      if (opts.labels !== false) {
        label(st.beforeLabel || "in", before, COL.before);
        if (Q.vdist(before, cur) > 0.06) {
          label(st.afterLabel || "out", cur, COL.after);
        }
      }
    }

    return { node: svg, update: update, size: size };
  }

  /* ------------------------------------------------------ bars and tables */

  function barRow(parent, label, value, cls, extra) {
    var row = el("div", { class: "gq-bar-row" }, parent);
    el("span", { class: "gq-bar-lab", text: label }, row);
    var track = el("div", { class: "gq-bar-track" }, row);
    var fill = el("i", { class: "gq-bar-fill " + cls }, track);
    fill.style.width = (Math.max(0, Math.min(1, value)) * 100).toFixed(1) + "%";
    el("span", { class: "gq-bar-val", text: extra == null ? value.toFixed(3) : extra }, row);
    return row;
  }

  function diffTable(parent, before, after) {
    var d = Q.diff1q(before, after);
    var tbl = el("table", { class: "gq-diff" }, parent);
    var thead = el("thead", null, tbl);
    var htr = el("tr", null, thead);
    ["", "before", "after", "Δ"].forEach(function (h) {
      el("th", { text: h }, htr);
    });
    var tb = el("tbody", null, tbl);
    d.rows.forEach(function (r) {
      var tr = el("tr", { class: r.changed ? "gq-changed" : "gq-same" }, tb);
      el("th", { text: r.label }, tr);
      el("td", { text: r.from }, tr);
      el("td", { text: r.to }, tr);
      el("td", { class: "gq-delta", text: r.delta }, tr);
    });
    return d;
  }

  /* --------------------------------------------------- complex formatting */

  function fmtReal(v) {
    var s = v < 0 ? "−" : "";
    var a = Math.abs(v);
    if (a < 1e-9) return "0";
    if (Math.abs(a - 1) < 1e-9) return s + "1";
    if (Math.abs(a - Math.SQRT1_2) < 1e-9) return s + "1/√2";
    if (Math.abs(a - 0.5) < 1e-9) return s + "½";
    if (Math.abs(a - Math.sqrt(3) / 2) < 1e-9) return s + "√3/2";
    return s + a.toFixed(3);
  }
  function fmtComplex(c) {
    var re = c[0], im = c[1];
    if (Math.abs(im) < 1e-9) return fmtReal(re);
    var imu = Math.abs(im) < 1e-9 ? "0"
      : (Math.abs(Math.abs(im) - 1) < 1e-9 ? "" : fmtReal(Math.abs(im)));
    var ip = (im < 0 ? "−" : "") + imu + "i";
    if (Math.abs(re) < 1e-9) return ip;
    return fmtReal(re) + (im < 0 ? " − " : " + ") + imu + "i";
  }

  function matrixTable(parent, M) {
    var wrap = el("div", { class: "gq-matrix" }, parent);
    var t = el("table", null, wrap);
    for (var i = 0; i < M.length; i++) {
      var tr = el("tr", null, t);
      for (var j = 0; j < M[i].length; j++) {
        el("td", { text: fmtComplex(M[i][j]) }, tr);
      }
    }
    return wrap;
  }

  /* -------------------------------------------------------- 1-qubit card - */

  function gateRotationText(g, angle) {
    if (g.kind !== "1q") return g.nq + " qubits · no single-qubit rotation";
    var a = angle == null ? g.angle : angle;
    if (Math.abs(a) < 1e-9) return "no rotation";
    var axisName = axisLabel(g.axis);
    return fmtAngle(a) + " about " + axisName;
  }
  function axisLabel(ax) {
    if (Math.abs(ax[0] - 1) < 1e-9) return "x̂";
    if (Math.abs(ax[1] - 1) < 1e-9) return "ŷ";
    if (Math.abs(ax[2] - 1) < 1e-9) return "ẑ";
    return "(x̂+ẑ)/√2";
  }
  function fmtAngle(a) {
    var deg = a * 180 / Math.PI;
    var s = (deg < 0 ? "−" : "") + Math.abs(Math.round(deg * 10) / 10) + "°";
    return s;
  }

  /* Compact, static, no animation: the atlas entry. */
  function gateCard(g, inputId) {
    var card = el("figure", { class: "gq-card", "data-gate": g.id });
    var head = el("header", { class: "gq-card-head" }, card);
    el("span", { class: "gq-sym", text: g.symbol }, head);
    var ht = el("span", { class: "gq-card-titles" }, head);
    el("b", { text: g.name }, ht);
    el("small", { text: gateRotationText(g) }, ht);

    var body = el("div", { class: "gq-card-body" }, card);

    if (g.kind === "1q") {
      var inId = inputId || g.demo || "0";
      var before = Q.basisState(inId);
      var after = Q.applyGate(g, before);
      var sph = buildSphere(168, {});
      sph.update({
        before: before.r, axis: g.axis, angle: g.angle, progress: 1,
        beforeLabel: labelOf(inId), afterLabel: Q.nameState(after) || "out"
      });
      var left = el("div", { class: "gq-card-fig" }, body);
      left.appendChild(sph.node);
      var io = el("div", { class: "gq-io" }, left);
      el("span", { class: "gq-io-in", text: labelOf(inId) }, io);
      el("span", { class: "gq-io-arr", text: "→" }, io);
      el("span", { class: "gq-io-out", text: Q.nameState(after) || "…" }, io);

      var right = el("div", { class: "gq-card-num" }, body);
      var bars = el("div", { class: "gq-bars" }, right);
      barRow(bars, "P in", before.P, "gq-b-before");
      barRow(bars, "P out", after.P, "gq-b-after");
      var d = Q.diff1q(before, after);
      var note = el("p", { class: "gq-card-note" }, right);
      note.textContent = d.moved < 5e-7
        ? "no change on " + labelOf(inId)
        : summarise(d);
    } else {
      body.appendChild(basisDiff(g, g.demo2, true));
    }

    var cap = el("figcaption", { class: "gq-card-cap" }, card);
    el("code", { text: g.c }, cap);
    return card;
  }

  function labelOf(id) {
    for (var i = 0; i < Q.BASIS.length; i++) {
      if (Q.BASIS[i].id === id) return Q.BASIS[i].label;
    }
    return id;
  }

  function summarise(d) {
    var moved = [];
    d.rows.forEach(function (r) {
      if (r.changed && (r.key === "P" || r.key === "phi")) {
        moved.push((r.key === "P" ? "ΔP " : "Δφ ") + r.delta);
      }
    });
    return moved.length ? moved.join(", ") : "state moved";
  }

  /* ------------------------------------------- multi-qubit basis diff ---- */
  /* CZ, CNOT, SWAP and Toffoli have no single-qubit arrow, so the honest figure
     is the basis-amplitude table plus, for two qubits, the collapse of each
     qubit's own Bloch vector when the gate entangles. */
  function basisDiff(g, inputId, compact) {
    var wrap = el("div", { class: "gq-basis" + (compact ? " gq-compact" : "") });
    var input = Q.MULTI_Q[inputId] || Q.MULTI_Q[Q.multiInputs(g.nq)[0]];
    var before = input.vec;
    var after = Q.applyGateN(g, before);
    var labels = Q.basisLabels(g.nq);

    var tbl = el("table", { class: "gq-basis-tbl" }, wrap);
    var thead = el("thead", null, tbl);
    var htr = el("tr", null, thead);
    ["basis", "before", "after", ""].forEach(function (h) { el("th", { text: h }, htr); });
    var tb = el("tbody", null, tbl);
    for (var i = 0; i < labels.length; i++) {
      var b = before[i], a = after[i];
      var mb = Math.hypot(b[0], b[1]), ma = Math.hypot(a[0], a[1]);
      var changed = Math.abs(mb - ma) > 1e-9
        || (mb > 1e-9 && Math.abs(b[0] - a[0]) + Math.abs(b[1] - a[1]) > 1e-9);
      if (compact && mb < 1e-9 && ma < 1e-9) continue;
      var tr = el("tr", { class: changed ? "gq-changed" : "gq-same" }, tb);
      el("th", { text: labels[i] }, tr);
      amplitudeCell(el("td", null, tr), b);
      amplitudeCell(el("td", null, tr), a);
      el("td", { class: "gq-delta", text: changed ? "changed" : "" }, tr);
    }

    if (g.nq === 2) {
      var pb = [Q.vlen(Q.reducedBloch(before, 1)), Q.vlen(Q.reducedBloch(before, 0))];
      var pa = [Q.vlen(Q.reducedBloch(after, 1)), Q.vlen(Q.reducedBloch(after, 0))];
      var ent = el("p", { class: "gq-ent" }, wrap);
      var entangled = pa[0] < 0.999 || pa[1] < 0.999;
      ent.className = "gq-ent" + (entangled ? " gq-ent-yes" : "");
      ent.innerHTML = "single-qubit purity |r|: <b>" + pb[0].toFixed(2) + ", "
        + pb[1].toFixed(2) + "</b> → <b>" + pa[0].toFixed(2) + ", "
        + pa[1].toFixed(2) + "</b>"
        + (entangled
          ? " — both arrows have collapsed toward the centre of the ball. The"
            + " qubits are entangled and neither has a state of its own, which"
            + " is why no Bloch arrow can draw this gate."
          : " — still separable, so each qubit keeps its own arrow.");
    }
    return wrap;
  }

  function amplitudeCell(td, c) {
    var m = Math.hypot(c[0], c[1]);
    var box = el("div", { class: "gq-amp" }, td);
    var bar = el("i", { class: "gq-amp-bar" }, box);
    bar.style.width = (m * 100).toFixed(0) + "%";
    if (c[0] < -1e-9 || c[1] < -1e-9) bar.className += " gq-amp-neg";
    el("span", { class: "gq-amp-num", text: m < 1e-9 ? "0" : fmtComplex(c) }, box);
  }

  /* ---------------------------------------------------------------- atlas */

  function buildAtlas(host) {
    var only = (host.getAttribute("data-gates") || "").trim();
    var ids = only ? only.split(/[,\s]+/) : Q.GATE_ORDER;
    var grid = el("div", { class: "gq-atlas" }, host);
    ids.forEach(function (id) {
      var g = Q.GATES[id];
      if (!g) return;
      var card = gateCard(g);
      var btn = el("button", { class: "gq-card-open", type: "button" }, card);
      btn.textContent = "open ▸";
      btn.setAttribute("aria-label", "Open the " + g.name + " detail figure");
      btn.addEventListener("click", function () { openModal(g); });
      grid.appendChild(card);
    });
  }

  /* ---------------------------------------------------------------- modal */

  var modal = null;
  var modalState = null;

  function ensureModal() {
    if (modal) return modal;
    var back = el("div", { class: "gq-modal-back", role: "presentation" });
    var panel = el("div", {
      class: "gq-modal", role: "dialog", "aria-modal": "true",
      "aria-labelledby": "gq-modal-title", tabindex: "-1"
    }, back);
    var head = el("header", { class: "gq-modal-head" }, panel);
    var title = el("h3", { id: "gq-modal-title" }, head);
    var close = el("button", { class: "gq-close", type: "button", "aria-label": "Close" }, head);
    close.innerHTML = "&times;";
    var bodyEl = el("div", { class: "gq-modal-body" }, panel);
    document.body.appendChild(back);

    close.addEventListener("click", closeModal);
    back.addEventListener("mousedown", function (e) {
      if (e.target === back) closeModal();
    });
    document.addEventListener("keydown", function (e) {
      if (!back.classList.contains("gq-open")) return;
      if (e.key === "Escape") closeModal();
    });
    modal = { back: back, panel: panel, title: title, body: bodyEl };
    return modal;
  }

  var lastFocus = null;

  function closeModal() {
    if (!modal) return;
    if (modalState && modalState.raf) cancelAnimationFrame(modalState.raf);
    modalState = null;
    modal.back.classList.remove("gq-open");
    document.body.classList.remove("gq-modal-lock");
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  }

  function openModal(g, inputId) {
    var m = ensureModal();
    lastFocus = document.activeElement;
    clear(m.body);
    m.title.innerHTML = "";
    el("span", { class: "gq-sym", text: g.symbol }, m.title);
    el("span", { text: " " + g.name }, m.title);
    el("code", { class: "gq-qiskit", text: g.qiskit }, m.title);

    if (g.kind === "1q") buildModal1q(m.body, g, inputId);
    else buildModalNq(m.body, g, inputId);

    m.back.classList.add("gq-open");
    document.body.classList.add("gq-modal-lock");
    m.panel.focus();
  }

  function prose(parent, g, extraRows) {
    var dl = el("dl", { class: "gq-prose" }, parent);
    function row(k, v, isCode) {
      el("dt", { text: k }, dl);
      var dd = el("dd", null, dl);
      if (isCode) el("code", { text: v }, dd); else dd.textContent = v;
    }
    row("Bloch sphere", g.bloch);
    row("Reversible C", g.c, true);
    row("Cycle function", g.cycle);
    row("Why it matters", g.why);
    (extraRows || []).forEach(function (r) { row(r[0], r[1], r[2]); });
    return dl;
  }

  function buildModal1q(body, g, inputId) {
    var inId = inputId || g.demo || "0";
    var angle = g.angle;

    var main = el("div", { class: "gq-modal-main" }, body);
    var figCol = el("div", { class: "gq-modal-fig" }, main);
    var numCol = el("div", { class: "gq-modal-num" }, main);

    var sph = buildSphere(320, {});
    figCol.appendChild(sph.node);

    /* input state selector */
    var ctrl = el("div", { class: "gq-controls" }, figCol);
    var inRow = el("div", { class: "gq-ctrl-row" }, ctrl);
    el("span", { class: "gq-ctrl-lab", text: "input" }, inRow);
    var inBtns = el("div", { class: "gq-chips" }, inRow);
    Q.BASIS.forEach(function (b) {
      var btn = el("button", {
        class: "gq-chip" + (b.id === inId ? " gq-on" : ""), type: "button",
        title: b.note
      }, inBtns);
      btn.textContent = b.label;
      btn.addEventListener("click", function () {
        inId = b.id;
        Array.prototype.forEach.call(inBtns.children, function (c) {
          c.classList.remove("gq-on");
        });
        btn.classList.add("gq-on");
        redraw(1);
      });
    });

    /* theta slider for the rotation families */
    var angRow = null;
    if (g.param) {
      angRow = el("div", { class: "gq-ctrl-row" }, ctrl);
      el("span", { class: "gq-ctrl-lab", text: "θ" }, angRow);
      var sl = el("input", {
        type: "range", min: "0", max: "360", step: "1",
        value: String(Math.round(angle * 180 / Math.PI)), class: "gq-range"
      }, angRow);
      var out = el("output", { class: "gq-ctrl-out" }, angRow);
      sl.addEventListener("input", function () {
        angle = parseFloat(sl.value) * Math.PI / 180;
        out.textContent = sl.value + "°";
        redraw(1);
      });
      out.textContent = sl.value + "°";
    }

    /* the difference animation: ghost fixed, arc grows, numbers track */
    var playRow = el("div", { class: "gq-ctrl-row" }, ctrl);
    var play = el("button", { class: "gq-play", type: "button" }, playRow);
    play.textContent = "▶ replay the change";
    var scrub = el("input", {
      type: "range", min: "0", max: "1000", step: "1", value: "1000",
      class: "gq-range gq-scrub", "aria-label": "transformation progress"
    }, playRow);

    var numHead = el("div", { class: "gq-num-head" }, numCol);
    var diffHost = el("div", { class: "gq-diff-host" }, numCol);
    var barHost = el("div", { class: "gq-bars" }, numCol);

    var extra = el("div", { class: "gq-extra" }, numCol);
    el("h4", { text: "matrix" }, extra);
    var mHost = el("div", null, extra);
    el("h4", { text: "action on the basis" }, extra);
    var actHost = el("div", null, extra);

    prose(body, g, [["Qiskit / Cirq", g.qiskit, true]]);

    function redraw(progress) {
      var before = Q.basisState(inId);
      var after = Q.applyGate(g, before, angle);
      /* Scrubbing has to interpolate the *rotation*, not the gate's own matrix:
         a fixed matrix like H has no fractional form, so asking gateMatrix for
         a partial angle would silently hand back the finished gate and the table
         would jump to the answer while the arc was still travelling. Building
         the intermediate state from rotMatrix keeps the numbers and the picture
         the same statement. At progress = 1 the two agree exactly, up to a
         global phase that none of the displayed quantities can see. */
      var prog = progress == null ? 1 : progress;
      var cur = Q.stateFromKet(
        Q.applyM1(Q.rotMatrix(g.axis, angle * prog), before.ket));
      sph.update({
        before: before.r, axis: g.axis, angle: angle, progress: progress,
        beforeLabel: labelOf(inId), afterLabel: Q.nameState(after) || "out"
      });
      var shown = prog >= 0.999 ? after : cur;
      numHead.innerHTML = "";
      el("b", { text: labelOf(inId) }, numHead);
      el("span", { text: "  →  " }, numHead);
      el("b", { class: "gq-out", text: Q.nameState(after) || "state" }, numHead);
      el("small", { text: "   " + gateRotationText(g, angle) }, numHead);

      clear(diffHost);
      var d = diffTable(diffHost, before, shown);
      clear(barHost);
      barRow(barHost, "P in", before.P, "gq-b-before");
      barRow(barHost, "P out", shown.P, "gq-b-after");
      barRow(barHost, "Q in", before.Q, "gq-b-before");
      barRow(barHost, "Q out", shown.Q, "gq-b-after");
      clear(mHost);
      matrixTable(mHost, Q.gateMatrix(g, angle));
      clear(actHost);
      basisActionTable(actHost, g, angle);

      var notes = el("div", { class: "gq-notes" });
      d.notes.forEach(function (t) { el("p", { text: t }, notes); });
      if (d.notes.length) diffHost.appendChild(notes);
    }

    var anim = null;
    function stop() { if (anim) { cancelAnimationFrame(anim); anim = null; } }
    play.addEventListener("click", function () {
      stop();
      var t0 = null, dur = 1150;
      function step(ts) {
        if (t0 === null) t0 = ts;
        var u = Math.min(1, (ts - t0) / dur);
        var e = u < 0.5 ? 2 * u * u : 1 - Math.pow(-2 * u + 2, 2) / 2;
        scrub.value = String(Math.round(e * 1000));
        redraw(e);
        if (u < 1) anim = requestAnimationFrame(step);
        else { anim = null; }
      }
      redraw(0);
      anim = requestAnimationFrame(step);
      modalState = { raf: anim };
    });
    scrub.addEventListener("input", function () {
      stop();
      redraw(parseFloat(scrub.value) / 1000);
    });

    redraw(1);
  }

  function basisActionTable(host, g, angle) {
    var t = el("table", { class: "gq-act" }, host);
    ["0", "1", "+", "-"].forEach(function (id) {
      var b = Q.basisState(id);
      var a = Q.applyGate(g, b, angle);
      var tr = el("tr", null, t);
      el("th", { text: labelOf(id) }, tr);
      el("td", { text: "→" }, tr);
      var name = Q.nameState(a);
      el("td", {
        text: name || ("P=" + a.P.toFixed(2) + ", φ=" + Q.fmtDeg(a.phi))
      }, tr);
      var same = Q.vdist(b.r, a.r) < 5e-7;
      tr.className = same ? "gq-same" : "gq-changed";
    });
  }

  function buildModalNq(body, g, inputId) {
    var ids = Q.multiInputs(g.nq);
    var inId = inputId || g.demo2 || ids[0];

    var main = el("div", { class: "gq-modal-main gq-modal-main-nq" }, body);
    var col = el("div", { class: "gq-modal-fig" }, main);
    var ctrl = el("div", { class: "gq-controls" }, col);
    var inRow = el("div", { class: "gq-ctrl-row" }, ctrl);
    el("span", { class: "gq-ctrl-lab", text: "input" }, inRow);
    var chips = el("div", { class: "gq-chips" }, inRow);
    var host = el("div", { class: "gq-nq-host" }, col);
    var numCol = el("div", { class: "gq-modal-num" }, main);

    el("h4", { text: "matrix (" + (1 << g.nq) + "×" + (1 << g.nq) + ")" }, numCol);
    var mHost = el("div", null, numCol);
    matrixTable(mHost, g.matrixN);

    ids.forEach(function (id) {
      var btn = el("button", {
        class: "gq-chip" + (id === inId ? " gq-on" : ""), type: "button"
      }, chips);
      btn.textContent = Q.MULTI_Q[id].label;
      btn.addEventListener("click", function () {
        inId = id;
        Array.prototype.forEach.call(chips.children, function (c) {
          c.classList.remove("gq-on");
        });
        btn.classList.add("gq-on");
        clear(host);
        host.appendChild(basisDiff(g, inId, false));
      });
    });
    host.appendChild(basisDiff(g, inId, false));
    prose(body, g, [["Qiskit / Cirq", g.qiskit, true]]);
  }

  /* ------------------------------------------------------------ autolink - */

  var LOOKUP = {};
  function normKey(s) {
    return String(s).toLowerCase().replace(/[\s\u00a0]+/g, "")
      .replace(/[()]/g, "");
  }
  Q.GATE_ORDER.forEach(function (id) {
    var g = Q.GATES[id];
    [g.symbol, g.name, id].concat(g.aliases || []).forEach(function (k) {
      var n = normKey(k);
      if (n && !LOOKUP[n]) LOOKUP[n] = id;
    });
  });

  /* Only accept a table cell whose whole text, or whose first token, names a
     gate. Anything looser matches things like "Rotation gates (Rx, Ry, Rz)",
     which the prose pass handles properly by linking each name separately. */
  function resolveCell(text) {
    var raw = String(text).replace(/\u00a0/g, " ").trim();
    var first = (raw.match(/^[^(,]+/) || [""])[0];
    var id = LOOKUP[normKey(raw)] || LOOKUP[normKey(first)];
    return id ? Q.GATES[id] : null;
  }

  var SKIP = /^(CODE|PRE|A|SCRIPT|STYLE|TEXTAREA|BUTTON|H1|H2)$/;
  function skipNode(n) {
    for (var p = n.parentNode; p && p !== document.body; p = p.parentNode) {
      if (p.nodeType !== 1) continue;
      if (SKIP.test(p.tagName)) return true;
      var c = p.getAttribute && p.getAttribute("class");
      if (c && (/\bkatex\b/.test(c) || /\bgq-/.test(c) || /\bbloch-/.test(c))) {
        return true;
      }
    }
    return false;
  }

  function makeLink(gate, text) {
    var a = document.createElement("button");
    a.type = "button";
    a.className = "gq-link";
    a.textContent = text;
    a.setAttribute("data-gate", gate.id);
    a.title = gate.name + " — click for the before/after figure";
    a.addEventListener("click", function (e) {
      e.preventDefault();
      openModal(gate);
    });
    return a;
  }

  function linkTables(root) {
    var tables = root.querySelectorAll("table");
    for (var i = 0; i < tables.length; i++) {
      var ths = tables[i].querySelectorAll("thead th");
      var col = -1;
      for (var j = 0; j < ths.length; j++) {
        if (/^gate$/i.test(ths[j].textContent.trim())) { col = j; break; }
      }
      if (col < 0) continue;
      var rows = tables[i].querySelectorAll("tbody tr");
      for (var k = 0; k < rows.length; k++) {
        var td = rows[k].children[col];
        if (!td || td.querySelector(".gq-link")) continue;
        var g = resolveCell(td.textContent);
        if (!g) continue;
        var host = td.querySelector("strong") || td;
        var txt = (host.textContent || "").trim();
        if (!txt) continue;
        var link = makeLink(g, txt);
        clear(host);
        host.appendChild(link);
      }
    }
  }

  /* Conservative prose patterns. Bare single letters are deliberately absent:
     "X" in running text is far more often a variable than a gate. */
  var PROSE = [
    ["Toffoli", "Toffoli"], ["CCNOT", "Toffoli"],
    ["Controlled-NOT", "CNOT"], ["CNOT", "CNOT"],
    ["Controlled-Z", "CZ"], ["CZ", "CZ"],
    ["SWAP", "SWAP"], ["Hadamard", "H"],
    ["Pauli-X", "X"], ["Pauli-Y", "Y"], ["Pauli-Z", "Z"],
    ["H gate", "H"], ["X gate", "X"], ["Y gate", "Y"], ["Z gate", "Z"],
    ["S gate", "S"], ["T gate", "T"], ["phase gate", "S"],
    ["Rx", "Rx"], ["RX", "Rx"], ["Ry", "Ry"], ["RY", "Ry"],
    ["Rz", "Rz"], ["RZ", "Rz"]
  ];
  var PROSE_RE = new RegExp("(" + PROSE.map(function (p) {
    return p[0].replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }).join("|") + ")", "g");
  var PROSE_MAP = {};
  PROSE.forEach(function (p) { PROSE_MAP[p[0]] = p[1]; });

  var MAX_PER_SECTION = 3;

  function linkProse(root) {
    var sections = root.querySelectorAll("section.chapter");
    for (var s = 0; s < sections.length; s++) linkProseIn(sections[s]);
  }

  function linkProseIn(scope) {
    var counts = {};
    var walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT, null);
    var nodes = [], n;
    while ((n = walker.nextNode())) {
      if (n.nodeValue && PROSE_RE.test(n.nodeValue) && !skipNode(n)) nodes.push(n);
      PROSE_RE.lastIndex = 0;
    }
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      var text = node.nodeValue;
      var frag = document.createDocumentFragment();
      var last = 0, m, did = false;
      PROSE_RE.lastIndex = 0;
      while ((m = PROSE_RE.exec(text))) {
        var id = PROSE_MAP[m[1]];
        var g = Q.GATES[id];
        counts[id] = counts[id] || 0;
        /* require a word boundary on both sides */
        var before = m.index === 0 ? "" : text.charAt(m.index - 1);
        var after = text.charAt(m.index + m[1].length);
        var wordish = /[A-Za-z0-9_]/;
        if ((before && wordish.test(before)) || (after && wordish.test(after))) {
          continue;
        }
        if (!g || counts[id] >= MAX_PER_SECTION) continue;
        counts[id]++;
        if (m.index > last) {
          frag.appendChild(document.createTextNode(text.slice(last, m.index)));
        }
        frag.appendChild(makeLink(g, m[1]));
        last = m.index + m[1].length;
        did = true;
      }
      if (!did) continue;
      if (last < text.length) {
        frag.appendChild(document.createTextNode(text.slice(last)));
      }
      node.parentNode.replaceChild(frag, node);
    }
  }

  /* ----------------------------------------------------------------- init */

  function init() {
    var article = document.querySelector("article") || document.body;
    var hosts = document.querySelectorAll(".gate-atlas");
    for (var i = 0; i < hosts.length; i++) {
      if (hosts[i].dataset.ready) continue;
      hosts[i].dataset.ready = "1";
      buildAtlas(hosts[i]);
    }
    linkTables(article);
    linkProse(article);
  }

  /* Run after KaTeX: it renders on the auto-render script's load event, and
     linking inside an unrendered \( … \) span would break the formula. */
  if (document.readyState === "complete") init();
  else window.addEventListener("load", init);

  window.QGateFigure = { open: openModal, card: gateCard, atlas: buildAtlas };
})();
