// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * JS exports for HolyC / kernel interactivity.
 * svelte-d splices these into src-ts jsExports / window.__svelteD.ts.
 * g6b-js AOT understands fetch(), kernel.holyc(), kernel.register().
 */

export function fetchBios(url) {
  return fetch(url, { method: "GET", credentials: "same-origin" });
}

export function holycEval(line) {
  const host = globalThis.kernel;
  if (!host || typeof host.holyc !== "function") throw new Error("HolyC host unavailable in a native browser");
  return host.holyc(line);
}

export function registerEndpoint(path, method = "GET") {
  const host = globalThis.kernel;
  if (!host || typeof host.register !== "function") throw new Error("Endpoint registration is host-only");
  return host.register(path, method);
}

/** Open a MENUS.md screen on both faces (fetch + HolyC). */
export function openMenu(id) {
  if (!["main", "cpu", "memory", "uncore", "devices", "boot", "settings"].includes(id)) {
    throw new Error("Unknown setup menu");
  }
  return fetchBios("/bios/menu/" + id);
}

export const jsExports = {
  env: {
    fetchBios,
    holycEval,
    registerEndpoint,
  },
};

export function createWasmHost(doc, allowed, request, log = (message) => console.log(message)) {
  let memory;
  let calls = 0;
  const queue = [];
  const queued = new Set();
  const saved = new Map();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  function text(ptr, len) {
    if (++calls > 4096) throw new Error("WASM import budget exceeded");
    if (!memory || !Number.isInteger(ptr) || !Number.isInteger(len) || ptr < 0 || len < 0 ||
        ptr > memory.buffer.byteLength || len > memory.buffer.byteLength - ptr) {
      throw new Error("WASM memory bounds violation");
    }
    return decoder.decode(new Uint8Array(memory.buffer, ptr, len));
  }
  function remember(node) {
    if (!saved.has(node)) saved.set(node, {});
    return saved.get(node);
  }
  function fetchImport(ptr, len) {
    const url = text(ptr, len);
    if (!allowed.has(url) || queued.has(url)) return;
    if (queue.length >= 128) throw new Error("WASM read queue budget exceeded");
    queued.add(url);
    queue.push(url);
  }
  return {
    imports: {
      env: {
        set_inner_text(idPtr, idLen, valuePtr, valueLen) {
          const id = text(idPtr, idLen);
          const value = text(valuePtr, valueLen);
          const node = doc.getElementById(id);
          if (!node || node.getAttribute("data-preserve") === "true") return;
          if (node.children.length) throw new Error("WASM text target must be a leaf: " + id);
          const prior = remember(node);
          if (!("text" in prior)) prior.text = node.textContent;
          node.textContent = value;
        },
        console_log(ptr, len) { log(text(ptr, len)); },
        set_visible(ptr, len, on) {
          const node = doc.getElementById(text(ptr, len));
          if (!node) return;
          const prior = remember(node);
          if (!("hidden" in prior)) prior.hidden = node.hidden;
          node.hidden = on === 0;
        },
        fetch: fetchImport,
        Object_Call_string__Handle: fetchImport,
      },
    },
    bind(value) {
      if (!value || !value.buffer || typeof value.buffer.byteLength !== "number") throw new Error("WASM memory export missing");
      memory = value;
    },
    async drain() {
      while (queue.length) await request(queue.shift());
    },
    rollback() {
      queue.length = 0;
      for (const [node, prior] of saved) {
        if ("text" in prior) node.textContent = prior.text;
        if ("hidden" in prior) node.hidden = prior.hidden;
      }
      saved.clear();
    },
  };
}

// libwasm `NodeType` ordinals (browser-ui/libwasm/source/libwasm/types.d).
// The LDC cell passes these as the `createElement` i32 argument.
const LIBWASM_TAGS =
  "a,abbr,address,area,article,aside,audio,b,base,bdi,bdo,blockquote,body,br,button,canvas,caption,cite,code,col,colgroup,data,datalist,dd,del,dfn,div,dl,dt,em,embed,fieldset,figcaption,figure,footer,form,h1,h2,h3,h4,h5,h6,head,header,hr,html,i,iframe,img,input,ins,kbd,keygen,label,legend,li,link,main,map,mark,meta,meter,nav,noscript,object,ol,optgroup,option,output,p,param,pre,progress,q,rb,rp,rt,rtc,ruby,s,samp,script,section,select,small,source,span,strong,style,sub,sup,table,tbody,td,template,textarea,tfoot,th,thead,time,title,tr,track,u,ul,var,video,wbr"
    .split(",");

/**
 * DOM-kernel host for the LDC/libwasm wasm-eh cell
 * (`out/bios-ui-libwasm.wasm`). Strings arrive as libwasm (length, pointer)
 * pairs; the module-internal `getRoot()` returns handle 1, mapped to `mount`.
 * Bounded like createWasmHost: the handle table is capped, strings are
 * bounds-checked, and a failed `_start` never unmounts the static view.
 */
export function createLibwasmHost(doc, mount, wasmApi = globalThis.WebAssembly) {
  if (!mount || typeof mount.replaceChildren !== "function") throw new Error("libwasm mount unavailable");
  if (!wasmApi || typeof wasmApi.Tag !== "function") throw new Error("WebAssembly exception tags unavailable");
  const tags = new Set("a abbr address article aside b bdi bdo blockquote br button caption cite code col colgroup data datalist dd del dfn div dl dt em fieldset figcaption figure footer h1 h2 h3 h4 h5 h6 header hr i input ins kbd label legend li main mark meter nav ol optgroup option output p pre progress q rb rp rt rtc ruby s samp section select small span strong sub sup table tbody td textarea tfoot th thead time tr u ul var wbr".split(" "));
  const root = doc.createElement("div");
  const handles = new Map([[1, root]]);
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let memory, prior;
  let next = 2, calls = 0, stringBytes = 0;
  let state = "staging";
  function checkMemory(value) {
    if (!value || !value.buffer || !Number.isInteger(value.buffer.byteLength) || value.buffer.byteLength > 16 * 1024 * 1024) {
      throw new Error("WASM memory export missing or memory budget exceeded");
    }
  }
  function text(len, ptr) {
    checkMemory(memory);
    if (!Number.isInteger(ptr) || !Number.isInteger(len) || ptr < 0 || len < 0 ||
        len > 65536 || ptr > memory.buffer.byteLength || len > memory.buffer.byteLength - ptr) {
      throw new Error("WASM string bounds violation");
    }
    stringBytes += len;
    if (stringBytes > 1024 * 1024) throw new Error("WASM string budget exceeded");
    return decoder.decode(new Uint8Array(memory.buffer, ptr, len));
  }
  function node(handle, writable = false) {
    if (!Number.isInteger(handle) || !handles.has(handle) || (writable && handle === 1)) {
      throw new Error("WASM unknown or protected DOM handle");
    }
    return handles.get(handle);
  }
  function create(tag) {
    if (!tags.has(tag)) throw new Error("WASM unsupported DOM tag: " + tag);
    if (handles.size >= 4096) throw new Error("WASM DOM handle budget exceeded");
    const handle = next++;
    handles.set(handle, doc.createElement(tag));
    return handle;
  }
  function place(parent, child, sibling = 0) {
    const p = node(parent), c = node(child, true), s = sibling === 0 ? null : node(sibling, true);
    if (c.contains(p) || (s && s.parentNode !== p)) throw new Error("WASM invalid DOM hierarchy");
    let depth = 0;
    for (let n = p; n; n = n.parentNode) depth++;
    const pending = [[c, depth + 1]];
    while (pending.length) {
      const [n, d] = pending.pop();
      if (d > 64) throw new Error("WASM DOM depth budget exceeded");
      for (const childNode of n.children) pending.push([childNode, d + 1]);
    }
    p.insertBefore(c, s);
  }
  function detach(child) { node(child, true).remove(); }
  const functions = {
    createElement(tag) {
      if (!Number.isInteger(tag)) throw new Error("WASM invalid DOM tag ordinal");
      return create(LIBWASM_TAGS[tag]);
    },
    createCustomElement(len, ptr) { return create(text(len, ptr)); },
    appendChild(parent, child) { place(parent, child); },
    insertBefore: place,
    removeChild: detach,
    unmount: detach,
    setProperty(handle, nameLen, namePtr, valueLen, valuePtr) {
      const n = node(handle, true), name = text(nameLen, namePtr), value = text(valueLen, valuePtr);
      if (name === "innerText" || name === "textContent") n.textContent = value;
      else if (name === "className" || name === "title" || name === "value") n[name] = value;
      else throw new Error("WASM unsupported DOM property: " + name);
    },
    setPropertyBool(handle, nameLen, namePtr, value) {
      const n = node(handle, true), name = text(nameLen, namePtr);
      if (!["hidden", "disabled", "checked", "readOnly"].includes(name) || (value !== 0 && value !== 1)) {
        throw new Error("WASM unsupported boolean DOM property");
      }
      n[name] = value !== 0;
    },
    setPropertyInt(handle, nameLen, namePtr, value) {
      const n = node(handle, true), name = text(nameLen, namePtr);
      if (name !== "tabIndex" || !Number.isInteger(value) || value < -1 || value > 32767) {
        throw new Error("WASM unsupported integer DOM property");
      }
      n.tabIndex = value;
    },
    addClass(handle, len, ptr) { node(handle, true).classList.add(text(len, ptr)); },
    removeClass(handle, len, ptr) { node(handle, true).classList.remove(text(len, ptr)); },
  };
  const env = Object.fromEntries(Object.entries(functions).map(([name, fn]) => [name, (...args) => {
    try {
      if (state !== "staging") throw new Error("WASM DOM transaction is " + state);
      if (++calls > 16384) throw new Error("WASM import budget exceeded");
      if (memory) checkMemory(memory);
      return fn(...args);
    } catch (error) { state = "failed"; throw error; }
  }]));
  env.__cpp_exception = new wasmApi.Tag({ parameters: ["i32"] });
  return {
    imports: { env },
    nodeCount() { return handles.size - 1; },
    bind(value) { checkMemory(value); memory = value; },
    commit() {
      if (state !== "staging") throw new Error("WASM DOM transaction is " + state);
      checkMemory(memory);
      if (!root.childNodes.length) throw new Error("WASM DOM root is empty");
      prior = Array.from(mount.childNodes);
      mount.replaceChildren(...Array.from(root.childNodes));
      state = "committed";
    },
    rollback() {
      if (prior) mount.replaceChildren(...prior);
      prior = undefined;
      root.replaceChildren();
      handles.clear();
      state = "aborted";
    },
  };
}

export function createParticleBackground(doc, ui, exports, view = doc.defaultView || globalThis) {
  const canvas = doc.getElementById("bios-fx");
  const note = doc.getElementById("fx-status");
  const button = doc.getElementById("fx-motion");
  if (!canvas || ui.getAttribute("data-fx-gl") !== "true") return null;
  const programs = [], buffers = [], textures = [];
  let gl, frame = 0, stopped = false, paused = false, last = null, elapsed = 0;
  const motion = view.matchMedia?.("(prefers-reduced-motion: reduce)");
  const report = (text) => { if (note) note.textContent = text; };
  const fps = [30, 60, 120].includes(Number(ui.getAttribute("data-fx-fps"))) ? Number(ui.getAttribute("data-fx-fps")) : 60;
  function bounded(value, fallback, min, max) { return Number.isFinite(value) && value > 0 ? Math.max(min, Math.min(max, value)) : fallback; }
  function suspend() { if (frame) view.cancelAnimationFrame(frame); frame = 0; last = null; }
  function stop() {
    if (stopped) return;
    stopped = true;
    suspend();
    doc.removeEventListener?.("visibilitychange", wake);
    view.removeEventListener?.("resize", wake);
    view.removeEventListener?.("pagehide", stop);
    motion?.removeEventListener?.("change", wake);
    button?.removeEventListener?.("click", toggle);
    canvas.removeEventListener("webglcontextlost", lost);
    if (gl && !gl.isContextLost()) {
      for (const program of programs) gl.deleteProgram(program);
      for (const buffer of buffers) gl.deleteBuffer(buffer);
      for (const texture of textures) gl.deleteTexture(texture);
    }
    canvas.hidden = true;
    ui.removeAttribute("data-fx-active");
  }
  function fail(error) { stop(); report("Background unavailable: " + String(error?.message || error)); }
  function lost(event) { event.preventDefault(); fail(new Error("WebGL context lost; reload to restore")); }
  function program(vertex, fragment) {
    const result = gl.createProgram();
    if (!result) throw new Error("WebGL program allocation failed");
    programs.push(result);
    for (const [type, source] of [[gl.VERTEX_SHADER, vertex], [gl.FRAGMENT_SHADER, fragment]]) {
      const shader = gl.createShader(type);
      if (!shader) throw new Error("WebGL shader allocation failed");
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      const ok = gl.getShaderParameter(shader, gl.COMPILE_STATUS);
      if (ok) gl.attachShader(result, shader);
      gl.deleteShader(shader);
      if (!ok) throw new Error("WebGL shader compilation failed");
    }
    gl.linkProgram(result);
    if (!gl.getProgramParameter(result, gl.LINK_STATUS)) throw new Error("WebGL program link failed");
    return result;
  }
  function buffer() {
    const result = gl.createBuffer();
    if (!result) throw new Error("WebGL buffer allocation failed");
    buffers.push(result);
    return result;
  }
  function floats(ptr, count) {
    const memory = exports.memory;
    if (!memory?.buffer || memory.buffer.byteLength > 16 * 1024 * 1024 || !Number.isInteger(ptr) || ptr < 0 || ptr % 4 ||
        ptr > memory.buffer.byteLength || count * 4 > memory.buffer.byteLength - ptr) throw new Error("Particle memory bounds violation");
    const values = new Float32Array(memory.buffer, ptr, count);
    if (!values.every(Number.isFinite)) throw new Error("Non-finite particle state");
    return values;
  }
  let draw;
  function schedule() {
    if (!stopped && !paused && !motion?.matches && !doc.hidden && !frame) frame = view.requestAnimationFrame(tick);
  }
  function tick(now) {
    frame = 0;
    if (stopped || paused || motion?.matches || doc.hidden) return;
    try {
      if (last === null || now - last >= 1000 / fps - 0.5) {
        const dt = last === null ? 0 : Math.max(0, Math.min(0.05, (now - last) / 1000));
        last = now;
        elapsed += dt;
        draw(dt);
      }
      schedule();
    } catch (error) { fail(error); }
  }
  function wake() {
    if (stopped) return;
    suspend();
    try { if (!doc.hidden) draw(0); } catch (error) { fail(error); return; }
    report(motion?.matches ? "Background: reduced motion (static)" : paused ? "Background paused" : "D/WASM particles + WebGL (OpenGL ES)");
    if (button) { button.disabled = Boolean(motion?.matches); button.textContent = paused ? "Resume background" : "Pause background"; }
    schedule();
  }
  function toggle() { paused = !paused; wake(); }
  try {
    for (const name of ["g6b_fx_data", "g6b_fx_count", "g6b_fx_step", "g6b_fx_logo"]) {
      if (typeof exports[name] !== "function") throw new Error("Missing D/WASM particle export: " + name);
    }
    if (typeof view.requestAnimationFrame !== "function") throw new Error("Animation frame scheduling unavailable");
    const count = exports.g6b_fx_count();
    if (!Number.isInteger(count) || count < 1 || count > 1024) throw new Error("Particle count budget exceeded");
    gl = canvas.getContext("webgl", { alpha: false, antialias: false, depth: false, stencil: false, preserveDrawingBuffer: false });
    if (!gl) throw new Error("WebGL is unavailable");
    const quadVertex = "attribute vec2 a; varying vec2 uv; uniform vec2 center; uniform vec2 scale; void main(){uv=a;gl_Position=vec4(center+a*scale,0.,1.);}";
    const field = program(quadVertex, "precision mediump float; varying vec2 uv; uniform vec2 origin; uniform float clock; uniform float aspect; void main(){vec2 p=(uv-origin)*vec2(aspect,1.);float r=length(p);float a=atan(p.y,p.x);float ring=exp(-90.*abs(r-.28))*(.45+.55*pow(abs(sin(a*6.+clock*.7)),12.));float halo=exp(-r*3.)*.13;vec3 color=vec3(.008,.01,.065)+vec3(.12,.025,.25)*halo+vec3(.06,.45,.66)*ring*.42;gl_FragColor=vec4(color,1.);}");
    const particles = program("attribute vec4 a; varying float glow; uniform float dpi; uniform float sizeMax; void main(){gl_Position=vec4(a.xy,0.,1.);gl_PointSize=min(sizeMax,a.w*dpi*2.);glow=a.z;}", "precision mediump float; varying float glow; void main(){float r=length(gl_PointCoord-vec2(.5))*2.;float alpha=pow(max(0.,1.-r),2.)*glow;vec3 c=mix(vec3(.6,.2,1.),vec3(.2,.9,1.),glow);gl_FragColor=vec4(c*alpha,alpha);}");
    const logo = program(quadVertex, "precision mediump float; varying vec2 uv; uniform sampler2D mark; void main(){gl_FragColor=texture2D(mark,vec2(uv.x*.5+.5,.5-uv.y*.5));}");
    const quad = buffer(), points = buffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1,1,-1,-1,1,1,1]), gl.STATIC_DRAW);
    const atlas = doc.createElement("canvas");
    atlas.width = 512; atlas.height = 128;
    const ctx = atlas.getContext("2d");
    if (!ctx) throw new Error("Wordmark texture unavailable");
    ctx.clearRect(0, 0, 512, 128);
    ctx.textAlign = "center";
    ctx.shadowColor = "#55dfff"; ctx.shadowBlur = 12;
    ctx.fillStyle = "#d7faff"; ctx.font = 'bold 58px "Courier New", monospace'; ctx.fillText("GSys", 256, 60);
    ctx.fillStyle = "#a2caff"; ctx.font = '30px "Courier New", monospace'; ctx.fillText("LibreCore", 256, 103);
    const texture = gl.createTexture();
    if (!texture) throw new Error("WebGL texture allocation failed");
    textures.push(texture);
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, atlas);
    const viewport = gl.getParameter(gl.MAX_VIEWPORT_DIMS);
    const sizeMax = gl.getParameter(gl.ALIASED_POINT_SIZE_RANGE)[1];
    function use(p, b, size) {
      gl.useProgram(p); gl.bindBuffer(gl.ARRAY_BUFFER, b);
      const a = gl.getAttribLocation(p, "a");
      gl.enableVertexAttribArray(a); gl.vertexAttribPointer(a, size, gl.FLOAT, false, 0, 0);
      return (name) => gl.getUniformLocation(p, name);
    }
    draw = (dt) => {
      const dpi = Math.min(bounded(view.devicePixelRatio, 1, 1, 4), bounded(Number(ui.getAttribute("data-fx-dpi")) / 96, 1, 1, 4));
      let w = Math.min(bounded(view.innerWidth, 640, 1, 7680) * dpi, bounded(Number(ui.getAttribute("data-fx-width")), 1920, 640, 7680), viewport[0]);
      let h = Math.min(bounded(view.innerHeight, 480, 1, 4320) * dpi, bounded(Number(ui.getAttribute("data-fx-height")), 1080, 480, 4320), viewport[1]);
      const scale = Math.min(1, Math.sqrt(8294400 / (w * h)));
      w = Math.max(1, Math.floor(w * scale)); h = Math.max(1, Math.floor(h * scale));
      if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
      gl.viewport(0, 0, w, h);
      exports.g6b_fx_step(dt);
      const data = floats(exports.g6b_fx_data(), count * 4), pos = floats(exports.g6b_fx_logo(), 2);
      for (let i = 0; i < count; i++) {
        if (Math.abs(data[i*4]) > 1 || Math.abs(data[i*4+1]) > 1 || data[i*4+2] < 0 || data[i*4+2] > 1 || data[i*4+3] < 0 || data[i*4+3] > 32) throw new Error("Particle state outside display bounds");
      }
      if (Math.abs(pos[0]) > .8 || Math.abs(pos[1]) > .8) throw new Error("Wordmark outside display bounds");
      gl.disable(gl.BLEND);
      let u = use(field, quad, 2);
      gl.uniform2f(u("center"), 0, 0); gl.uniform2f(u("scale"), 1, 1); gl.uniform2f(u("origin"), pos[0], pos[1]);
      gl.uniform1f(u("clock"), elapsed); gl.uniform1f(u("aspect"), w/h);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
      gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE);
      u = use(particles, points, 4);
      gl.bufferData(gl.ARRAY_BUFFER, data, gl.DYNAMIC_DRAW);
      gl.uniform1f(u("dpi"), dpi); gl.uniform1f(u("sizeMax"), sizeMax);
      gl.drawArrays(gl.POINTS, 0, count);
      gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
      u = use(logo, quad, 2);
      gl.uniform2f(u("center"), pos[0], pos[1]); gl.uniform2f(u("scale"), .22, Math.min(.16, .055*w/h));
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, texture); gl.uniform1i(u("mark"), 0);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    };
    canvas.hidden = false;
    ui.setAttribute("data-fx-active", "true");
    canvas.addEventListener("webglcontextlost", lost);
    doc.addEventListener?.("visibilitychange", wake);
    view.addEventListener?.("resize", wake);
    view.addEventListener?.("pagehide", stop);
    motion?.addEventListener?.("change", wake);
    button?.addEventListener?.("click", toggle);
    wake();
  } catch (error) { fail(error); }
  return { stop, paused: () => paused || Boolean(motion?.matches) };
}

export function createComputePool(url, limit, platform = globalThis) {
  if (!/^\/(?!\/)[A-Za-z0-9/_.-]+\.js$/.test(url) || url.split("/").some((part) => part === "." || part === "..")) {
    throw new DOMException("Worker script must be a local kernel path", "SecurityError");
  }
  if (typeof platform.Worker !== "function") throw new DOMException("Dedicated workers unavailable", "NotSupportedError");
  if (!Number.isInteger(limit) || limit < 1 || limit > 64) throw new DOMException("Invalid worker limit", "QuotaExceededError");
  const hardware = Number(platform.navigator?.hardwareConcurrency);
  const size = Math.min(limit, Number.isInteger(hardware) && hardware > 1 ? hardware - 1 : 1);
  const slots = [], queue = [], tasks = new Map();
  let next = 0, closed = false, pendingBytes = 0;
  const error = (name, message) => new DOMException(message, name);
  function finish(task, failure, value) {
    if (!tasks.delete(task.id)) return;
    pendingBytes -= task.bytes;
    if (task.timer) platform.clearTimeout(task.timer);
    task.signal?.removeEventListener("abort", task.abort);
    if (failure) task.reject(failure); else task.resolve(value);
    platform.queueMicrotask(pump);
  }
  function retire(slot, failure) {
    slot.worker.terminate();
    const index = slots.indexOf(slot);
    if (index >= 0) slots.splice(index, 1);
    const task = slot.task; slot.task = null;
    if (task) finish(task, failure);
  }
  function pump() {
    if (closed) return;
    while (queue.length) {
      let slot = slots.find((entry) => !entry.task);
      if (!slot && slots.length >= size) return;
      const task = queue.shift();
      if (!tasks.has(task.id)) continue;
      if (!slot) {
        try {
          slot = { worker: new platform.Worker(url, { type: "module", name: "GSys LibreCore compute" }), task: null };
          slots.push(slot);
          slot.worker.onmessage = (event) => {
            const current = slot.task;
            if (!current || event.data?.id !== current.id) return;
            if (event.data.error) {
              slot.task = null;
              const name = ["AbortError", "DataError", "DataCloneError", "InvalidAccessError", "NotSupportedError", "OperationError", "QuotaExceededError"].includes(event.data.error.name) ? event.data.error.name : "OperationError";
              finish(current, error(name, "Compute operation failed"));
            } else {
              const result = event.data.result;
              if (!(result?.data instanceof ArrayBuffer) || result.data.byteLength > 1048592 ||
                  (result.iv !== undefined && (!(result.iv instanceof ArrayBuffer) || result.iv.byteLength !== 12))) {
                retire(slot, error("DataError", "Invalid worker response"));
                return;
              }
              slot.task = null;
              finish(current, null, result);
            }
          };
          slot.worker.onerror = (event) => { event.preventDefault?.(); retire(slot, error("OperationError", "Worker execution failed")); };
          slot.worker.onmessageerror = () => retire(slot, error("DataCloneError", "Worker message could not be cloned"));
        } catch (failure) { finish(task, failure); continue; }
      }
      slot.task = task;
      task.timer = platform.setTimeout(() => retire(slot, error("TimeoutError", "Compute deadline exceeded")), 30000);
      try {
        const transfer = [task.job.data];
        if (task.job.iv) transfer.push(task.job.iv);
        if (task.job.additionalData) transfer.push(task.job.additionalData);
        slot.worker.postMessage({ id: task.id, job: task.job }, transfer);
      } catch (failure) { retire(slot, failure); }
    }
  }
  return {
    run(job, { signal } = {}) {
      if (closed) return Promise.reject(error("InvalidStateError", "Compute pool terminated"));
      if (signal?.aborted) return Promise.reject(error("AbortError", "Compute request cancelled"));
      if (tasks.size >= 128 || next >= Number.MAX_SAFE_INTEGER) return Promise.reject(error("QuotaExceededError", "Compute queue full"));
      if (!job || !(job.data instanceof ArrayBuffer) || job.data.byteLength > (job.kind === "decrypt" ? 1048592 : 1048576) ||
          (job.iv !== undefined && (!(job.iv instanceof ArrayBuffer) || job.iv.byteLength !== 12)) ||
          (job.additionalData !== undefined && (!(job.additionalData instanceof ArrayBuffer) || job.additionalData.byteLength > 65536))) {
        return Promise.reject(error("DataError", "Invalid compute buffer"));
      }
      const bytes = job.data.byteLength + (job.iv?.byteLength || 0) + (job.additionalData?.byteLength || 0);
      if (pendingBytes + bytes > 16777216) return Promise.reject(error("QuotaExceededError", "Compute buffer budget exceeded"));
      const copied = { kind: job.kind, algorithm: job.algorithm, key: job.key, data: job.data.slice(0),
        iv: job.iv?.slice(0), additionalData: job.additionalData?.slice(0) };
      return new Promise((resolve, reject) => {
        const task = { id: ++next, job: copied, bytes, resolve, reject, signal, timer: 0, abort: null };
        task.abort = () => {
          const slot = slots.find((entry) => entry.task === task);
          if (slot) retire(slot, error("AbortError", "Compute request cancelled"));
          else {
            const index = queue.indexOf(task);
            if (index >= 0) queue.splice(index, 1);
            finish(task, error("AbortError", "Compute request cancelled"));
          }
        };
        tasks.set(task.id, task);
        pendingBytes += bytes;
        signal?.addEventListener("abort", task.abort, { once: true });
        queue.push(task);
        pump();
      });
    },
    stats() { return { workers: slots.length, active: slots.filter((slot) => slot.task).length, queued: queue.length, limit: size }; },
    terminate() {
      if (closed) return;
      closed = true;
      for (const slot of [...slots]) retire(slot, error("AbortError", "Compute pool terminated"));
      for (const task of [...tasks.values()]) finish(task, error("AbortError", "Compute pool terminated"));
      queue.length = 0;
    },
  };
}

function localWasmUrl(url) {
  return /^\/(?!\/)[A-Za-z0-9/_.-]+\.wasm$/.test(url) && !url.split("/").some((part) => part === "." || part === "..");
}

let activeBrowserApp;

export function computeBios(job, options) {
  if (!activeBrowserApp) return Promise.reject(new DOMException("Browser worker host unavailable", "InvalidStateError"));
  return activeBrowserApp.compute(job, options);
}

export function createBrowserApp(doc, fetchFn = globalThis.fetch.bind(globalThis), wasmApi = globalThis.WebAssembly) {
  const ui = doc.getElementById("bios-ui");
  let computePool;
  async function compute(job, options) {
    const url = ui?.getAttribute("data-worker-url");
    if (!url) throw new DOMException("Compute workers disabled by BoardSpec", "NotSupportedError");
    if (!computePool) computePool = createComputePool(url, Number(ui.getAttribute("data-worker-limit")), doc.defaultView || globalThis);
    return computePool.run(job, options);
  }
  const status = doc.getElementById("status");
  const menus = Array.from(doc.querySelectorAll("[data-menu]"));
  const links = Array.from(doc.querySelectorAll("[data-menu-link]"));
  const targets = new Map();
  for (const node of doc.querySelectorAll("[data-fetch]")) {
    const url = node.getAttribute("data-fetch");
    if (/^\/bios\/(menu(?:\/(?:main|cpu|memory|uncore|devices|boot|settings))?|clocks|bootloader|settings(?:\/usb)?|usb\/ls|files(?:\/(?:fat32|ntfs|ext4))?)$/.test(url)) {
      targets.set(url, node);
    }
  }
  const allowed = new Set(targets.keys());
  for (const name of ["cpu", "uncore"]) {
    if (allowed.has("/bios/menu/" + name)) allowed.add("/bios/" + name);
  }
  const pending = new Map();
  const initial = ui && ui.getAttribute("data-start-menu");
  let selected = menus.some((node) => node.getAttribute("data-menu") === initial) ? initial : "main";
  let started = false;
  function message(value) { if (status) status.textContent = value; }
  function show(id) {
    if (!menus.some((node) => node.getAttribute("data-menu") === id)) return;
    selected = id;
    for (const menu of menus) menu.hidden = menu.getAttribute("data-menu") !== id;
    for (const link of links) {
      if (link.getAttribute("data-menu-link") === id) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    }
  }
  function fallback(error, context) {
    for (const menu of menus) menu.hidden = false;
    message("Static view: " + context + " failed: " + String(error && error.message || error));
  }
  function paint(url, data) {
    const node = targets.get(url);
    if (!node) return;
    const menu = node.getAttribute("data-menu");
    if (menu) {
      if (!data || data.id !== menu || typeof data.title !== "string" || !Array.isArray(data.items)) {
        throw new Error("Invalid menu response: " + url);
      }
      const rows = Array.from(node.querySelectorAll("[data-item]"));
      if (data.items.length !== rows.length) throw new Error("Menu row count mismatch: " + menu);
      const seen = new Set();
      for (const item of data.items) {
        if (!item || typeof item.id !== "string" || typeof item.label !== "string" || typeof item.value !== "string" ||
            typeof item.writable !== "boolean" || seen.has(item.id) || !rows.some((row) => row.getAttribute("data-item") === item.id)) {
          throw new Error("Invalid menu row: " + menu);
        }
        seen.add(item.id);
      }
      const title = doc.getElementById(menu + "-title");
      if (title) title.textContent = data.title;
      for (const item of data.items) {
        const value = doc.getElementById("row-" + menu + "-" + item.id);
        const label = doc.getElementById("label-" + menu + "-" + item.id);
        const access = doc.getElementById("access-" + menu + "-" + item.id);
        if (value) value.textContent = item.value;
        if (label) label.textContent = item.label;
        if (access) access.textContent = item.writable ? "Writable in spec; editing unavailable" : "Read-only";
        rows.find((row) => row.getAttribute("data-item") === item.id).setAttribute("data-writable", String(item.writable));
      }
    } else if (url !== "/bios/menu") {
      node.textContent = JSON.stringify(data, null, 2);
    }
  }
  async function request(path) {
    const url = path === "/bios/cpu" || path === "/bios/uncore" ? "/bios/menu/" + path.slice(6) : path;
    if (!targets.has(url)) return;
    if (pending.has(url)) return pending.get(url);
    const work = (async () => {
      const response = await fetchFn(url, { method: "GET", credentials: "same-origin", cache: "no-store", redirect: "error" });
      if (!response.ok) throw new Error(url + " HTTP " + response.status);
      paint(url, await response.json());
    })();
    pending.set(url, work);
    try { await work; } finally { pending.delete(url); }
  }
  async function refresh() {
    try {
      for (const url of targets.keys()) await request(url);
      message(targets.size ? "UI-BOOT: values refreshed; read-only setup" : "Static view: browser refresh unavailable");
    } catch (error) { fallback(error, "Refresh"); }
  }
  async function navigate(id) {
    show(id);
    try {
      await request("/bios/menu/" + selected);
      message(targets.has("/bios/menu/" + selected) ? "UI-BOOT: " + selected + " menu; read-only setup" : "Static view: " + selected + " menu; browser refresh unavailable");
    } catch (error) { fallback(error, "Menu refresh"); }
  }
  async function handleKey(event) {
    if (event.defaultPrevented || event.repeat || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey ||
        event.isComposing || event.target?.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(event.target?.tagName || "")) return;
    const index = menus.findIndex((node) => node.getAttribute("data-menu") === selected);
    if (event.key === "F10") {
      event.preventDefault();
      await refresh();
    } else if (index >= 0 && ["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) {
      event.preventDefault();
      const next = event.key === "Home" ? 0 : event.key === "End" ? menus.length - 1 :
        (index + (event.key === "ArrowLeft" ? menus.length - 1 : 1)) % menus.length;
      await navigate(menus[next].getAttribute("data-menu"));
    }
  }
  return {
    refresh,
    navigate,
    handleKey,
    compute,
    terminateWorkers() { computePool?.terminate(); computePool = undefined; },
    async start() {
      if (started || !ui) return;
      started = true;
      for (const link of links) {
        link.addEventListener("click", async (event) => {
          event.preventDefault();
          await navigate(link.getAttribute("data-menu-link"));
        });
      }
      const button = doc.getElementById("refresh");
      if (button) button.addEventListener("click", refresh);
      ui.addEventListener("keydown", handleKey);
      const workerButton = doc.getElementById("worker-check");
      workerButton?.addEventListener("click", async () => {
        const note = doc.getElementById("worker-status");
        if (note) note.textContent = "Compute worker pending; setup remains interactive";
        try {
          const result = await compute({ kind: "digest", algorithm: "SHA-256", data: new TextEncoder().encode("GSys LibreCore").buffer });
          if (note) note.textContent = "Dedicated worker SHA-256: " + Array.from(new Uint8Array(result.data), (b) => b.toString(16).padStart(2, "0")).join("");
        } catch (error) { if (note) note.textContent = "Compute worker: " + error.name; }
      });
      doc.defaultView?.addEventListener("pagehide", () => { computePool?.terminate(); computePool = undefined; }, { once: true });
      show(selected);
      const libwasmReady = loadLibwasm();
      const wasmUrl = ui.getAttribute("data-wasm-url");
      if (wasmUrl) {
        const host = createWasmHost(doc, allowed, request);
        try {
          if (!wasmApi) throw new Error("WebAssembly is unavailable");
          if (!localWasmUrl(wasmUrl)) throw new Error("WASM URL must be local");
          const response = await fetchFn(wasmUrl, { method: "GET", credentials: "same-origin", redirect: "error" });
          if (!response.ok) throw new Error("WASM HTTP " + response.status);
          const bytes = await response.arrayBuffer();
          if (bytes.byteLength < 8 || bytes.byteLength > 1024 * 1024) throw new Error("WASM module size budget exceeded");
          const { instance } = await wasmApi.instantiate(bytes, host.imports);
          host.bind(instance.exports.memory);
          if (typeof instance.exports._start !== "function") throw new Error("WASM _start export missing");
          instance.exports._start();
          await host.drain();
        } catch (error) {
          host.rollback();
          fallback(error, "WASM");
          return;
        }
      }
      await libwasmReady;
      await refresh();
      async function loadLibwasm() {
        const libwasmUrl = ui.getAttribute("data-libwasm-url");
        const libwasmRoot = doc.getElementById("libwasm-root");
        if (!libwasmUrl || !libwasmRoot) return;
        const note = doc.getElementById("libwasm-status");
        let host;
        try {
          if (!wasmApi) throw new Error("WebAssembly is unavailable");
          if (!localWasmUrl(libwasmUrl)) throw new Error("WASM URL must be local");
          host = createLibwasmHost(doc, libwasmRoot, wasmApi);
          const response = await fetchFn(libwasmUrl, { method: "GET", credentials: "same-origin", redirect: "error" });
          if (!response.ok) throw new Error("WASM HTTP " + response.status);
          const bytes = await response.arrayBuffer();
          if (bytes.byteLength < 8 || bytes.byteLength > 1024 * 1024) throw new Error("WASM module size budget exceeded");
          const { instance } = await wasmApi.instantiate(bytes, host.imports);
          host.bind(instance.exports.memory);
          if (typeof instance.exports._start !== "function") throw new Error("WASM _start export missing");
          const heap = instance.exports.__heap_base?.value;
          if (!Number.isInteger(heap) || heap < 0 || heap > instance.exports.memory.buffer.byteLength) {
            throw new Error("WASM heap base export invalid");
          }
          // LDC/libwasm `_start(heap_base)`; extra args on 0-param exports are ignored.
          instance.exports._start(heap);
          host.commit();
          if (note) note.textContent = "libwasm component scaffold: " + host.nodeCount() + " allocated nodes (LDC wasm-eh cell)";
          createParticleBackground(doc, ui, instance.exports);
        } catch (error) {
          if (host) host.rollback();
          if (note) note.textContent = "libwasm SPA unavailable: " + String(error && error.message || error);
        }
      }
    },
  };
}

if (typeof document !== "undefined") {
  const app = createBrowserApp(document);
  activeBrowserApp = app;
  void app.start();
}
