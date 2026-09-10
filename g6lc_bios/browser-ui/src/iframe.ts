// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * JS host adapter for `g6b-iframe`. Dispatch, history, and caps live in the
 * Rust crate. This file only plans a location, fulfills HostNeed fetches, and
 * paints a mount. Not imported by App.svelte.
 * Nested `createBrowserContext` is re-populated on navigate (B92e); it never
 * uses the shell `contextId=main` and cannot `getElementById` shell chrome.
 * Outbound `http(s):` is armed by default (`kernel.http.outbound`); pass
 * `outbound: false` to fail closed. Never KernelPort / HolyC.
 */
import { createBrowserContext } from "./kernel.ts";

/// `/ui/*.html` location. Same rules as `g6b_iframe::local_html_url`.
export function localFrameUrl(url) {
  if (typeof url !== "string") return null;
  const path = url.split(/[?#]/)[0];
  if (!path.startsWith("/ui/") || path.startsWith("//") || path.includes("\\") || path.includes(":") || /[\u0000-\u001f\u007f]/.test(path) || path.split("/").some((p) => p === "." || p === "..")) return null;
  if (path.endsWith(".html") || path === "/ui/") return path;
  return null;
}

/// `app:files` / `/apps/files` → `app:files`. Same as `g6b_iframe::canonicalize_app_url`.
export function canonicalizeAppUrl(url) {
  if (typeof url !== "string") return null;
  const u = url.trim();
  let name = "";
  if (u.startsWith("app:")) name = u.slice(4).split("/")[0];
  else if (u.startsWith("/apps/")) name = u.slice(6).split("/")[0];
  else return null;
  if (!name || !/^[a-z][a-z0-9_]*$/.test(name)) return null;
  return "app:" + name;
}

function hookArmed(hooks, app) {
  return Array.isArray(hooks) && hooks.some((h) => h === app || (h && h.prefix === app));
}

function remoteWasmUrl(url) {
  const path = String(url).split(/[?#]/)[0];
  const name = path.split("/").pop() || "";
  return name.endsWith(".wasm");
}

/// Mirror of `g6b_iframe::plan_navigate_gated`. `outbound` default false (crate
/// `plan_navigate`). `createIframe` arms it unless `opts.outbound === false`.
export function planNavigate(url, hooks = [], outbound = false) {
  const u = String(url).trim();
  if (!u || u === "about:blank") return { kind: "blank" };
  if (u === "about:srcdoc") return { kind: "fail", location: u, error: "srcdoc requires the srcdoc attribute" };
  if (/^(javascript|file|data):/i.test(u)) return { kind: "fail", location: u, error: "javascript:/file:/data: documents refused" };
  if (/^https?:/i.test(u)) {
    if (remoteWasmUrl(u)) return { kind: "fail", location: u, error: "remote wasm cells refused" };
    if (outbound) return { kind: "fetchRemote", url: u };
    return { kind: "fail", location: u, error: "outbound fetch disabled" };
  }
  const app = canonicalizeAppUrl(u);
  if (app) {
    if (!hookArmed(hooks, app)) return { kind: "fail", location: u, error: "app: hook not registered" };
    if (app === "app:files") return { kind: "hook", prefix: app, url: u, files: true };
    return { kind: "fail", location: u, error: "app: hook not registered" };
  }
  if (u.startsWith("/bios/")) return { kind: "fail", location: u, error: "iframe cannot load /bios" };
  const path = localFrameUrl(u);
  if (!path) return { kind: "fail", location: u, error: "not a local /ui HTML document" };
  return { kind: "fetchHtml", path };
}

export function planSrcdoc(html) {
  return { kind: "srcdoc", html: String(html) };
}

function stripTags(s) {
  return String(s).replace(/<[^>]+>/g, "");
}

const RESERVED_VARS = new Set([
  "window", "document", "console", "eval", "Function", "globalThis", "self", "top", "parent",
  "frames", "location", "navigator", "holyc", "holycEval", "fetchBios", "registerEndpoint",
  "register_endpoint", "pglite", "platform", "hw", "contentWindow", "contentDocument", "src", "srcdoc",
]);
const MAX_SESSION_VARS = 32;

export function sessionVarNameAllowed(name) {
  return typeof name === "string" && /^[A-Za-z_][A-Za-z0-9_]*$/.test(name) && !RESERVED_VARS.has(name);
}

/// `vars={frameVars}` / `vars=frameVars` / `vars='{"greeting":"hi"}'`.
export function parseVarsAttr(attr) {
  if (typeof attr !== "string") return null;
  const t = attr.trim();
  if (!t) return null;
  if (t.startsWith("{") && t.endsWith("}")) {
    const inner = t.slice(1, -1).trim();
    if (inner && /^[A-Za-z_][A-Za-z0-9_]*$/.test(inner) && sessionVarNameAllowed(inner)) return { kind: "binding", name: inner };
    if (inner.startsWith("\"") || inner.includes(":")) return { kind: "json", json: t };
    if (!inner) return { kind: "json", json: "{}" };
    return null;
  }
  if (sessionVarNameAllowed(t)) return { kind: "binding", name: t };
  return null;
}

export function filterSessionVars(map) {
  const out = {};
  if (!map || typeof map !== "object" || Array.isArray(map)) return out;
  const keys = Object.keys(map);
  let n = 0;
  for (const k of keys) {
    if (!sessionVarNameAllowed(k)) continue;
    if (n >= MAX_SESSION_VARS) break;
    out[k] = map[k];
    n += 1;
  }
  return out;
}

function normalizeVars(v) {
  if (v == null) return {};
  if (typeof v === "string") {
    const parsed = parseVarsAttr(v);
    if (parsed && parsed.kind === "json") {
      try { return filterSessionVars(JSON.parse(parsed.json)); } catch { return {}; }
    }
    return {};
  }
  if (typeof v === "object") return filterSessionVars(v);
  return {};
}

/// HTMLIFrameElement controller on an existing `createBrowserContext` instance.
/// `src` / `srcdoc` navigate; nested context is re-populated. Not a CSS box.
export function createIframe(doc, opts = {}) {
  const el = doc.createElement("iframe");
  let baseId = String(opts.contextId || "frame-1");
  if (baseId === "main") baseId = "frame-1";
  const fetchFn = typeof opts.fetchFn === "function" ? opts.fetchFn : null;
  const hostFetch = fetchFn || (typeof fetch === "function" ? fetch.bind(globalThis) : null);
  const mount = opts.mount || doc.createElement("div");
  const hooks = Array.isArray(opts.hooks) ? opts.hooks : [];
  // Armed unless the host passes `outbound: false` (`kernel.http.outbound`).
  const outbound = opts.outbound !== false;
  let varsMap = normalizeVars(opts.vars);
  let generation = 1;
  function nestedDoc() {
    return {
      createElement: (tag) => doc.createElement(tag),
      getElementById: (id) => {
        if (mount && mount.id === id) return mount;
        return null;
      },
      querySelectorAll: () => [],
      title: "",
    };
  }
  function spawn() {
    return createBrowserContext(nestedDoc(), {
      contextId: baseId + "-g" + generation,
      store: false,
      fetchFn: opts.fetchFn,
      guestVars: varsMap,
    });
  }
  let nested = spawn();
  let location = "about:blank";
  let history = ["about:blank"];
  let load = "ok";
  let srcdocValue = "";
  let pending = Promise.resolve();
  function repopulate() {
    generation += 1;
    nested = spawn();
  }
  function replaceHistory(url) {
    location = url;
    if (history.length === 0) history.push(url);
    else history[history.length - 1] = url;
  }
  function fail(url, error) {
    repopulate();
    replaceHistory(url);
    load = "error: " + error;
    srcdocValue = "";
    mount.textContent = load;
    el.setAttribute("src", url);
  }
  async function navigate(url) {
    const plan = planNavigate(url, hooks, outbound);
    if (plan.kind === "blank") {
      repopulate();
      replaceHistory("about:blank");
      load = "ok";
      srcdocValue = "";
      mount.textContent = "about:blank";
      el.setAttribute("src", "about:blank");
      return;
    }
    if (plan.kind === "fail") {
      fail(plan.location, plan.error);
      return;
    }
    if (plan.kind === "hook" && plan.files) {
      if (!fetchFn) {
        fail("app:files", "app: hook not registered");
        return;
      }
      load = "loading";
      replaceHistory("app:files");
      const resp = await fetchFn("/bios/files", { method: "GET" });
      el.setAttribute("src", "app:files");
      srcdocValue = "";
      if (!resp || !resp.ok) {
        load = "error: HTTP " + (resp && resp.status || 0);
        return;
      }
      load = "ok";
      const body = typeof resp.text === "function" ? await resp.text() : String(resp.body || "");
      mount.textContent = stripTags(body);
      repopulate();
      return;
    }
    if (plan.kind === "fetchHtml") {
      if (!fetchFn) {
        fail(plan.path, "fetch not provided");
        return;
      }
      load = "loading";
      replaceHistory(plan.path);
      const resp = await fetchFn(plan.path, { method: "GET" });
      const status = resp && Number(resp.status);
      el.setAttribute("src", plan.path);
      srcdocValue = "";
      if (!resp || !resp.ok || status !== 200) {
        load = "error: HTTP " + (status || 0);
        return;
      }
      load = String(status);
      const html = typeof resp.text === "function" ? await resp.text() : String(resp.body || "");
      mount.textContent = stripTags(html);
      repopulate();
      return;
    }
    if (plan.kind === "fetchRemote") {
      if (!hostFetch) {
        fail(plan.url, "fetch not provided");
        return;
      }
      load = "loading";
      replaceHistory(plan.url);
      const resp = await hostFetch(plan.url, { method: "GET", redirect: "error" });
      const status = resp && Number(resp.status);
      el.setAttribute("src", plan.url);
      srcdocValue = "";
      if (!resp || !resp.ok || status !== 200) {
        load = "error: HTTP " + (status || 0);
        repopulate();
        return;
      }
      load = String(status);
      const html = typeof resp.text === "function" ? await resp.text() : String(resp.body || "");
      mount.textContent = stripTags(html);
      repopulate();
      return;
    }
  }
  async function applySrcdoc(html) {
    const plan = planSrcdoc(html);
    srcdocValue = plan.html;
    repopulate();
    replaceHistory("about:srcdoc");
    load = "ok";
    mount.textContent = stripTags(srcdocValue);
    el.setAttribute("src", "about:srcdoc");
    el.setAttribute("srcdoc", srcdocValue);
  }
  Object.defineProperty(el, "src", { get() { return location; }, set(v) { pending = navigate(v); }, configurable: true });
  Object.defineProperty(el, "srcdoc", { get() { return srcdocValue; }, set(v) { pending = applySrcdoc(v); }, configurable: true });
  Object.defineProperty(el, "contentWindow", { get() { return nested.window; }, configurable: true });
  Object.defineProperty(el, "contentDocument", { get() { return nested.document; }, configurable: true });
  Object.defineProperty(el, "vars", {
    get() { return varsMap; },
    set(v) {
      varsMap = normalizeVars(v);
      el.setAttribute("vars", typeof v === "string" ? v : "");
      if (nested && typeof nested.defineGlobal === "function") {
        for (const k of Object.keys(varsMap)) nested.defineGlobal(k, varsMap[k]);
      }
    },
    configurable: true,
  });
  el.context = () => nested;
  if (typeof opts.vars === "string") el.setAttribute("vars", opts.vars);
  el.ready = () => pending;
  el.loadState = () => load;
  el.historyEntries = () => history.slice();
  el.mount = mount;
  return el;
}
