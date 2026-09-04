/**
 * Copyright 2019 Google Inc. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import {
  formatAwaitReason,
  recordAwaitFail,
  recordAwaitOk,
} from './await-status';

// Put `__asyncify_data` somewhere at the start.
// This address is pretty hand-wavy and we might want to make it configurable in future.
// See https://github.com/WebAssembly/binaryen/blob/6371cf63687c3f638b599e086ca668c04a26cbbb/src/passes/Asyncify.cpp#L106-L113
// for structure details.

// _start must be wrapped: App.construct / ready / default navigateTo that
// .await would unwind and never rewind if called raw (libwasm.ts).
// wireAwait now calls JsPromise.await; that import only rewinds if the
// export that reached it is wrapped.
export const EXPORTED_FROM_D = [
  '_start',
  'domEvent',
  'jsCallback0',
  'jsCallback',
  'loadApp',
  'dumpApp',
  'svelte_engine_eh_probe',
  'svelte_engine_phobos_probe',
];

// Start unwind buffers halfway through the stack space
const DATA_ADDR = 524288;
// Place actual data right after the descriptor (which is 2 * sizeof(i32) = 8 bytes).
const DATA_START = DATA_ADDR + 8;
// End data at "-Lstack-size=1048576", configured in ldc2.conf for wasm by default
// ideally we would use `__stack_pointer` here, but, sadly, it's not exposed via exports yet.
const DATA_END = 1048576;

const WRAPPED_EXPORTS = new WeakMap();

export const State = {
  None: 0,
  Unwinding: 1,
  Rewinding: 2,
};

function isPromise(obj: any) {
  return (
    !!obj &&
    (typeof obj === 'object' || typeof obj === 'function') &&
    typeof obj.then === 'function'
  );
}

function proxyGet(obj: any, transform: any) {
  return new Proxy(obj, {
    get: (obj, name) => transform(obj[name]),
  });
}

export class Asyncify {
  exports: any;
  value: any;
  lastError: unknown;
  failed: boolean;
  lastExport: string;
  queue: Promise<unknown>;
  constructor() {
    this.value = undefined;
    this.exports = null;
    this.lastError = null;
    this.failed = false;
    this.lastExport = '';
    this.queue = Promise.resolve();
  }

  getState() {
    return this.exports.asyncify_get_state();
  }

  assertNoneState() {
    let state = this.getState();
    if (state !== State.None) {
      throw new Error(`Invalid async state ${state}, expected 0.`);
    }
  }

  wrapImportFn(fn: any) {
    return (...args: any) => {
      let curState = this.getState();
      if (curState === State.Rewinding) {
        this.exports.asyncify_stop_rewind();
        return this.value;
      }
      this.assertNoneState();
      try {
        let value = fn(...args);
        if (!isPromise(value)) {
          return value;
        }
        this.exports.asyncify_start_unwind(DATA_ADDR);
        this.value = value;
      } catch (e) {
        console.error("[wrapImportFn] Error in asyncify'd function: ", e);
        throw e;
      }
    };
  }

  wrapModuleImports(module: any) {
    return proxyGet(module, (value: any) => {
      if (typeof value === 'function') {
        return this.wrapImportFn(value);
      }
      return value;
    });
  }

  wrapImports(imports: any) {
    if (imports === undefined) return;

    return proxyGet(imports, (moduleImports = Object.create(null)) =>
      this.wrapModuleImports(moduleImports)
    );
  }

  wrapExportFn(fn: any, exportName: string) {
    let newExport = WRAPPED_EXPORTS.get(fn);

    if (newExport !== undefined) {
      return newExport;
    }

    const run = async (...args: any) => {
      this.assertNoneState();
      this.lastExport = exportName;
      try {
        let result = await fn(...args);

        while (this.getState() === State.Unwinding) {
          this.exports.asyncify_stop_unwind();
          // Reject must still rewind: landing pads are not on this stack,
          // but ScopedPool dtors are. Record the reason; D reads it after
          // rewind (libwasm_await_failed). Do not throw before start_rewind.
          try {
            this.value = await this.value;
            this.lastError = null;
            this.failed = false;
            recordAwaitOk(exportName, this.value);
          } catch (e) {
            this.lastError = e;
            this.failed = true;
            this.value = null;
            recordAwaitFail(e, exportName);
          }
          this.assertNoneState();
          this.exports.asyncify_start_rewind(DATA_ADDR);
          result = await fn(...args);
        }

        this.assertNoneState();
        return result;
      } catch (e) {
        // Keep WebAssembly.Exception so wasm-eh host hooks can see it.
        // Do not wrap it in a generic Error (that hid D throws from spa.ts).
        const rewrite =
          typeof window !== 'undefined'
            ? (window as any).__svelteDRewriteError
            : null;
        const shown =
          typeof rewrite === 'function' ? rewrite(e) : formatAwaitReason(e);
        console.log('While calling: ', exportName, args, shown);
        throw e;
      }
    };

    // One in-flight unwind. Overlapping domEvent/jsCallback corrupt state.
    newExport = (...args: any) => {
      const p = this.queue.then(
        () => run(...args),
        () => run(...args)
      );
      this.queue = p.then(
        () => undefined,
        () => undefined
      );
      return p;
    };

    WRAPPED_EXPORTS.set(fn, newExport);

    return newExport;
  }

  wrapExports(exports: any) {
    let newExports = Object.create(null);

    for (let exportName in exports) {
      let value = exports[exportName];
      if (typeof value === 'function' && EXPORTED_FROM_D.includes(exportName)) {
        value = this.wrapExportFn(value, exportName);
      }
      Object.defineProperty(newExports, exportName, {
        enumerable: true,
        value,
      });
    }

    WRAPPED_EXPORTS.set(exports, newExports);

    return newExports;
  }

  init(instance: any, imports: any) {
    const { exports } = instance;

    const memory = exports.memory || (imports.env && imports.env.memory);

    new Int32Array(memory.buffer, DATA_ADDR).set([DATA_START, DATA_END]);

    this.exports = this.wrapExports(exports);

    Object.setPrototypeOf(instance, Instance.prototype);
  }
}

export class Instance extends WebAssembly.Instance {
  constructor(module: any, imports: any) {
    let state = new Asyncify();
    super(module, state.wrapImports(imports));
    state.init(this, imports);
  }

  get exports() {
    return WRAPPED_EXPORTS.get(super.exports);
  }
}

Object.defineProperty(Instance.prototype, 'exports', { enumerable: true });

export function moduleHasAsyncify(mod: WebAssembly.Module) {
  return WebAssembly.Module.exports(mod).some(
    (e) => e.name === 'asyncify_get_state'
  );
}

/// Raw instantiate. Used when the module has no asyncify_get_state
/// (stock Binaryen 123/132 cannot --asyncify try_table). The
/// etcimon/binaryen fork emits asyncify_get_state; instantiate() then
/// wraps exports. EH probes still run without wrapping (no await).
export async function instantiateRaw(source: any, imports: any) {
  const result = await WebAssembly.instantiate(source, imports);
  return result instanceof WebAssembly.Instance
    ? { instance: result, module: undefined }
    : result;
}

export async function instantiate(source: any, imports: any) {
  const compiled =
    source instanceof WebAssembly.Module
      ? source
      : await WebAssembly.compile(source);
  if (!moduleHasAsyncify(compiled)) {
    const instance = await WebAssembly.instantiate(compiled, imports);
    return { instance, module: compiled };
  }
  let state = new Asyncify();
  let result = await WebAssembly.instantiate(
    compiled,
    state.wrapImports(imports)
  );
  state.init(
    result instanceof WebAssembly.Instance ? result : result.instance,
    imports
  );
  return result;
}

export async function instantiateStreaming(source: any, imports: any) {
  const res = await source;
  const buf = res instanceof Response ? await res.arrayBuffer() : res;
  return instantiate(buf, imports);
}
