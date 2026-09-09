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
  const pending = new Set();
  const rejected = new Set();
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
        // env.await/env.throw — the host correlate of the guest's bounded
        // AWAIT_SLOTS=4 queue: await() claims a slot and returns its index
        // (-1 when full — guest parity), throw(slot) rejects that slot
        // (the targeted reject, guest parity with a0>=0); drain() resolves
        // every pending slot.
        await() {
          if (pending.size >= 4) return -1;
          let slot = 0;
          while (pending.has(slot)) slot++;
          pending.add(slot);
          rejected.delete(slot); // reset if the slot is being reused
          log("AWAIT pending " + slot);
          return slot;
        },
        throw(slot) {
          if (slot < 0) {
            const newest = Array.from(pending).pop();
            if (newest === undefined) {
              log("AWAIT-THROW none");
              return;
            }
            slot = newest;
          }
          if (!pending.delete(slot)) {
            log("AWAIT-THROW none");
            return;
          }
          rejected.add(slot);
          log("AWAIT-THROW /bios/menu");
        },
        catch(slot) {
          // Query-only: does not clear the rejected state (guest parity).
          return rejected.has(slot) ? 1 : 0;
        },
        addEventListener(tPtr, tLen, tyPtr, tyLen, listener, capture) {
          log("WASM addEventListener " + text(tPtr, tLen) + " " + text(tyPtr, tyLen) + " " + listener + " " + capture);
        },
        removeEventListener(listener) {
          log("WASM removeEventListener " + listener);
        },
        dispatchEvent(tPtr, tLen, tyPtr, tyLen, dPtr, dLen) {
          log("WASM dispatchEvent " + text(tPtr, tLen) + " " + text(tyPtr, tyLen) + " " + text(dPtr, dLen));
          return 1;
        },
      },
    },
    bind(value) {
      if (!value || !value.buffer || typeof value.buffer.byteLength !== "number") throw new Error("WASM memory export missing");
      memory = value;
    },
    async drain() {
      while (queue.length) await request(queue.shift());
      for (const slot of pending) {
        log("AWAIT-GET /bios/menu");
      }
      pending.clear();
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

// libwasm `NodeType` ordinals (libwasm/source/libwasm/types.d).
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
export function createLibwasmHost(doc, mount, wasmApi = globalThis.WebAssembly, opts = {}) {
  if (!mount || typeof mount.replaceChildren !== "function") throw new Error("libwasm mount unavailable");
  if (!wasmApi || typeof wasmApi.Tag !== "function") throw new Error("WebAssembly exception tags unavailable");
  const asyncify = opts.asyncify ? new LibwasmAsyncify() : null;
  const fetchFn = opts.fetchFn || (() => { throw new Error("libwasm fetchFn not provided"); });
  // B61 refcounted libwasm object table. `struct JsHandle` frees on destruct
  // and calls copyObjectRef on copy, so entries carry a reference count and a
  // release at zero. Handles 1 (staging DOM root) and 2 (BoardSpec scope) are
  // roots the guest never frees. See architecture/LIBWASM-ABI.md §3.
  const OBJ_BASE = 0x100000, OBJ_MAX = 4096;
  const objects = new Map();
  const objFree = [];
  let objNextSlot = 0;
  // Optional browser instance (createBrowserContext). The bridge is ONE import
  // plus a reserved root per binding: the engine consumes the generic
  // `bindings()` map, so the context stays engine-agnostic and a context with
  // extra globals needs no change here.
  const ctx = opts.context || null;
  const globalRoots = new Map();       // name -> object handle
  const globalRootHandles = new Set(); // the same handles, for the root check
  const objIsRoot = (h) => h === 1 || h === 2 || globalRootHandles.has(h);
  function objAdd(value) {
    if (objects.size >= OBJ_MAX) throw new Error("libwasm object budget exceeded");
    const slot = objFree.length ? objFree.pop() : objNextSlot++;
    const handle = OBJ_BASE + slot;
    objects.set(handle, { value, refs: 1 });
    return handle;
  }
  function objEntry(handle, what) {
    if (objIsRoot(handle)) throw new Error("libwasm handle " + handle + " is a protected root");
    const e = objects.get(handle);
    if (!e) throw new Error("libwasm " + what + " on freed handle " + handle);
    return e;
  }
  function objGet(handle) {
    const e = objects.get(handle);
    return e ? e.value : undefined;
  }
  const tags = new Set("a abbr address article aside b bdi bdo blockquote br button caption cite code col colgroup data datalist dd del dfn div dl dt em fieldset figcaption figure footer h1 h2 h3 h4 h5 h6 header hr i input ins kbd label legend li main mark meter nav ol optgroup option output p pre progress q rb rp rt rtc ruby s samp section select small span strong sub sup table tbody td textarea tfoot th thead time tr u ul var wbr".split(" "));
  const root = doc.createElement("div");
  const handles = new Map([[1, root]]);
  const decoder = new TextDecoder("utf-8", { fatal: true });
  const encoder = new TextEncoder();
  let memory, prior, wasmInstance;
  let next = 2, calls = 0, stringBytes = 0, stringPool = 0;
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
  function writeString(raw, s) {
    checkMemory(memory);
    if (!Number.isInteger(raw) || raw < 0 || raw + 8 > memory.buffer.byteLength) {
      throw new Error("WASM string result out of bounds");
    }
    const bytes = encoder.encode(String(s));
    if (bytes.length > 65536) throw new Error("WASM string result too long");
    let ptr;
    if (wasmInstance?.exports?.allocString && typeof wasmInstance.exports.allocString === "function") {
      ptr = wasmInstance.exports.allocString(bytes.length);
      if (!Number.isInteger(ptr) || ptr < 0) throw new Error("WASM allocString failed");
    } else {
      const pageSize = 65536;
      let end = memory.buffer.byteLength;
      if (stringPool === 0) stringPool = end;
      if (stringPool + bytes.length > end) {
        const delta = Math.ceil((stringPool + bytes.length - end) / pageSize);
        const old = memory.grow(delta);
        if (old < 0) throw new Error("WASM memory grow failed");
        stringPool = end;
        end = memory.buffer.byteLength;
      }
      ptr = stringPool;
      stringPool += bytes.length;
    }
    new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
    const u32 = new Uint32Array(memory.buffer, raw, 2);
    u32[0] = bytes.length;
    u32[1] = ptr;
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
  // B67 Lodash backend. `struct Lodash` ships a JSON command buffer through
  // the twelve ldexec_* imports; libwasm's own putLocal emits one of five fixed
  // arrow-function iteratees whose body just calls the guest's indirect
  // function table. We recognise those by identity and dispatch into wasm —
  // the iteratee runs in the guest, so no host `eval` is needed or accepted.
  // Anything else `=(...)` is refused. See architecture/LIBWASM-ABI.md §5.
  const CB_BOILERPLATE = new Set([
    "(o,s)=>{let hndl=ao(o);let str=es(0,s,null,true);return !!sifg(cbPtr)(cbCtx,str[0],str[1],hndl);}",
    "(o,i)=>{let hndl=ao(o);return !!sifg(cbPtr)(cbCtx,BigInt(i),hndl);}",
    "(s1,s2)=>{let str1=es(0,s1,null,true);let str2=es(0,s2,null,true);return !!sifg(cbPtr)(cbCtx,str2[0],str2[1],str1[0],str1[1]);}",
    "(s,i)=>{let str=es(0,s,null,true);return !!sifg(cbPtr)(cbCtx,BigInt(i),str[0],str[1]);}",
    "(i1,i2)=>{return !!sifg(cbPtr)(cbCtx, BigInt(i2), BigInt(i1));}",
  ]);
  const LODASH_MAX_COMMANDS = 256, LODASH_MAX_COLLECTION = 4096;

  // String(v) that agrees with g6b-js JsValue::to_js_string in the kernel lane.
  // Plain String() throws on a null-prototype object (libwasm_add__object), and
  // the two backends must not disagree about a chain's result.
  function jsString(v) {
    if (v === null) return "null";
    if (v === undefined) return "undefined";
    if (Array.isArray(v)) return v.map((x) => (x === null || x === undefined ? "" : jsString(x))).join(",");
    if (typeof v === "object") return "[object Object]";
    return String(v);
  }

  function lodashSigil(raw) {
    if (raw.startsWith("\\")) return { v: raw.slice(1) };
    if (!raw.startsWith("=")) return { v: raw };
    const e = raw.slice(1);
    if (e === "true") return { v: true };
    if (e === "false") return { v: false };
    if (e === "null") return { v: null };
    if (e === "undefined") return { v: undefined };
    if (e === "cb" || CB_BOILERPLATE.has(e)) return { cb: true };
    const n = Number(e);
    if (e !== "" && Number.isFinite(n)) return { v: n };
    throw new Error("libwasm lodash refuses host eval of " + JSON.stringify(e));
  }
  function lodashParse(src) {
    const raw = JSON.parse(src.endsWith(",]") ? src.slice(0, -2) + "]" : src);
    if (!Array.isArray(raw)) throw new Error("libwasm lodash command buffer is not an array");
    if (raw.length > LODASH_MAX_COMMANDS) throw new Error("libwasm lodash budget exceeded: commands");
    const param = (p) => (typeof p === "string" ? lodashSigil(p) : { v: p });
    return raw.map((c) => {
      if (c && typeof c.local === "string") return { local: c.local, value: param(c.value) };
      if (c && typeof c.func === "string") {
        if (!Array.isArray(c.params)) throw new Error("libwasm lodash func without params");
        return { func: c.func, params: c.params.map(param) };
      }
      throw new Error("malformed libwasm lodash command");
    });
  }
  /** Bind the guest delegate at (ctx, ptr) as a native predicate. */
  function guestIteratee(ctx, ptr) {
    if (!(ptr > 0)) return null;
    const table = wasmInstance?.exports?.__indirect_function_table;
    if (!table || typeof table.get !== "function") return null;
    const fn = table.get(ptr);
    if (typeof fn !== "function") return null;
    return (value, key) => {
      // The generated boilerplates box the element as a handle and pass the
      // key either as a string pair or a BigInt, matching the five shapes.
      const h = objAdd(value);
      try {
        return !!fn(ctx, typeof key === "string" ? key.length : key, h);
      } finally { functions.libwasm_removeObject(h); }
    };
  }
  function lodashRun(init, commandsSrc, cbCtx, cbPtr) {
    const commands = lodashParse(commandsSrc);
    const cb = guestIteratee(cbCtx, cbPtr);
    const list = (v) => {
      const out = Array.isArray(v) ? v
        : typeof v === "string" ? Array.from(v)
        : v === null || v === undefined ? []
        : typeof v === "object" ? Object.values(v) : [v];
      if (out.length > LODASH_MAX_COLLECTION) throw new Error("libwasm lodash budget exceeded: collection");
      return out;
    };
    const need = (p, m) => { if (!p || p.cb) throw new Error("libwasm lodash " + m + " needs a value parameter"); return p.v; };
    const pred = (params, m) => {
      if (!params.length) return (v) => !!v;
      if (params[0].cb) {
        if (!cb) throw new Error("libwasm lodash " + m + " needs a guest iteratee and none is bound");
        return cb;
      }
      const prop = params[0].v;
      return (v) => !!(v && typeof v === "object" && v[prop]);
    };
    let acc = init;
    for (const c of commands) {
      if (c.local) continue; // `cb` names the callback; it has no value
      const p = c.params;
      switch (c.func) {
        case "identity": break;
        case "defaultTo": acc = acc === null || acc === undefined || Number.isNaN(acc) ? need(p[0], "defaultTo") : acc; break;
        case "toString": acc = jsString(acc); break;
        case "toNumber": acc = Number(acc); break;
        case "size": acc = typeof acc === "string" ? Array.from(acc).length : list(acc).length; break;
        case "first": case "head": acc = list(acc)[0]; break;
        case "last": { const l = list(acc); acc = l[l.length - 1]; break; }
        case "keys": acc = Array.isArray(acc) ? list(acc).map((_, i) => i) : Object.keys(acc ?? {}); break;
        case "values": acc = list(acc); break;
        case "reverse": acc = list(acc).reverse(); break;
        case "compact": acc = list(acc).filter(Boolean); break;
        case "uniq": acc = Array.from(new Set(list(acc))); break;
        case "flatten": acc = list(acc).flat(1); break;
        case "sortBy": acc = list(acc).slice().sort((a, b) => jsString(a) < jsString(b) ? -1 : jsString(a) > jsString(b) ? 1 : 0); break;
        case "join": acc = list(acc).map(jsString).join(p.length ? jsString(need(p[0], "join")) : ","); break;
        case "concat": acc = list(acc).concat(...p.map((x) => need(x, "concat"))); break;
        case "chunk": { const n = Math.max(1, Number(need(p[0], "chunk"))), l = list(acc), o = []; for (let i = 0; i < l.length; i += n) o.push(l.slice(i, i + n)); acc = o; break; }
        case "take": acc = list(acc).slice(0, Math.max(0, Number(need(p[0], "take")))); break;
        case "drop": acc = list(acc).slice(Math.max(0, Number(need(p[0], "drop")))); break;
        case "nth": { const l = list(acc), i = Number(need(p[0], "nth")); acc = l[i < 0 ? l.length + i : i]; break; }
        case "trim": acc = jsString(acc).trim(); break;
        case "toUpper": acc = jsString(acc).toUpperCase(); break;
        case "toLower": acc = jsString(acc).toLowerCase(); break;
        case "capitalize": { const s = jsString(acc); acc = s.charAt(0).toUpperCase() + s.slice(1).toLowerCase(); break; }
        case "sum": acc = list(acc).reduce((a, b) => a + Number(b), 0); break;
        case "min": acc = list(acc).reduce((a, b) => (Number(b) < Number(a) ? b : a), list(acc)[0]); break;
        case "max": acc = list(acc).reduce((a, b) => (Number(b) > Number(a) ? b : a), list(acc)[0]); break;
        case "includes": acc = typeof acc === "string" ? acc.includes(jsString(need(p[0], "includes"))) : list(acc).includes(need(p[0], "includes")); break;
        case "indexOf": acc = list(acc).indexOf(need(p[0], "indexOf")); break;
        case "get": { let cur = acc; for (const seg of jsString(need(p[0], "get")).split(".")) cur = cur == null ? undefined : cur[seg]; acc = cur === undefined && p[1] ? need(p[1], "get") : cur; break; }
        case "filter": { const f = pred(p, "filter"); acc = list(acc).filter((v, i) => f(v, i)); break; }
        case "reject": { const f = pred(p, "reject"); acc = list(acc).filter((v, i) => !f(v, i)); break; }
        case "map": { const f = pred(p, "map"); acc = list(acc).map((v, i) => !!f(v, i)); break; }
        case "find": { const f = pred(p, "find"); acc = list(acc).find((v, i) => f(v, i)); break; }
        case "every": { const f = pred(p, "every"); acc = list(acc).every((v, i) => f(v, i)); break; }
        case "some": { const f = pred(p, "some"); acc = list(acc).some((v, i) => f(v, i)); break; }
        case "countBy": { const f = pred(p, "countBy"), o = { true: 0, false: 0 }; list(acc).forEach((v, i) => o[f(v, i) ? "true" : "false"]++); acc = o; break; }
        default: throw new Error("libwasm lodash method " + JSON.stringify(c.func) + " is not implemented");
      }
    }
    return acc;
  }
  /** The twelve ldexec_* imports: 3 init kinds x 4 result kinds. */
  function ldexecImports() {
    const out = {};
    const seed = {
      Handle: (a) => ({ init: objGet(a[0]), n: 1 }),
      long: (a) => ({ init: Number(a[0]), n: 1 }),
      string: (a) => ({ init: text(a[0], a[1]), n: 2, evalTail: true }),
    };
    for (const kind of ["Handle", "long", "string"]) {
      for (const ret of ["string", "long", "double", "Handle"]) {
        out[`ldexec_${kind}__${ret}`] = (...args) => {
          let i = 0;
          const raw = ret === "string" ? args[i++] : 0;
          const s = seed[kind](args.slice(i));
          i += s.n;
          const commands = text(args[i], args[i + 1]); i += 2;
          const cbCtx = args[i++], cbPtr = args[i++];
          i += 2; // onError (ctx, ptr): a thrown chain is a host trap here
          if (s.evalTail && args[i++]) {
            throw new Error("libwasm lodash refuses an eval seed: no host JS evaluator");
          }
          const v = lodashRun(s.init, commands, cbCtx, cbPtr);
          if (ret === "string") return writeString(raw, v === undefined || v === null ? "" : jsString(v));
          if (ret === "long") return BigInt(Math.trunc(Number(v)) || 0);
          if (ret === "double") return Number(v);
          return typeof v === "number" && Number.isInteger(v) && v >= 0x100000 ? v : objAdd(v);
        };
      }
    }
    return out;
  }

  // B63 typed object getter/call imports.  The object table is the receiver;
  // DOM handles are resolved lazily so the two handle spaces can merge later.
  const libwasmObjectAccess = (() => {
    const out = {};
    const resolve = (handle) => {
      if (handle < OBJ_BASE) {
        if (!handles.has(handle)) throw new Error("WASM object resolve unknown DOM handle " + handle);
        return handles.get(handle);
      }
      const e = objects.get(handle);
      if (!e) throw new Error("WASM object resolve unknown handle " + handle);
      return e.value;
    };
    const convertTo = (v, type) => {
      switch (type) {
        case "int": return Number(v) | 0;
        case "uint": return Number(v) >>> 0;
        case "short": return (Number(v) << 16) >> 16;
        case "ushort": return Number(v) & 0xFFFF;
        case "bool": return (v === true || v === 1 || (typeof v === "number" && v !== 0)) ? 1 : 0;
        case "float": return Math.fround(Number(v));
        case "double": return Number(v);
        case "long": return BigInt.asIntN(64, BigInt(Math.trunc(Number(v))));
        case "ulong": return BigInt.asUintN(64, BigInt(Math.trunc(Number(v))));
        case "Handle": return objAdd(v);
        default: throw new Error("libwasm unsupported object getter type " + type);
      }
    };
    const readArg = (type, args, at) => {
      switch (type) {
        case "string": return text(args[at.i++], args[at.i++]);
        case "int": return args[at.i++] | 0;
        case "uint": return args[at.i++] >>> 0;
        case "bool": return args[at.i++] !== 0;
        case "long": return BigInt.asIntN(64, BigInt(args[at.i++]));
        case "ulong": return BigInt.asUintN(64, BigInt(args[at.i++]));
        case "float": return Math.fround(args[at.i++]);
        case "double": return Number(args[at.i++]);
        case "Handle": return resolve(args[at.i++]);
        default: throw new Error("libwasm unsupported object call arg type " + type);
      }
    };
    const getter = (handle, len, ptr, type) => {
      const prop = text(len, ptr);
      const obj = resolve(handle);
      if (obj == null) throw new Error("libwasm object getter on null receiver");
      const boxed = Object(obj);
      if (!(prop in boxed)) throw new Error("libwasm object has no property " + prop);
      return convertTo(boxed[prop], type);
    };
    for (const t of ["int", "uint", "ushort", "bool", "float", "double", "Handle"]) {
      out["Object_Getter__" + t] = (handle, len, ptr) => getter(handle, len, ptr, t);
    }
    out["Object_Getter__string"] = (raw, handle, len, ptr) => {
      const prop = text(len, ptr);
      const obj = resolve(handle);
      if (obj == null) throw new Error("libwasm object getter on null receiver");
      const boxed = Object(obj);
      if (!(prop in boxed)) throw new Error("libwasm object has no property " + prop);
      writeString(raw, jsString(boxed[prop]));
    };
    const callSpecs = [
      ["", [], "void"],
      ["string", ["string"], "void"],
      ["uint", ["uint"], "void"],
      ["int", ["int"], "void"],
      ["bool", ["bool"], "void"],
      ["double", ["double"], "void"],
      ["float", ["float"], "void"],
      ["Handle", ["Handle"], "void"],
      ["string_string", ["string", "string"], "void"],
      ["double_double", ["double", "double"], "void"],
      ["string", ["string"], "Handle"],
      ["uint", ["uint"], "Handle"],
      ["int", ["int"], "Handle"],
      ["bool", ["bool"], "Handle"],
      ["Handle", ["Handle"], "Handle"],
      ["string_string", ["string", "string"], "Handle"],
      ["string", ["string"], "bool"],
      ["string", ["string"], "string"],
      ["uint", ["uint"], "string"],
      ["uint_uint", ["uint", "uint"], "string"],
      // B67 Moment: string-argument methods returning scalars.
      ["string", ["string"], "uint"],
      ["string", ["string"], "int"],
      ["string", ["string"], "double"],
    ];
    for (const [argPart, argTypes, ret] of callSpecs) {
      const name = "Object_Call_" + argPart + "__" + ret;
      const sret = (ret === "string");
      out[name] = (...args) => {
        const at = { i: 0 };
        const raw = sret ? args[at.i++] : 0;
        const handle = args[at.i++];
        const mlen = args[at.i++];
        const mptr = args[at.i++];
        const method = text(mlen, mptr);
        const obj = resolve(handle);
        if (obj == null) throw new Error("libwasm object call on null receiver");
        const target = Object(obj);
        const callArgs = argTypes.map((t) => readArg(t, args, at));
        if (typeof target[method] !== "function") throw new Error("libwasm object has no method " + method);
        const result = target[method](...callArgs);
        if (ret === "void") return;
        if (ret === "string") { writeString(raw, jsString(result)); return; }
        return convertTo(result, ret);
      };
    }
    // B64 Optional!T sret writers.  Layout is `T _value; bool defined;`,
    // so the value is at `raw` and the presence flag at `raw + sizeof(T)`.
    const OPTIONAL_TYPES = { Handle: "Handle", Uint: "uint", Double: "double", String: "string", Bool: "bool" };
    function writeOptional(raw, v, type) {
      checkMemory(memory);
      if (!Number.isInteger(raw) || raw < 0) throw new Error("WASM optional result pointer invalid");
      const off = type === "Handle" || type === "uint" ? 4 : type === "double" || type === "string" ? 8 : 1;
      if (off + 1 > memory.buffer.byteLength - raw) throw new Error("WASM optional result out of bounds");
      const missing = v === undefined || v === null;
      const view = new DataView(memory.buffer);
      const setDef = () => { new Uint8Array(memory.buffer)[raw + off] = missing ? 0 : 1; };
      if (missing) {
        if (type === "string") {
          view.setUint32(raw, 0, true);
          view.setUint32(raw + 4, 0, true);
        } else if (type === "double") {
          view.setFloat64(raw, 0, true);
        } else if (type === "Handle" || type === "uint") {
          view.setUint32(raw, 0, true);
        } else {
          view.setUint8(raw, 0);
        }
        setDef();
        return;
      }
      if (type === "string") {
        writeString(raw, jsString(v));
      } else if (type === "double") {
        view.setFloat64(raw, Number(v), true);
      } else if (type === "Handle") {
        view.setUint32(raw, objAdd(v), true);
      } else if (type === "uint") {
        view.setUint32(raw, Number(v) >>> 0, true);
      } else {
        view.setUint8(raw, (v === true || v === 1 || (typeof v === "number" && v !== 0)) ? 1 : 0);
      }
      setDef();
    }
    for (const t of ["Handle", "Uint", "Double", "String", "Bool"]) {
      const type = OPTIONAL_TYPES[t];
      out["Object_Getter__Optional" + t] = (raw, handle, len, ptr) => {
        const prop = text(len, ptr);
        const obj = resolve(handle);
        if (obj == null) { writeOptional(raw, null, type); return; }
        const boxed = Object(obj);
        if (!(prop in boxed) || boxed[prop] == null) { writeOptional(raw, null, type); return; }
        writeOptional(raw, boxed[prop], type);
      };
    }
    const OPTIONAL_CALL_TYPES = { OptionalHandle: "Handle", OptionalString: "string" };
    const optionalCallSpecs = [
      ["string", ["string"], "OptionalHandle"],
      ["uint", ["uint"], "OptionalHandle"],
      ["int", ["int"], "OptionalHandle"],
      ["bool", ["bool"], "OptionalHandle"],
      ["string", ["string"], "OptionalString"],
    ];
    for (const [argPart, argTypes, ret] of optionalCallSpecs) {
      const name = "Object_Call_" + argPart + "__" + ret;
      const type = OPTIONAL_CALL_TYPES[ret];
      out[name] = (...args) => {
        const at = { i: 0 };
        const raw = args[at.i++];
        const handle = args[at.i++];
        const mlen = args[at.i++];
        const mptr = args[at.i++];
        const method = text(mlen, mptr);
        const obj = resolve(handle);
        if (obj == null) throw new Error("libwasm object call on null receiver");
        const target = Object(obj);
        const callArgs = argTypes.map((t) => readArg(t, args, at));
        if (typeof target[method] !== "function") throw new Error("libwasm object has no method " + method);
        const result = target[method](...callArgs);
        writeOptional(raw, result, type);
      };
    }

    // B65 JSON codec.
    out.JSON_parse_string = (len, ptr) => {
      const s = text(len, ptr);
      let v;
      try { v = JSON.parse(s); } catch (e) { throw new Error("JSON parse error: " + e.message); }
      if (v === undefined) v = null;
      return objAdd(v);
    };
    out.JSON_stringify = (raw, handle) => {
      const v = objGet(handle);
      const s = v === undefined ? "" : JSON.stringify(v);
      writeString(raw, s);
    };

    // B65 overload-resolving vararg call.  The D host serializes the tuple as a
    // flat JSON array and passes an `argsdef` descriptor.
    function splitTypes(inner) {
      const out = [];
      let depth = 0, start = 0;
      for (let i = 0; i < inner.length; i++) {
        const c = inner[i];
        if (c === "(") depth++;
        else if (c === ")") depth--;
        else if (c === "," && depth === 0) { out.push(inner.slice(start, i)); start = i + 1; }
      }
      out.push(inner.slice(start));
      return out;
    }
    function readVarArg(type, json, at, resolveHandles = true) {
      if (type.startsWith("Optional!")) {
        const inner = type.slice(9);
        const defined = !!json[at.i++];
        if (defined) return readVarArg(inner, json, at, resolveHandles);
        readVarArg(inner, json, at, resolveHandles);
        return undefined;
      }
      if (type.startsWith("SumType!")) {
        const inner = type.slice(8);
        const body = inner.slice(1, -1);
        const disc = Number(json[at.i++]) || 0;
        const types = splitTypes(body);
        const values = [];
        for (let i = 0; i < types.length; i++) {
          values.push(readVarArg(types[i].trim(), json, at, resolveHandles && i === disc));
        }
        return values[disc];
      }
      const v = json[at.i++];
      switch (type) {
        case "bool": return !!v;
        case "int": return Number(v) | 0;
        case "uint": return Number(v) >>> 0;
        case "short": return (Number(v) << 16) >> 16;
        case "ushort": return Number(v) & 0xFFFF;
        case "long": return BigInt.asIntN(64, BigInt(Math.trunc(Number(v))));
        case "ulong": return BigInt.asUintN(64, BigInt(Math.trunc(Number(v))));
        case "float": return Math.fround(Number(v));
        case "double": return Number(v);
        case "string": return String(v);
        case "Handle": return resolveHandles ? resolve(Number(v)) : Number(v);
        default: throw new Error("libwasm unsupported vararg type " + type);
      }
    }
    const varargSpecs = ["void", "bool", "int", "uint", "short", "ushort", "long", "ulong", "float", "double", "Handle", "string"];
    for (const ret of varargSpecs) {
      const sret = ret === "string";
      out["Object_VarArgCall__" + ret] = (...args) => {
        const at = { i: 0 };
        const raw = sret ? args[at.i++] : 0;
        const handle = args[at.i++];
        const mlen = args[at.i++], mptr = args[at.i++];
        const method = text(mlen, mptr);
        const dlen = args[at.i++], dptr = args[at.i++];
        const argsdef = text(dlen, dptr);
        const alen = args[at.i++], aptr = args[at.i++];
        const jsonArgs = JSON.parse(text(alen, aptr));
        if (!Array.isArray(jsonArgs)) throw new Error("Object_VarArgCall args must be a JSON array");
        const types = argsdef.split(";").filter((t) => t);
        const callAt = { i: 0 };
        const callArgs = types.map((t) => readVarArg(t.trim(), jsonArgs, callAt));
        const obj = resolve(handle);
        if (obj == null) throw new Error("libwasm vararg call on null receiver");
        const target = Object(obj);
        if (typeof target[method] !== "function") throw new Error("libwasm object has no method " + method);
        const result = target[method](...callArgs);
        if (ret === "void") return;
        if (ret === "string") { writeString(raw, jsString(result)); return; }
        return convertTo(result, ret);
      };
    }

    // B66 named delegates, event handlers, and timers. Re-entry is guarded by
    // the DOM transaction state and, when asyncify is present, the asyncify
    // state: the instance is not called while staging/unwinding/rewinding.
    const eventsEnabled = opts.events ?? !!asyncify;
    const delegateRegistry = new Map();
    const eventRegistry = new Map();
    let nextTimerId = 1;
    const timers = new Map();
    function callDelegate(ptr, ctx, ...args) {
      if (!(ptr > 0)) throw new Error("libwasm delegate pointer invalid");
      const table = wasmInstance?.exports?.__indirect_function_table;
      if (!table || typeof table.get !== "function") throw new Error("libwasm indirect function table not available");
      const fn = table.get(ptr);
      if (typeof fn !== "function") throw new Error("libwasm delegate pointer not in table");
      return fn(ctx, ...args);
    }
    function canReenter() {
      if (state !== "committed") return false;
      if (asyncify && asyncify.getState() !== 0) return false;
      return true;
    }
    const rafNow = typeof requestAnimationFrame === "function"
      ? requestAnimationFrame
      : (fn) => setTimeout(() => fn(0), 16);
    const cafNow = typeof cancelAnimationFrame === "function" ? cancelAnimationFrame : clearTimeout;
    function scheduleTimer(ctx, ptr, ms, interval) {
      const id = nextTimerId++;
      if (!eventsEnabled) {
        timers.set(id, { ctx, ptr, interval: false, raf: false });
        return id;
      }
      const handle = (interval ? setInterval : setTimeout)(() => {
        if (!canReenter()) return;
        try { callDelegate(ptr, ctx); } catch (e) { /* host event failures are not guest traps */ }
      }, ms);
      timers.set(id, { handle, ctx, ptr, interval, raf: false });
      return id;
    }
    out.libwasm_set__function = (nlen, nptr, ctx, ptr) => {
      const name = text(nlen, nptr);
      if (name.length > 256) throw new Error("libwasm delegate name too long");
      delegateRegistry.set(name, { ctx, ptr });
    };
    out.libwasm_unset__function = (nlen, nptr) => {
      delegateRegistry.delete(text(nlen, nptr));
    };
    out.setTimeout = (ctx, ptr, ms) => scheduleTimer(ctx, ptr, ms, false);
    out.setInterval = (ctx, ptr, ms) => scheduleTimer(ctx, ptr, ms, true);
    out.clearTimeout = (id) => {
      const t = timers.get(id);
      if (t?.handle) (t.raf ? cafNow : clearTimeout)(t.handle);
      timers.delete(id);
    };
    out.clearInterval = (id) => {
      const t = timers.get(id);
      if (t?.handle) clearInterval(t.handle);
      timers.delete(id);
    };
    out.requestAnimationFrame = (ctx, ptr) => {
      const id = nextTimerId++;
      if (!eventsEnabled) {
        timers.set(id, { ctx, ptr, raf: true });
        return id;
      }
      const handle = rafNow(() => {
        timers.delete(id);
        if (!canReenter()) return;
        try { callDelegate(ptr, ctx); } catch { /* host event failures are not guest traps */ }
      });
      timers.set(id, { handle, ctx, ptr, raf: true });
      return id;
    };
    out.cancelAnimationFrame = (id) => {
      const t = timers.get(id);
      if (t?.handle && t.raf) cafNow(t.handle);
      timers.delete(id);
    };
    out.Object_Call_EventHandler__void = (handle, mlen, mptr, defined, ctx, ptr) => {
      const name = text(mlen, mptr);
      const eventType = name.startsWith("on") ? name.slice(2) : name;
      const target = resolve(handle);
      if (target == null || (typeof target !== "object" && typeof target !== "function")) throw new Error("libwasm event handler target invalid");
      if (typeof target.addEventListener !== "function" && typeof target[name] === "undefined") throw new Error("libwasm event handler target has no event interface");
      const key = `${handle}:${name}`;
      const prev = eventRegistry.get(key);
      if (prev?.listener) {
        try { target.removeEventListener(eventType, prev.listener); } catch {}
      }
      if (!defined) { eventRegistry.delete(key); return; }
      if (!(ptr > 0)) throw new Error("libwasm event handler pointer invalid");
      const listener = (event) => {
        if (!canReenter()) return;
        const eventHandle = objAdd({ target, type: event?.type ?? eventType });
        try { callDelegate(ptr, ctx, eventHandle); } finally { /* event object is released on guest side if it frees the handle */ }
      };
      eventRegistry.set(key, { ctx, ptr, listener });
      if (typeof target.addEventListener === "function") target.addEventListener(eventType, listener);
      else target[name] = listener;
    };
    out.Object_Getter__EventHandler = (raw, handle, mlen, mptr) => {
      const name = text(mlen, mptr);
      const key = `${handle}:${name}`;
      const stored = eventRegistry.get(key);
      checkMemory(memory);
      const view = new DataView(memory.buffer);
      view.setUint32(raw, stored ? stored.ctx : 0, true);
      view.setUint32(raw + 4, stored ? stored.ptr : 0, true);
      new Uint8Array(memory.buffer)[raw + 8] = stored ? 1 : 0;
    };

    return out;
  })();

  const functions = {
    getTimeStamp() {
      return BigInt(Date.now());
    },
    fetch(ptr, len) {
      const url = text(len, ptr);
      if (!/^\/(bios|ui)\//.test(url)) throw new Error("libwasm fetch URL not a local /bios/ or /ui/ path: " + url);
      if (!asyncify) return 1;
      const promise = fetchFn(url, { method: "GET", credentials: "same-origin", redirect: "error" }).then((r) => {
        if (typeof r === "string") return r;
        if (!r || typeof r.ok !== "boolean") throw new Error("libwasm fetch returned non-Response");
        if (!r.ok) throw new Error(url + " HTTP " + r.status);
        return r.text();
      });
      return objAdd(promise);
    },
    holyc(ptr, len) {
      const line = text(len, ptr);
      if (line.length > 256) throw new Error("libwasm holyc line too long");
      const host = globalThis.kernel;
      if (asyncify && host && typeof host.holyc === "function") {
        return objAdd(Promise.resolve(host.holyc(line)));
      }
      return 0;
    },
    register_endpoint(pathPtr, pathLen, methodPtr, methodLen) {
      const path = text(pathLen, pathPtr);
      const method = text(methodLen, methodPtr);
      if (!/^\/bios\//.test(path)) throw new Error("libwasm register path not in /bios/: " + path);
      if (!/^(GET|POST|PUT|DELETE)$/.test(method)) throw new Error("libwasm register method unsupported: " + method);
      const host = globalThis.kernel;
      if (asyncify && host && typeof host.register === "function") {
        host.register(path, method);
      }
    },
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
      else if (name === "id") n.id = value;
      else if (name === "src") {
        if (!/^\/ui\/[A-Za-z0-9._/-]+\.(svg|png|jpg|ico)$/.test(value)) {
          throw new Error("WASM src must be a local /ui/ image path");
        }
        n.setAttribute("src", value);
      }
      else if (["innerHTML", "outerHTML", "onclick", "__proto__", "constructor", "style"].includes(name)) {
        throw new Error("WASM unsupported DOM property: " + name);
      } else n.setAttribute(name, value);
    },
    libwasm_await__void(handle) {
      if (!Number.isInteger(handle) || handle < 0) throw new Error("libwasm await handle invalid");
      if (!asyncify) return; // build/verification no-op
      const promise = objGet(handle);
      if (!promise) return null;
      if (typeof promise.then !== "function") return promise;
      return promise;
    },
    libwasm_await_supported() {
      return asyncify ? 1 : 0;
    },
    libwasm_await_failed() {
      return asyncify && asyncify.failed ? 1 : 0;
    },
    libwasm_await_error(raw) {
      const e = asyncify ? asyncify.lastError : null;
      writeString(raw, e ? (e.message || String(e)) : "");
    },
    libwasm_await_value(raw) {
      const v = asyncify ? asyncify.value : null;
      writeString(raw, v === undefined || v === null ? "" : String(v));
    },
    libwasm_note_await_fail(handle) {
      const obj = objGet(handle);
      if (asyncify) {
        asyncify.failed = true;
        asyncify.lastError = obj instanceof Error ? obj : new Error(String(obj ?? "rejected"));
        asyncify.value = null;
      }
    },
    libwasm_note_await_ok(handle) {
      const obj = objGet(handle);
      if (asyncify) {
        asyncify.failed = false;
        asyncify.lastError = null;
        asyncify.value = obj;
      }
    },
    libasync_promise_all__promise(handle) {
      const arr = objGet(handle);
      if (!Array.isArray(arr)) throw new Error("libwasm promise all expects a handle array");
      const promises = arr.map((h, i) => {
        const p = objGet(h);
        if (!isPromise(p)) throw new Error(`libwasm promise all handle ${i} is not a promise`);
        return p;
      });
      return objAdd(Promise.all(promises).then((values) => objAdd(values), (err) => Promise.reject(objAdd(err))));
    },
    libasync_promise_any__promise(handle) {
      const arr = objGet(handle);
      if (!Array.isArray(arr)) throw new Error("libwasm promise any expects a handle array");
      const promises = arr.map((h, i) => {
        const p = objGet(h);
        if (!isPromise(p)) throw new Error(`libwasm promise any handle ${i} is not a promise`);
        return p;
      });
      return objAdd(Promise.any(promises).then((value) => objAdd(value), (err) => Promise.reject(objAdd(err))));
    },
    libasync_promise_allsettled__promise(handle) {
      const arr = objGet(handle);
      if (!Array.isArray(arr)) throw new Error("libwasm promise allSettled expects a handle array");
      const promises = arr.map((h, i) => {
        const p = objGet(h);
        if (!isPromise(p)) throw new Error(`libwasm promise allSettled handle ${i} is not a promise`);
        return p;
      });
      return objAdd(Promise.allSettled(promises).then((results) => objAdd(results), (err) => Promise.reject(objAdd(err))));
    },
    libwasm_get__string(raw, ptr) {
      if (ptr === 0) return writeString(raw, ""); // D null handle
      const obj = objEntry(ptr, "get__string").value;
      if (typeof obj !== "string") throw new Error("libwasm object is not a string");
      writeString(raw, obj);
    },
    libwasm_add__string(len, ptr) {
      return objAdd(text(len, ptr));
    },
    libwasm_add__object() {
      return objAdd(Object.create(null));
    },
    // Resolve a browser-instance global (`console`, `window`, `document`, ...)
    // to a stable, protected object handle. Returns 0 when no context is bound
    // or the name is not in `bindings()` — fail closed, so guest code that
    // asks for an unavailable global gets a null handle it must check, not a
    // fake object that silently swallows writes.
    //
    // Everything else flows through the existing typed machinery: with the
    // handle in hand, `Object_Call_string__void(h, "log", msg)` already works.
    // That is why this is one import and not a console ABI.
    libwasm_global(len, ptr) {
      if (!ctx) return 0;
      const name = text(len, ptr);
      const existing = globalRoots.get(name);
      if (existing !== undefined) return existing;
      const value = ctx.global(name);
      if (value === undefined) return 0;
      const handle = objAdd(value);
      globalRoots.set(name, handle);
      globalRootHandles.add(handle);
      return handle;
    },
    libwasm_copyObjectRef(handle) {
      if (objIsRoot(handle)) return handle; // roots are never refcounted
      objEntry(handle, "copyObjectRef").refs++;
      return handle;
    },
    libwasm_removeObject(handle) {
      const e = objEntry(handle, "removeObject");
      if (--e.refs > 0) return;
      objects.delete(handle);
      objFree.push(handle - OBJ_BASE);
    },
    libwasm_add__bool(v) { return objAdd(!!v ? 1 : 0); },
    libwasm_add__int(v) { return objAdd(v | 0); },
    libwasm_add__uint(v) { return objAdd(v >>> 0); },
    libwasm_add__long(v) { return objAdd(typeof v === "bigint" ? BigInt.asIntN(64, v) : BigInt.asIntN(64, BigInt(Math.trunc(Number(v))))); },
    libwasm_add__ulong(v) { return objAdd(typeof v === "bigint" ? BigInt.asUintN(64, v) : BigInt.asUintN(64, BigInt(Math.trunc(Number(v))))); },
    libwasm_add__short(v) { return objAdd((v << 16) >> 16); },
    libwasm_add__ushort(v) { return objAdd(v & 0xFFFF); },
    libwasm_add__float(v) { return objAdd(Math.fround(Number(v))); },
    libwasm_add__double(v) { return objAdd(Number(v)); },
    libwasm_add__byte(v) { return objAdd((v << 24) >> 24); },
    libwasm_add__ubyte(v) { return objAdd(v & 0xFF); },
    libwasm_add__ints(len, ptr) { return objAdd(Array.from(new Int32Array(memory.buffer, ptr, len))); },
    libwasm_add__uints(len, ptr) { return objAdd(Array.from(new Uint32Array(memory.buffer, ptr, len))); },
    libwasm_moment_now() { return objAdd(new Date()); },
    libwasm_moment_from_millis(ms) { return objAdd(new Date(Number(ms))); },
    libwasm_map_create() { return objAdd(new Map()); },
    libwasm_map_set(handle, klen, kptr, vlen, vptr) {
      const map = objGet(handle);
      if (!(map instanceof Map)) throw new Error("libwasm map_set on non-Map");
      map.set(text(klen, kptr), text(vlen, vptr));
    },
    libwasm_map_get__OptionalString(raw, handle, klen, kptr) {
      const map = objGet(handle);
      if (!(map instanceof Map)) throw new Error("libwasm map_get on non-Map");
      const v = map.get(text(klen, kptr));
      if (v === undefined) {
        writeString(raw, "");
        new Uint8Array(memory.buffer)[raw + 8] = 0;
      } else {
        writeString(raw, jsString(v));
        new Uint8Array(memory.buffer)[raw + 8] = 1;
      }
    },
    libwasm_map_has(handle, klen, kptr) {
      const map = objGet(handle);
      if (!(map instanceof Map)) return 0;
      return map.has(text(klen, kptr)) ? 1 : 0;
    },
    libwasm_map_delete(handle, klen, kptr) {
      const map = objGet(handle);
      if (!(map instanceof Map)) throw new Error("libwasm map_delete on non-Map");
      map.delete(text(klen, kptr));
    },
    libwasm_map_clear(handle) {
      const map = objGet(handle);
      if (!(map instanceof Map)) throw new Error("libwasm map_clear on non-Map");
      map.clear();
    },
    Int8Array_Create(len, ptr) { return objAdd(new Int8Array(memory.buffer, ptr, len)); },
    Int32Array_Create(len, ptr) { return objAdd(new Int32Array(memory.buffer, ptr, len)); },
    Uint8Array_Create(len, ptr) { return objAdd(new Uint8Array(memory.buffer, ptr, len)); },
    Float32Array_Create(len, ptr) { return objAdd(new Float32Array(memory.buffer, ptr, len)); },
    DataView_Create(len, ptr) { return objAdd(new DataView(memory.buffer, ptr, len)); },
    libwasm_get__bool(handle) { const v = objGet(handle); return (v === true || v === 1 || (typeof v === "number" && v !== 0)) ? 1 : 0; },
    libwasm_get__int(handle) { return Number(objGet(handle)) | 0; },
    libwasm_get__uint(handle) { return Number(objGet(handle)) >>> 0; },
    libwasm_get__long(handle) { const v = objGet(handle); return typeof v === "bigint" ? BigInt.asIntN(64, v) : BigInt.asIntN(64, BigInt(Math.trunc(Number(v)))); },
    libwasm_get__ulong(handle) { const v = objGet(handle); return typeof v === "bigint" ? BigInt.asUintN(64, v) : BigInt.asUintN(64, BigInt(Math.trunc(Number(v)))); },
    libwasm_get__short(handle) { return (Number(objGet(handle)) << 16) >> 16; },
    libwasm_get__ushort(handle) { return Number(objGet(handle)) & 0xFFFF; },
    libwasm_get__float(handle) { return Math.fround(Number(objGet(handle))); },
    libwasm_get__double(handle) { return Number(objGet(handle)); },
    libwasm_get__byte(handle) { return (Number(objGet(handle)) << 24) >> 24; },
    libwasm_get__ubyte(handle) { return Number(objGet(handle)) & 0xFF; },
    libwasm_get__field(handle, len, ptr) {
      const name = text(len, ptr);
      const obj = objGet(handle);
      if (obj === undefined || obj === null) return 0;
      if (obj instanceof DataView) {
        if (name === "length" || name === "byteLength") return objAdd(obj.byteLength);
        if (name === "byteOffset") return objAdd(obj.byteOffset);
      }
      return objAdd(obj[name]);
    },
    libwasm_get_idx__field(handle, idx) {
      const obj = objGet(handle);
      if (obj === undefined || obj === null) return 0;
      if (obj instanceof DataView) return objAdd(obj.getUint8(idx));
      if (ArrayBuffer.isView(obj)) return objAdd(obj[idx]);
      return objAdd(obj[idx]);
    },
    ...libwasmObjectAccess,
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
    addEventListener(targetPtr, targetLen, typePtr, typeLen, listener, capture) {
      log("WASM addEventListener " + text(targetPtr, targetLen) + " " + text(typePtr, typeLen) + " " + listener + " " + capture);
    },
    removeEventListener(listener) {
      log("WASM removeEventListener " + listener);
    },
    dispatchEvent(targetPtr, targetLen, typePtr, typeLen, detailPtr, detailLen) {
      log("WASM dispatchEvent " + text(targetPtr, targetLen) + " " + text(typePtr, typeLen) + " " + text(detailPtr, detailLen));
      return 1;
    },
    ...ldexecImports(),
  };
  const baseFunctions = asyncify ? asyncify.wrapModuleImports(functions) : functions;
  const env = Object.fromEntries(Object.entries(baseFunctions).map(([name, fn]) => [name, (...args) => {
    try {
      if (state !== "staging") throw new Error("WASM DOM transaction is " + state);
      if (++calls > 16384) throw new Error("WASM import budget exceeded");
      if (memory) checkMemory(memory);
      return fn(...args);
    } catch (error) { state = "failed"; throw error; }
  }]));
  env.__cpp_exception = new wasmApi.Tag({ parameters: ["i32"] });
  const host = {
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
  if (asyncify) {
    host.start = async (instance, heap) => {
      wasmInstance = instance;
      asyncify.init(instance, host.imports);
      return await asyncify.exports._start(heap);
    };
    host.exports = () => asyncify.exports;
  }
  return host;
}

// A browser instance: the `console` / `window` / `document` singletons that a
// UI is built on, plus a bounded pollable console ring.
//
// Deliberately ENGINE-AGNOSTIC. Nothing here mentions WebAssembly, libwasm or
// the object table: the contract offered to any engine is `bindings()`, a plain
// `name -> object` map, plus `consolePage()` for polling. libwasm consumes it
// through one optional import (`libwasm_global`); the MVP `createWasmHost` can
// route its `log` into the same ring; a devtools panel or plain JS can use it
// directly. Adding a second engine must not require touching this function.
//
// Multiple instances coexist, each with its own `contextId`, handle vocabulary
// and console ring — that is what lets an embedded frame get its own browser
// instance without its output interleaving into the parent's console.
//
// Console shape follows `kernel-spec/goosie` `internal/browsercontrol/types.go`:
// `ConsoleEntry{level, data, timestamp}` and a bounded
// `ConsolePage{contextId, pageRevision, entries, dropped}`. The bounded-ring
// -that-reports-drops detail is taken from there deliberately: silently losing
// console output is how a debugging tool lies to you.
export function createBrowserContext(doc, opts = {}) {
  const contextId = String(opts.contextId || "main");
  const LIMIT = Number.isInteger(opts.consoleLimit) ? opts.consoleLimit : 512;
  if (LIMIT < 1) throw new Error("browser context console limit must be >= 1");
  // goosie ConsoleMessage.Level, minus "table" (needs a table renderer we do
  // not have; an unknown level is refused rather than silently downgraded).
  const LEVELS = ["log", "info", "warn", "error", "debug"];
  const MAX_TEXT = 4096;

  const entries = [];      // ring, oldest first
  let nextSeq = 1;         // monotonic; also the pageRevision cursor
  let dropped = 0;         // total evicted by the bound, never silently hidden
  const mirror = typeof opts.mirror === "function" ? opts.mirror : null;
  const clock = typeof opts.now === "function" ? opts.now : () => Date.now();

  function record(level, parts) {
    if (!LEVELS.includes(level)) throw new Error("browser console unknown level " + level);
    // Formatting is deliberately dumb: String() each argument. No %s/%o
    // interpolation, because a format-string mini-language is a parser, and an
    // unbounded one at that.
    let data = parts.map((p) => {
      if (typeof p === "string") return p;
      if (p === null || p === undefined || typeof p !== "object") return String(p);
      try { return JSON.stringify(p); } catch { return "[uncloneable]"; }
    }).join(" ");
    if (data.length > MAX_TEXT) data = data.slice(0, MAX_TEXT) + "...[truncated]";
    const entry = { seq: nextSeq++, level, data, timestamp: clock() };
    entries.push(entry);
    while (entries.length > LIMIT) { entries.shift(); dropped++; }
    if (mirror) mirror(entry, contextId);
    return entry;
  }

  const console_ = {};
  for (const level of LEVELS) console_[level] = (...parts) => { record(level, parts); };
  console_.clear = () => { entries.length = 0; };
  // console.count/group would each need state or nesting semantics; refuse
  // rather than pretend.
  console_.levels = () => LEVELS.slice();

  const view = opts.view || doc.defaultView || null;
  // Bounded `document`: an allow-listed projection, not the host document.
  // Anything not listed is absent, so guest or UI code cannot reach cookies,
  // scripts, or navigation through this singleton.
  const document_ = {
    contextId,
    getElementById: (id) => doc.getElementById(id),
    querySelectorAll: (sel) => (typeof doc.querySelectorAll === "function" ? doc.querySelectorAll(sel) : []),
    createElement: (tag) => doc.createElement(tag),
    get title() { return typeof doc.title === "string" ? doc.title : ""; },
  };
  // Bounded `window`: geometry and the two singletons. No open/eval/fetch/
  // location-assignment — those are the BIOS kernel's business, not a UI
  // global's, and `location` is exposed read-only as a string.
  const window_ = {
    contextId,
    console: console_,
    document: document_,
    get innerWidth() { return view && Number.isFinite(view.innerWidth) ? view.innerWidth : 0; },
    get innerHeight() { return view && Number.isFinite(view.innerHeight) ? view.innerHeight : 0; },
    get devicePixelRatio() { return view && Number.isFinite(view.devicePixelRatio) ? view.devicePixelRatio : 1; },
    get href() {
      const l = view && view.location;
      return l && typeof l.href === "string" ? l.href : "";
    },
  };

  const BINDINGS = { console: console_, window: window_, document: document_ };

  return {
    contextId,
    console: console_,
    window: window_,
    document: document_,

    /// The engine-facing contract: an allow-listed `name -> object` map.
    /// A name absent here is absent everywhere, which is what keeps a new
    /// engine from widening the surface by accident.
    bindings() { return { ...BINDINGS }; },
    /// Resolve one global by name; `undefined` (never a throw) when unknown,
    /// so an engine can decide whether an unknown global is fatal.
    global(name) { return Object.prototype.hasOwnProperty.call(BINDINGS, name) ? BINDINGS[name] : undefined; },
    globalNames() { return Object.keys(BINDINGS); },

    /// Poll the console. Returns entries newer than `sinceRevision`, the new
    /// cursor, the lifetime `dropped` count, and `missed` — how many entries
    /// this caller can never see because the ring evicted them while its cursor
    /// was behind. A poller that silently skips is worse than one that reports.
    consolePage(sinceRevision = 0) {
      const since = Number.isFinite(sinceRevision) ? Math.max(0, Math.trunc(sinceRevision)) : 0;
      const fresh = entries.filter((e) => e.seq > since);
      const oldest = entries.length ? entries[0].seq : nextSeq;
      const missed = since > 0 && oldest > since + 1 ? oldest - since - 1 : 0;
      return {
        contextId,
        pageRevision: nextSeq - 1,
        entries: fresh.map((e) => ({ level: e.level, data: e.data, timestamp: e.timestamp, seq: e.seq })),
        dropped,
        missed,
      };
    },

    /// Paint the console into a DOM element — the devtools panel.
    ///
    /// Text is written through textContent, never innerHTML, so a logged
    /// string containing markup is displayed rather than parsed. Returns the
    /// cursor to pass back on the next call for incremental appends.
    renderConsoleInto(el, sinceRevision = 0) {
      if (!el || typeof el.appendChild !== "function") throw new Error("console target unavailable");
      const page = this.consolePage(sinceRevision);
      if (sinceRevision === 0 && typeof el.replaceChildren === "function") el.replaceChildren();
      if (page.missed) {
        const note = doc.createElement("div");
        note.setAttribute("data-console-level", "warn");
        note.textContent = "[" + page.missed + " earlier entries dropped]";
        el.appendChild(note);
      }
      for (const entry of page.entries) {
        const row = doc.createElement("div");
        row.setAttribute("data-console-level", entry.level);
        row.setAttribute("data-console-seq", String(entry.seq));
        row.textContent = entry.level.toUpperCase() + " " + entry.data;
        el.appendChild(row);
      }
      return page.pageRevision;
    },
  };
}

// Render debugging (see architecture/RENDER-VALIDATION.md §7).
//
// A DevTools-like inspector over the *first-party* g6b-css engine. Two jobs:
//
//   describe(el)      dump what the real browser computed for an element, in
//                     the same property vocabulary g6b-css uses.
//   diff(el, report)  compare a `g6b_css::inspect::StyleReport` JSON against
//                     the real browser's getComputedStyle for the same element.
//
// `diff` is the useful one: the host browser is an *external* oracle for
// computed values, so a mismatch localises a cascade or box-model bug to one
// property instead of one wrong pixel. This is NOT a conformance score — see
// RENDER-VALIDATION.md §1 on why recognition/self-reported numbers mean
// nothing. It is a dev facility and is never on the BIOS render path.
export function createRenderInspector(doc, view = doc.defaultView || globalThis) {
  // The longhands g6b-css models. Keep in sync with SUPPORTED_PROPERTIES.
  const PROPERTIES = [
    "display", "width", "height", "box-sizing",
    "margin-top", "margin-right", "margin-bottom", "margin-left",
    "padding-top", "padding-right", "padding-bottom", "padding-left",
    "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
    "color", "background-color", "visibility",
  ];

  function resolve(target) {
    const el = typeof target === "string" ? doc.getElementById(target) : target;
    if (!el) throw new Error("render inspector: unknown element " + target);
    return el;
  }

  // getComputedStyle is absent in the bun/TestNode harness; callers get an
  // explicit failure rather than a silently empty diff that looks like a pass.
  function computed(el) {
    if (typeof view.getComputedStyle !== "function") {
      throw new Error("render inspector: host has no getComputedStyle");
    }
    const style = view.getComputedStyle(el);
    const out = {};
    for (const p of PROPERTIES) {
      const v = style.getPropertyValue(p);
      if (v !== undefined && v !== null && v !== "") out[p] = String(v).trim();
    }
    return out;
  }

  // "10px" -> 10. Returns null when the value is not a whole-pixel length, so
  // a unit we cannot compare is reported as such instead of coerced to 0.
  function px(value) {
    if (value === undefined || value === null) return null;
    const m = /^(-?\d+)(?:px)?$/.exec(String(value).trim());
    return m ? Number(m[1]) : null;
  }

  return {
    properties: PROPERTIES,
    computed(target) { return computed(resolve(target)); },

    /// Text dump of the browser's own view of an element, plus its box.
    describe(target) {
      const el = resolve(target);
      const style = computed(el);
      const lines = [el.tagName ? el.tagName.toLowerCase() : "?"];
      if (el.id) lines[0] += "#" + el.id;
      for (const p of PROPERTIES) {
        if (p in style) lines.push("  " + p + ": " + style[p]);
      }
      const box = typeof el.getBoundingClientRect === "function" ? el.getBoundingClientRect() : null;
      if (box) lines.push("  rect: " + Math.round(box.width) + "x" + Math.round(box.height));
      return lines.join("\n");
    },

    /// Diff a g6b-css StyleReport (object or JSON text) against the browser.
    ///
    /// `tolerance` is in whole pixels and applies only to length comparisons;
    /// keyword values must match exactly. Returns every disagreement with both
    /// values, so the caller can see *which* side is wrong.
    diff(target, report, tolerance = 0) {
      const parsed = typeof report === "string" ? JSON.parse(report) : report;
      if (!parsed || !Array.isArray(parsed.properties)) {
        throw new Error("render inspector: report has no properties array");
      }
      const el = resolve(target);
      const actual = computed(el);
      const mismatches = [];
      const compared = [];
      const skipped = [];

      for (const trace of parsed.properties) {
        const property = trace.property;
        const ours = trace.value;
        if (!(property in actual)) {
          skipped.push({ property, reason: "host did not report this property" });
          continue;
        }
        const theirs = actual[property];
        const a = px(ours);
        const b = px(theirs);
        compared.push(property);
        if (a !== null && b !== null) {
          const delta = Math.abs(a - b);
          if (delta > tolerance) {
            mismatches.push({ property, ours, theirs, delta, kind: "length" });
          }
        } else if (a === null && b === null) {
          if (ours.toLowerCase() !== theirs.toLowerCase()) {
            mismatches.push({ property, ours, theirs, kind: "keyword" });
          }
        } else {
          // One side is a length and the other is not: a real disagreement
          // about the *type* of the value, which is worth surfacing loudly.
          mismatches.push({ property, ours, theirs, kind: "unit-mismatch" });
        }
      }

      // The box model is the pixel-accuracy signal; compare it to the layout
      // rect the browser actually used.
      const boxDiff = [];
      const rect = typeof el.getBoundingClientRect === "function" ? el.getBoundingClientRect() : null;
      if (rect && parsed.box && !parsed.box.refused) {
        for (const [key, got] of [["borderBoxWidth", rect.width], ["borderBoxHeight", rect.height]]) {
          const ours = parsed.box[key];
          if (typeof ours !== "number") continue;
          const delta = Math.abs(ours - Math.round(got));
          if (delta > tolerance) boxDiff.push({ metric: key, ours, theirs: Math.round(got), delta });
        }
      }

      return { element: parsed.element, ok: !mismatches.length && !boxDiff.length, compared, skipped, mismatches, box: boxDiff };
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
      // Native-browser fallback until the LDC cell's g6b_listen listeners
      // own tab/refresh (B87). Same protocol as BrowserSession::cell_click.
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
          const response = await fetchFn(libwasmUrl, { method: "GET", credentials: "same-origin", redirect: "error" });
          if (!response.ok) throw new Error("WASM HTTP " + response.status);
          const bytes = await response.arrayBuffer();
          const isLibwasmWasm = bytes.byteLength >= 8 &&
            new Uint8Array(bytes)[0] === 0x00 &&
            new Uint8Array(bytes)[1] === 0x61 &&
            new Uint8Array(bytes)[2] === 0x73 &&
            new Uint8Array(bytes)[3] === 0x6d;
          host = createLibwasmHost(doc, libwasmRoot, wasmApi, { asyncify: isLibwasmWasm, fetchFn });
          if (bytes.byteLength < 8 || bytes.byteLength > 1024 * 1024) throw new Error("WASM module size budget exceeded");
          const { instance } = await wasmApi.instantiate(bytes, host.imports);
          host.bind(instance.exports.memory);
          if (typeof instance.exports._start !== "function") throw new Error("WASM _start export missing");
          const heap = instance.exports.__heap_base?.value;
          if (!Number.isInteger(heap) || heap < 0 || heap > instance.exports.memory.buffer.byteLength) {
            throw new Error("WASM heap base export invalid");
          }
          // LDC/libwasm `_start(heap_base)` is wrapped by the asyncify driver
          // only when the module is a real libwasm asyncified binary.
          if (host.start) await host.start(instance, heap);
          else instance.exports._start(heap);
          host.commit();
          if (note) note.textContent = "libwasm SPA: " + host.nodeCount() + " allocated nodes (LDC wasm-eh " + (host.start ? "asyncify" : "scaffold") + ")";
          createParticleBackground(doc, ui, instance.exports);
        } catch (error) {
          if (host) host.rollback();
          if (note) note.textContent = "libwasm SPA unavailable: " + String(error && error.message || error);
        }
      }
    },
  };
}

const ASYNCIFY_DATA_ADDR = 524288;
const ASYNCIFY_DATA_START = ASYNCIFY_DATA_ADDR + 8;
const ASYNCIFY_DATA_END = 1048576;
const ASYNCIFY_EXPORTS = ["_start"];

function isPromise(obj) {
  return !!obj && (typeof obj === "object" || typeof obj === "function") && typeof obj.then === "function";
}

class LibwasmAsyncify {
  constructor() {
    this.exports = null;
    this.value = undefined;
    this.lastError = null;
    this.failed = false;
    this.lastExport = "";
    this.queue = Promise.resolve();
  }

  getState() {
    return this.exports ? this.exports.asyncify_get_state() : 0;
  }

  assertNoneState() {
    const s = this.getState();
    if (s !== 0) throw new Error(`Invalid asyncify state ${s}, expected 0`);
  }

  wrapImportFn(fn) {
    return (...args) => {
      const curState = this.getState();
      if (curState === 2) {
        this.exports.asyncify_stop_rewind();
        return this.value;
      }
      this.assertNoneState();
      const value = fn(...args);
      if (!isPromise(value)) return value;
      this.exports.asyncify_start_unwind(ASYNCIFY_DATA_ADDR);
      this.value = value;
    };
  }

  wrapModuleImports(mod) {
    const out = Object.create(null);
    for (const [name, value] of Object.entries(mod)) {
      out[name] = typeof value === "function" ? this.wrapImportFn(value) : value;
    }
    return out;
  }

  wrapImports(imports) {
    if (!imports) return undefined;
    const out = Object.create(null);
    for (const [name, value] of Object.entries(imports)) {
      out[name] = name === "env" && typeof value === "object" ? this.wrapModuleImports(value) : value;
    }
    return out;
  }

  wrapExportFn(fn, exportName) {
    const run = async (...args) => {
      this.assertNoneState();
      this.lastExport = exportName;
      try {
        let result = await fn(...args);
        while (this.getState() === 1) {
          this.exports.asyncify_stop_unwind();
          try {
            this.value = await this.value;
            this.lastError = null;
            this.failed = false;
          } catch (error) {
            this.lastError = error;
            this.failed = true;
            this.value = null;
          }
          this.assertNoneState();
          this.exports.asyncify_start_rewind(ASYNCIFY_DATA_ADDR);
          result = await fn(...args);
        }
        this.assertNoneState();
        return result;
      } catch (error) {
        throw error;
      }
    };
    return (...args) => {
      const p = this.queue.then(() => run(...args), () => run(...args));
      this.queue = p.then(() => undefined, () => undefined);
      return p;
    };
  }

  wrapExports(exports) {
    const out = Object.create(null);
    for (const [name, value] of Object.entries(exports)) {
      if (typeof value === "function" && ASYNCIFY_EXPORTS.includes(name)) {
        out[name] = this.wrapExportFn(value, name);
      } else {
        out[name] = value;
      }
    }
    this.exports = out;
    return out;
  }

  init(instance, imports) {
    const memory = instance.exports.memory || (imports && imports.env && imports.env.memory);
    if (!memory) throw new Error("libwasm memory export missing");
    new Int32Array(memory.buffer, ASYNCIFY_DATA_ADDR).set([ASYNCIFY_DATA_START, ASYNCIFY_DATA_END]);
    this.wrapExports(instance.exports);
  }
}

if (typeof document !== "undefined") {
  const app = createBrowserApp(document);
  activeBrowserApp = app;
  void app.start();
}
