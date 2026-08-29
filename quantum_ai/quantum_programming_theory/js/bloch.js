// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * Bloch sphere — the animated Prime / Ortho figures.
 *
 * This file is the *scene*: camera, geometry, materials, the ψ(t) panel and the
 * frame loop. All of the physics comes from js/qtheory.js, which is the single
 * source of truth shared with js/gate-figure.js (the static before/after cards
 * and the gate modal) — see that file for the Prime/Ortho state model, the
 * Bloch/Stokes mapping, the two corrections needed to reconcile the thread's
 * cycle-function formula with its own Bloch table, and the gate registry.
 *
 * Layout notes specific to this scene:
 *
 *   +Z = |0⟩ Prime (horizontal)      −Z = |1⟩ Ortho (vertical)
 *   ±X = ±45° linear (φ = 0, π)      ±Y = right/left circular (φ = ±π/2)
 *
 * Z is up, as in the reference poster, so the camera carries an explicit up
 * vector and the floor grid is rotated out of three.js's default X–Z plane. The
 * arrow, the trail, the θ/φ arcs, the P−Q / 2√(PQ) legs and the wave panel are
 * all the same state drawn several ways, never independent decoration.
 */
(function () {
  "use strict";
  if (typeof THREE === "undefined" || typeof QTheory === "undefined") return;

  /* Thin adapters over the shared core: QTheory speaks plain [x, y, z] arrays,
     this scene speaks THREE.Vector3. Nothing here re-implements any physics. */
  var Q = QTheory;
  var TAU = Q.TAU;
  var EX = new THREE.Vector3(1, 0, 0);
  var EY = new THREE.Vector3(0, 1, 0);
  var EZ = new THREE.Vector3(0, 0, 1);
  var H_AXIS = new THREE.Vector3().fromArray(Q.H_AXIS);

  var COL = {
    x: 0xff3b52,
    y: 0x3dff8f,
    z: 0x4aa8ff,
    shell: 0x9fc4e8,
    ring: 0xbfe4f5,
    frame: 0x35c9e8, /* octahedron / prime-ortho legs */
    vec: 0xff35d6,
    prime: 0xffb03a, /* |0⟩ horizontal, sin³ */
    ortho: 0x4ce3ff, /* |1⟩ vertical,   cos³ */
    arc: 0xff8ae8
  };
  var CSS_PRIME = "#ffb03a";
  var CSS_ORTHO = "#4ce3ff";
  var CSS_SUM = "#ff6ce8";

  var TRAIL_MAX = 420;
  var PANEL_H = 122; /* wave-function panel, CSS px */
  var WAVE_HZ = 0.26; /* displayed optical cycle ≈ 3.8 s (real one is 5.16 fs) */

  /* ------------------------------------------------ theory (shared core) */

  function v3(a) { return new THREE.Vector3(a[0], a[1], a[2]); }
  function ar(v) { return [v.x, v.y, v.z]; }

  function rFromPQ(P, phi) { return v3(Q.rFromPQ(P, phi)); }
  function pqFromR(r) { return Q.pqFromR(ar(r)); }
  function rodrigues(v, axis, ang) {
    return v3(Q.rodrigues(ar(v), ar(axis), ang));
  }
  var primeAmp = Q.primeAmp;
  var orthoAmp = Q.orthoAmp;
  var fieldMag = Q.fieldMag;
  var polName = Q.polName;

  var PROGRAMS = Q.PROGRAMS;
  var compileProgram = Q.compileProgram;
  function sampleProgram(prog, t) {
    var s = Q.sampleProgram(prog, t);
    return { r: v3(s.r), name: s.name };
  }


  /* ------------------------------------------------------------- materials */

  function dotTexture() {
    var c = document.createElement("canvas");
    c.width = c.height = 64;
    var g = c.getContext("2d");
    var rg = g.createRadialGradient(32, 32, 0, 32, 32, 32);
    rg.addColorStop(0.0, "rgba(255,255,255,1)");
    rg.addColorStop(0.35, "rgba(255,255,255,0.75)");
    rg.addColorStop(1.0, "rgba(255,255,255,0)");
    g.fillStyle = rg;
    g.fillRect(0, 0, 64, 64);
    return new THREE.CanvasTexture(c);
  }
  var DOT = dotTexture();

  function backdropTexture() {
    var c = document.createElement("canvas");
    c.width = c.height = 256;
    var g = c.getContext("2d");
    g.fillStyle = "#04050a";
    g.fillRect(0, 0, 256, 256);
    var rg = g.createRadialGradient(170, 78, 8, 128, 128, 210);
    rg.addColorStop(0.0, "#2c0f34");
    rg.addColorStop(0.38, "#150b1e");
    rg.addColorStop(1.0, "#04050a");
    g.globalAlpha = 0.72;
    g.fillStyle = rg;
    g.fillRect(0, 0, 256, 256);
    return new THREE.CanvasTexture(c);
  }

  function labelSprite(text, cssColor, scale) {
    var c = document.createElement("canvas");
    c.width = 256; c.height = 128;
    var g = c.getContext("2d");
    g.font = "700 54px Palatino, 'Palatino Linotype', 'Times New Roman', serif";
    g.textAlign = "center";
    g.textBaseline = "middle";
    g.shadowColor = cssColor;
    g.shadowBlur = 18;
    g.fillStyle = cssColor;
    g.fillText(text, 128, 64);
    g.shadowBlur = 0;
    g.fillText(text, 128, 64);
    var spr = new THREE.Sprite(new THREE.SpriteMaterial({
      map: new THREE.CanvasTexture(c),
      transparent: true, depthWrite: false, depthTest: false,
      blending: THREE.AdditiveBlending
    }));
    var s = scale || 0.34;
    spr.scale.set(s * 2, s, 1);
    return spr;
  }

  function glowSprite(cssColor, size, opacity) {
    var c = document.createElement("canvas");
    c.width = c.height = 128;
    var g = c.getContext("2d");
    var rg = g.createRadialGradient(64, 64, 0, 64, 64, 64);
    rg.addColorStop(0.0, cssColor);
    rg.addColorStop(0.25, cssColor);
    rg.addColorStop(1.0, "rgba(0,0,0,0)");
    g.globalAlpha = 0.85;
    g.fillStyle = rg;
    g.beginPath();
    g.arc(64, 64, 64, 0, TAU);
    g.fill();
    var spr = new THREE.Sprite(new THREE.SpriteMaterial({
      map: new THREE.CanvasTexture(c),
      transparent: true, depthWrite: false,
      blending: THREE.AdditiveBlending,
      opacity: opacity == null ? 0.9 : opacity
    }));
    spr.scale.set(size, size, 1);
    return spr;
  }

  function orb(radius, color) {
    return new THREE.Mesh(
      new THREE.SphereGeometry(radius, 20, 14),
      new THREE.MeshBasicMaterial({ color: color })
    );
  }

  /* Beaded great circle — the dotted rings of the reference poster. */
  function beadRing(normal, radius, count, color, size, opacity) {
    var u = new THREE.Vector3(), v = new THREE.Vector3();
    var n = normal.clone().normalize();
    u.crossVectors(n, Math.abs(n.z) < 0.9 ? EZ : EY).normalize();
    v.crossVectors(n, u).normalize();
    var pos = new Float32Array(count * 3);
    for (var i = 0; i < count; i++) {
      var a = (i / count) * TAU;
      var p = u.clone().multiplyScalar(Math.cos(a) * radius)
        .add(v.clone().multiplyScalar(Math.sin(a) * radius));
      pos[i * 3] = p.x; pos[i * 3 + 1] = p.y; pos[i * 3 + 2] = p.z;
    }
    var geo = new THREE.BufferGeometry();
    geo.setAttribute("position", new THREE.BufferAttribute(pos, 3));
    return new THREE.Points(geo, new THREE.PointsMaterial({
      color: color, size: size, map: DOT, transparent: true,
      depthWrite: false, blending: THREE.AdditiveBlending,
      opacity: opacity == null ? 0.95 : opacity, sizeAttenuation: true
    }));
  }

  /* Dynamic bead strip, rewritten every frame (θ arc, φ arc). */
  function beadStrip(count, color, size, opacity) {
    var pos = new Float32Array(count * 3);
    var geo = new THREE.BufferGeometry();
    geo.setAttribute("position", new THREE.BufferAttribute(pos, 3));
    geo.setDrawRange(0, 0);
    var pts = new THREE.Points(geo, new THREE.PointsMaterial({
      color: color, size: size, map: DOT, transparent: true,
      depthWrite: false, blending: THREE.AdditiveBlending,
      opacity: opacity == null ? 1 : opacity, sizeAttenuation: true
    }));
    pts.count = count;
    return pts;
  }

  /* Fill a bead strip along the geodesic from unit a to unit b. */
  function fillGeodesic(strip, a, b, radius) {
    var geo = strip.geometry;
    var arr = geo.attributes.position.array;
    var axis = new THREE.Vector3().crossVectors(a, b);
    var ang = Math.acos(Math.min(1, Math.max(-1, a.dot(b))));
    if (axis.lengthSq() < 1e-9 || ang < 1e-3) {
      geo.setDrawRange(0, 0);
      return;
    }
    axis.normalize();
    var n = strip.count;
    for (var i = 0; i < n; i++) {
      var p = rodrigues(a, axis, ang * (i / (n - 1))).multiplyScalar(radius);
      arr[i * 3] = p.x; arr[i * 3 + 1] = p.y; arr[i * 3 + 2] = p.z;
    }
    geo.setDrawRange(0, n);
    geo.attributes.position.needsUpdate = true;
  }

  function dynamicLine(count, color, opacity, dashed) {
    var pos = new Float32Array(count * 3);
    var geo = new THREE.BufferGeometry();
    geo.setAttribute("position", new THREE.BufferAttribute(pos, 3));
    var mat = dashed
      ? new THREE.LineDashedMaterial({
        color: color, dashSize: 0.07, gapSize: 0.05,
        transparent: true, opacity: opacity, depthWrite: false
      })
      : new THREE.LineBasicMaterial({
        color: color, transparent: true, opacity: opacity, depthWrite: false
      });
    return new THREE.Line(geo, mat);
  }

  function setLine(line, points) {
    var arr = line.geometry.attributes.position.array;
    for (var i = 0; i < points.length; i++) {
      arr[i * 3] = points[i].x;
      arr[i * 3 + 1] = points[i].y;
      arr[i * 3 + 2] = points[i].z;
    }
    line.geometry.setDrawRange(0, points.length);
    line.geometry.attributes.position.needsUpdate = true;
    if (line.material.isLineDashedMaterial) line.computeLineDistances();
  }

  /* Neon arrow: emissive shaft + head, aimed by quaternion. */
  function neonArrow(color) {
    var g = new THREE.Group();
    var mat = new THREE.MeshBasicMaterial({ color: color });
    var shaft = new THREE.Mesh(new THREE.CylinderGeometry(0.012, 0.012, 1, 12), mat);
    shaft.position.y = 0.5;
    var head = new THREE.Mesh(new THREE.ConeGeometry(0.045, 0.14, 16), mat);
    head.position.y = 1;
    g.add(shaft);
    g.add(head);
    g.aim = function (dir, len) {
      g.quaternion.setFromUnitVectors(EY, dir.clone().normalize());
      shaft.scale.y = len - 0.14;
      shaft.position.y = (len - 0.14) / 2;
      head.position.y = len - 0.07;
    };
    return g;
  }

  /* ------------------------------------------------------------ wave panel */
  /* The ψ(t) = √P sin³(ωt) + √Q cos³(ωt+φ) animation, drawn in 2D over the
     bottom of the stage: both cycle terms, their sum, which space owns each
     slice of the cycle, and the transverse (Prime, Ortho) field ellipse.   */

  function makePanel(host) {
    var cv = document.createElement("canvas");
    cv.style.cssText = "position:absolute;left:0;bottom:0;width:100%;pointer-events:none;";
    host.appendChild(cv);
    var ctx = cv.getContext("2d");
    var W = 0, dpr = 1;

    function resize() {
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      W = host.clientWidth || 480;
      cv.width = Math.round(W * dpr);
      cv.height = Math.round(PANEL_H * dpr);
      cv.style.height = PANEL_H + "px";
    }
    resize();

    function draw(st, wt) {
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, W, PANEL_H);

      var grd = ctx.createLinearGradient(0, 0, 0, PANEL_H);
      grd.addColorStop(0, "rgba(4,5,10,0.0)");
      grd.addColorStop(0.22, "rgba(4,5,10,0.72)");
      grd.addColorStop(1, "rgba(4,5,10,0.94)");
      ctx.fillStyle = grd;
      ctx.fillRect(0, 0, W, PANEL_H);

      var wide = W >= 470;
      var inset = wide ? 86 : 0;
      var readW = wide ? 176 : 150;
      var padL = 12;
      var boxW = Math.max(90, W - padL - readW - inset - 26);
      var boxX = padL, boxY = 28, boxH = 66;
      var mid = boxY + boxH / 2;
      var amp = boxH / 2 - 2;
      var NRM = 1.04; /* |Prime|, |Ortho|, |E| are all ≤ 1 */

      /* zero line + cycle ticks */
      ctx.strokeStyle = "rgba(150,180,210,0.20)";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(boxX, mid);
      ctx.lineTo(boxX + boxW, mid);
      ctx.stroke();
      ctx.setLineDash([2, 4]);
      for (var q = 1; q < 4; q++) {
        var qx = boxX + (boxW * q) / 4;
        ctx.beginPath();
        ctx.moveTo(qx, boxY);
        ctx.lineTo(qx, boxY + boxH);
        ctx.stroke();
      }
      ctx.setLineDash([]);

      /* Which space owns each slice of the cycle (PrimeGate / OrthoGate). The
         two modes tie identically when P = Q and φ = 0 or π, i.e. for the ±45°
         linear states, where neither space dominates — painted neutral. */
      var N = Math.max(64, Math.round(boxW));
      var i, x, a, b;
      for (i = 0; i < N; i++) {
        var t0 = (i / N) * TAU;
        a = Math.abs(primeAmp(st.P, t0));
        b = Math.abs(orthoAmp(st.Q, t0, st.phi));
        ctx.fillStyle = Math.abs(a - b) < 1e-6
          ? "rgba(170,190,210,0.40)"
          : (a > b ? "rgba(255,176,58,0.55)" : "rgba(76,227,255,0.55)");
        ctx.fillRect(boxX + (i / N) * boxW, boxY + boxH + 5, boxW / N + 0.6, 3);
      }

      /* the three traces */
      function trace(fn, color, width, alpha) {
        ctx.beginPath();
        for (var k = 0; k <= N; k++) {
          var tt = (k / N) * TAU;
          x = boxX + (k / N) * boxW;
          var y = mid - (fn(tt) / NRM) * amp;
          if (k === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        }
        ctx.strokeStyle = color;
        ctx.lineWidth = width;
        ctx.globalAlpha = alpha;
        ctx.shadowColor = color;
        ctx.shadowBlur = 8;
        ctx.stroke();
        ctx.shadowBlur = 0;
        ctx.globalAlpha = 1;
      }
      var fP = function (tt) { return primeAmp(st.P, tt); };
      var fO = function (tt) { return orthoAmp(st.Q, tt, st.phi); };
      var fE = function (tt) { return fieldMag(st.P, st.Q, tt, st.phi); };
      /* ±|E| envelope, then the two component traces inside it */
      trace(fE, CSS_SUM, 1.7, 0.8);
      trace(function (tt) { return -fE(tt); }, CSS_SUM, 1.7, 0.8);
      trace(fP, CSS_PRIME, 1.8, 0.95);
      trace(fO, CSS_ORTHO, 1.8, 0.95);

      /* live cursor + the two component dots */
      var cw = ((wt % TAU) + TAU) % TAU;
      var cx = boxX + (cw / TAU) * boxW;
      ctx.strokeStyle = "rgba(255,255,255,0.42)";
      ctx.beginPath();
      ctx.moveTo(cx, boxY - 3);
      ctx.lineTo(cx, boxY + boxH + 3);
      ctx.stroke();
      function dot(y, color) {
        ctx.fillStyle = color;
        ctx.shadowColor = color;
        ctx.shadowBlur = 10;
        ctx.beginPath();
        ctx.arc(cx, y, 2.6, 0, TAU);
        ctx.fill();
        ctx.shadowBlur = 0;
      }
      dot(mid - (fP(cw) / NRM) * amp, CSS_PRIME);
      dot(mid - (fO(cw) / NRM) * amp, CSS_ORTHO);

      /* headline equation */
      ctx.font = "600 11.5px Palatino, 'Palatino Linotype', 'Times New Roman', serif";
      ctx.textBaseline = "alphabetic";
      var ex = boxX;
      function seg(txt, color) {
        ctx.fillStyle = color;
        ctx.fillText(txt, ex, 19);
        ex += ctx.measureText(txt).width;
      }
      var INK = "rgba(226,236,246,0.92)";
      seg("Prime ", CSS_PRIME);
      seg("√P sin³(ωt)", CSS_PRIME);
      seg("   Ortho ", CSS_ORTHO);
      seg("√Q sin³(ωt+φ)", CSS_ORTHO);
      seg("   ", INK);
      seg("|E| = √(Prime²+Ortho²)", CSS_SUM);

      /* transverse field ellipse: (Prime, Ortho) traced over one cycle */
      if (wide) {
        var ix = boxX + boxW + 14, iy = 22, iS = 78;
        var ccx = ix + iS / 2, ccy = iy + iS / 2, sc = (iS / 2 - 6) / 1.02;
        ctx.strokeStyle = "rgba(150,180,210,0.18)";
        ctx.strokeRect(ix, iy, iS, iS);
        ctx.strokeStyle = "rgba(150,180,210,0.16)";
        ctx.beginPath();
        ctx.moveTo(ix, ccy); ctx.lineTo(ix + iS, ccy);
        ctx.moveTo(ccx, iy); ctx.lineTo(ccx, iy + iS);
        ctx.stroke();
        ctx.beginPath();
        for (i = 0; i <= 180; i++) {
          var et = (i / 180) * TAU;
          x = ccx + primeAmp(st.P, et) * sc;
          var yy = ccy - orthoAmp(st.Q, et, st.phi) * sc;
          if (i === 0) ctx.moveTo(x, yy); else ctx.lineTo(x, yy);
        }
        ctx.strokeStyle = CSS_SUM;
        ctx.lineWidth = 1.6;
        ctx.shadowColor = CSS_SUM;
        ctx.shadowBlur = 8;
        ctx.stroke();
        ctx.shadowBlur = 0;
        /* live E-field vector in the transverse plane */
        var px = ccx + primeAmp(st.P, cw) * sc;
        var py = ccy - orthoAmp(st.Q, cw, st.phi) * sc;
        ctx.strokeStyle = "rgba(255,255,255,0.55)";
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(ccx, ccy);
        ctx.lineTo(px, py);
        ctx.stroke();
        ctx.fillStyle = "#ffffff";
        ctx.shadowColor = CSS_SUM;
        ctx.shadowBlur = 10;
        ctx.beginPath();
        ctx.arc(px, py, 2.8, 0, TAU);
        ctx.fill();
        ctx.shadowBlur = 0;
        ctx.font = "500 8.5px Palatino, 'Times New Roman', serif";
        ctx.fillStyle = "rgba(200,214,230,0.62)";
        ctx.textAlign = "center";
        ctx.fillText("transverse E (Prime, Ortho)", ccx, iy + iS + 10);
        ctx.textAlign = "left";
      }

      /* numeric readout */
      var rx = W - readW - 6;
      ctx.font = "600 10px 'Source Code Pro', Consolas, monospace";
      var ry = 22, lh = 13.5;
      ctx.fillStyle = CSS_PRIME;
      ctx.fillText("P = " + st.P.toFixed(3) + "   √P = " + Math.sqrt(st.P).toFixed(3), rx, ry);
      ctx.fillStyle = CSS_ORTHO;
      ctx.fillText("Q = " + st.Q.toFixed(3) + "   √Q = " + Math.sqrt(st.Q).toFixed(3), rx, ry + lh);
      ctx.fillStyle = "rgba(226,236,246,0.88)";
      ctx.fillText("θ = " + (st.theta * 180 / Math.PI).toFixed(1) + "°   φ = "
        + (((st.phi * 180 / Math.PI) + 360) % 360).toFixed(1) + "°", rx, ry + 2 * lh);
      ctx.fillStyle = "rgba(140,220,240,0.80)";
      ctx.fillText("2√(PQ) = " + (2 * Math.sqrt(st.P * st.Q)).toFixed(3)
        + "  P−Q = " + (st.P - st.Q).toFixed(3), rx, ry + 3 * lh);
      ctx.font = "500 9.5px Palatino, 'Times New Roman', serif";
      ctx.fillStyle = "rgba(226,236,246,0.80)";
      ctx.fillText(polName(st), rx, ry + 4 * lh + 3);
      ctx.fillStyle = "rgba(255,140,232,0.92)";
      ctx.fillText(st.name || "", rx, ry + 5 * lh + 3);
    }

    return { draw: draw, resize: resize };
  }

  /* ----------------------------------------------------------------- scene */

  function makeScene(el, demo) {
    var prog = compileProgram(PROGRAMS[demo] || PROGRAMS.precess);

    el.style.position = "relative";
    el.style.overflow = "hidden";

    var w = el.clientWidth || 480;
    var h = el.clientHeight || 440;

    var renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.setSize(w, h);
    renderer.domElement.style.display = "block";
    el.appendChild(renderer.domElement);

    var scene = new THREE.Scene();
    scene.background = backdropTexture();

    /* Z-up, as in the reference poster: Z up, Y to the right, X toward the
       viewer's lower left (screen-right = cross(view, ẑ) ≈ +ŷ). */
    var CAM_DIR = new THREE.Vector3(0.949, 0.150, 0.276); /* az 9°, el 16° */
    var CAM_DIST = 4.85;
    var camera = new THREE.PerspectiveCamera(40, w / h, 0.1, 60);
    camera.up.copy(EZ);
    camera.position.copy(CAM_DIR).multiplyScalar(CAM_DIST);

    /* Fit the ball + its labels into the band left above the ψ(t) panel:
       world z from about −1.3 (|1⟩ label) to +1.7 (Z label). */
    function frameCamera(cw, ch) {
      var aspect = cw / ch;
      var p = Math.min(0.42, PANEL_H / ch); /* fraction hidden by the panel */
      var hh = Math.max(1.9, 3.0 / (2 * (1 - p)));
      if (hh * aspect < 1.8) hh = 1.8 / aspect;
      camera.aspect = aspect;
      camera.fov = 2 * Math.atan(hh / CAM_DIST) * 180 / Math.PI;
      camera.updateProjectionMatrix();
      camera.lookAt(0, 0, 0.2 - hh * p);
    }
    frameCamera(w, h);

    scene.add(new THREE.AmbientLight(0x8fa8c0, 0.55));
    var key = new THREE.DirectionalLight(0xffffff, 0.85);
    key.position.set(4, 5, 6);
    scene.add(key);
    var fill = new THREE.PointLight(0x6ac6ff, 1.1, 16);
    fill.position.set(-2.4, -1.8, 2.2);
    scene.add(fill);
    var warm = new THREE.PointLight(0xff8a5c, 0.6, 12);
    warm.position.set(2.4, 1.6, -1.2);
    scene.add(warm);

    /* floor grid in the X–Y plane (GridHelper is born in X–Z); kept small and
       dim so its horizon does not compete with the ball */
    var grid = new THREE.GridHelper(7.5, 20, 0x123141, 0x0a1a24);
    grid.rotation.x = Math.PI / 2;
    grid.position.z = -1.92;
    grid.material.transparent = true;
    grid.material.opacity = 0.5;
    scene.add(grid);
    var floorGlow = glowSprite("rgba(70,150,220,0.30)", 1.9, 0.22);
    floorGlow.position.set(0, 0, -1.90);
    scene.add(floorGlow);

    var group = new THREE.Group();
    scene.add(group);

    /* translucent shell: a lit outer skin plus a dim inner back face so the
       ball reads as a volume rather than a wire cage */
    group.add(new THREE.Mesh(
      new THREE.SphereGeometry(1, 64, 48),
      new THREE.MeshPhongMaterial({
        color: COL.shell, transparent: true, opacity: 0.15,
        shininess: 90, specular: 0x9fd8f5, side: THREE.FrontSide,
        depthWrite: false
      })
    ));
    group.add(new THREE.Mesh(
      new THREE.SphereGeometry(0.995, 48, 32),
      new THREE.MeshBasicMaterial({
        color: 0x6f93b8, transparent: true, opacity: 0.05,
        side: THREE.BackSide, depthWrite: false
      })
    ));

    /* dotted great circles: equator + two meridians */
    group.add(beadRing(EZ, 1, 78, COL.ring, 0.030, 0.92));
    group.add(beadRing(EY, 1, 70, 0x8fb6cc, 0.024, 0.62));
    group.add(beadRing(EX, 1, 70, 0x8fb6cc, 0.024, 0.62));

    /* cyan octahedron through the six cardinal points */
    var octa = new THREE.LineSegments(
      new THREE.EdgesGeometry(new THREE.OctahedronGeometry(1, 0)),
      new THREE.LineBasicMaterial({
        color: COL.frame, transparent: true, opacity: 0.5, depthWrite: false
      })
    );
    group.add(octa);

    /* axes with arrow heads and letters */
    function axis(dir, color, cssColor, letter, labelAt) {
      var L = 1.34;
      group.add(new THREE.Line(
        new THREE.BufferGeometry().setFromPoints([
          dir.clone().multiplyScalar(-L), dir.clone().multiplyScalar(L)
        ]),
        new THREE.LineBasicMaterial({
          color: color, transparent: true, opacity: 0.9
        })
      ));
      var head = new THREE.Mesh(
        new THREE.ConeGeometry(0.036, 0.12, 14),
        new THREE.MeshBasicMaterial({ color: color })
      );
      head.quaternion.setFromUnitVectors(EY, dir);
      head.position.copy(dir.clone().multiplyScalar(L));
      group.add(head);
      var lab = labelSprite(letter, cssColor, 0.27);
      lab.position.copy(labelAt);
      group.add(lab);
    }
    axis(EX, COL.x, "#ff6070", "X", new THREE.Vector3(1.52, 0, -0.18));
    axis(EY, COL.y, "#6dffab", "Y", new THREE.Vector3(0, 1.55, -0.06));
    axis(EZ, COL.z, "#7cc4ff", "Z", new THREE.Vector3(0, -0.02, 1.56));

    /* cardinal states — Prime/Ortho poles and the four equator points */
    var CARDINAL = [
      [EZ, 0xffffff, "#ffffff", "|0⟩ Prime", new THREE.Vector3(0.30, 0.34, 1.03)],
      [EZ.clone().negate(), 0xdfe8ff, "#cfe0ff", "|1⟩ Ortho", new THREE.Vector3(0.30, 0.34, -1.05)],
      [EX, 0xff5ae0, "#ff8ae8", "|+⟩", new THREE.Vector3(1.10, -0.02, 0.20)],
      [EX.clone().negate(), 0xffa63a, "#ffbf6a", "|−⟩", new THREE.Vector3(-1.06, 0.06, 0.20)],
      [EY, 0x5affc8, "#8affda", "|R⟩", new THREE.Vector3(0.06, 1.12, 0.20)],
      [EY.clone().negate(), 0x6ab6ff, "#96cdff", "|L⟩", new THREE.Vector3(0.06, -1.10, 0.20)]
    ];
    CARDINAL.forEach(function (cdl) {
      var o = orb(0.036, cdl[1]);
      o.position.copy(cdl[0]);
      group.add(o);
      var gl = glowSprite(cdl[2], 0.22, 0.65);
      gl.position.copy(cdl[0]);
      group.add(gl);
      var ring = beadRing(cdl[0], 0.085, 18, cdl[1], 0.015, 0.85);
      ring.position.copy(cdl[0]);
      group.add(ring);
      var lab = labelSprite(cdl[3], cdl[2], 0.175);
      lab.position.copy(cdl[4]);
      group.add(lab);
    });

    /* --- the live state: arrow, legs, arcs, trail --- */

    var arrow = neonArrow(COL.vec);
    group.add(arrow);
    var tip = orb(0.042, 0xff9df0);
    group.add(tip);
    var tipGlow = glowSprite("rgba(255,90,224,0.8)", 0.25, 0.7);
    group.add(tipGlow);

    /* Prime/Ortho decomposition triangle: the equatorial leg has length
       2√(PQ) (coherence) and the vertical leg P − Q (population imbalance). */
    var legEq = dynamicLine(2, COL.frame, 0.75, true);
    var legZ = dynamicLine(2, COL.frame, 0.75, true);
    var legHyp = dynamicLine(2, 0x9ad8ff, 0.30, false);
    group.add(legEq);
    group.add(legZ);
    group.add(legHyp);

    var arcTheta = beadStrip(24, COL.arc, 0.026, 0.95);
    var arcPhi = beadStrip(24, 0xffd166, 0.026, 0.95);
    group.add(arcTheta);
    group.add(arcPhi);
    var labTheta = labelSprite("θ", "#ff9ae8", 0.16);
    var labPhi = labelSprite("φ", "#ffd166", 0.16);
    group.add(labTheta);
    group.add(labPhi);

    var trailPos = new Float32Array(TRAIL_MAX * 3);
    var trailCol = new Float32Array(TRAIL_MAX * 3);
    var trailGeo = new THREE.BufferGeometry();
    trailGeo.setAttribute("position", new THREE.BufferAttribute(trailPos, 3));
    trailGeo.setAttribute("color", new THREE.BufferAttribute(trailCol, 3));
    trailGeo.setDrawRange(0, 0);
    group.add(new THREE.Line(trailGeo, new THREE.LineBasicMaterial({
      vertexColors: true, transparent: true, opacity: 0.95,
      blending: THREE.AdditiveBlending, depthWrite: false
    })));
    var history = [];

    var panel = makePanel(el);
    var clock = new THREE.Clock();
    var visible = true;
    var headCol = new THREE.Color(COL.vec);
    var tailCol = new THREE.Color(0x1a6ad0);

    function frame() {
      var t = clock.getElapsedTime();
      var s = sampleProgram(prog, t);
      var r = s.r;
      var st = pqFromR(r);
      st.name = s.name;

      arrow.aim(r, 1.0);
      tip.position.copy(r);
      tipGlow.position.copy(r);

      /* decomposition legs */
      var proj = new THREE.Vector3(r.x, r.y, 0);
      setLine(legEq, [new THREE.Vector3(0, 0, 0), proj]);
      setLine(legZ, [proj, r]);
      setLine(legHyp, [new THREE.Vector3(0, 0, 0), r]);

      /* θ from +Z to r; φ in the equatorial plane from +X to proj */
      fillGeodesic(arcTheta, EZ, r, 0.46);
      var tAxis = new THREE.Vector3().crossVectors(EZ, r);
      tAxis = tAxis.lengthSq() > 1e-9 ? tAxis.normalize() : EY;
      labTheta.position.copy(rodrigues(EZ, tAxis, st.theta * 0.5).multiplyScalar(0.53));
      if (proj.lengthSq() > 1e-6) {
        var pn = proj.clone().normalize();
        fillGeodesic(arcPhi, EX, pn, 0.66);
        labPhi.position.copy(rodrigues(EX, EZ, st.phi * 0.5).multiplyScalar(0.78));
        labPhi.visible = true;
      } else {
        arcPhi.geometry.setDrawRange(0, 0);
        labPhi.visible = false;
      }

      /* trail of the tip */
      if (!history.length || history[history.length - 1].distanceToSquared(r) > 2e-5) {
        history.push(r.clone());
        if (history.length > TRAIL_MAX) history.shift();
      }
      var n = history.length;
      var c = new THREE.Color();
      for (var i = 0; i < n; i++) {
        var p = history[i];
        trailPos[i * 3] = p.x; trailPos[i * 3 + 1] = p.y; trailPos[i * 3 + 2] = p.z;
        var f = n > 1 ? i / (n - 1) : 1;
        c.copy(tailCol).lerp(headCol, f).multiplyScalar(0.15 + 0.85 * f * f);
        trailCol[i * 3] = c.r; trailCol[i * 3 + 1] = c.g; trailCol[i * 3 + 2] = c.b;
      }
      trailGeo.setDrawRange(0, n);
      trailGeo.attributes.position.needsUpdate = true;
      trailGeo.attributes.color.needsUpdate = true;

      renderer.render(scene, camera);
      panel.draw(st, t * TAU * WAVE_HZ);
    }

    function loop() {
      if (visible) frame();
      requestAnimationFrame(loop);
    }
    loop();

    function resize() {
      var w2 = el.clientWidth || 480;
      var h2 = el.clientHeight || 440;
      frameCamera(w2, h2);
      renderer.setSize(w2, h2);
      panel.resize();
    }
    if (typeof ResizeObserver !== "undefined") new ResizeObserver(resize).observe(el);
    else window.addEventListener("resize", resize);

    /* three WebGL canvases on one long page: only draw what is on screen */
    if (typeof IntersectionObserver !== "undefined") {
      new IntersectionObserver(function (entries) {
        visible = entries[0].isIntersecting;
      }, { rootMargin: "120px" }).observe(el);
    }
  }

  function init() {
    var stages = document.querySelectorAll(".bloch-stage");
    for (var i = 0; i < stages.length; i++) {
      var el = stages[i];
      if (el.dataset.ready) continue;
      el.dataset.ready = "1";
      makeScene(el, el.getAttribute("data-demo") || "precess");
    }
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
