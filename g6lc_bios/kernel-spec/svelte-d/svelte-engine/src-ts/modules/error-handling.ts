// Slideshow host EH runtime. Mirrors libwasm runtime-v1.43.0/js/error-handling.ts
// plus the wasm-eh tag the LDC 1.43 frontend expects (`__cpp_exception`).
//
// 1.36 / 1.42: DtoThrow → _d_throw_exception → captureException → abort.
// 1.43+: _d_throw_exception is llvm_wasm_throw(tag 0). Caught D try/catch
// stays in wasm. Uncaught throws become WebAssembly.Exception here.

export type AbortFn = (
  what: string,
  file: string,
  line: number,
  msg: string
) => void;

export type StringDecoder = (len: number | string, ptr?: number) => string;

export function createCppExceptionTag(): WebAssembly.Tag {
  return new WebAssembly.Tag({ parameters: ['i32'] });
}

export function isWasmException(e: unknown): boolean {
  return (
    typeof WebAssembly !== 'undefined' &&
    typeof (WebAssembly as any).Exception === 'function' &&
    e instanceof (WebAssembly as any).Exception
  );
}

/** Stringify a wasm-eh throw or a JS reject for DevTools / lastAwait. */
export function formatHostError(e: unknown): string {
  if (isWasmException(e)) return 'WebAssembly.Exception';
  if (e == null) return '';
  if (typeof e === 'string') return e;
  const err = e as { message?: unknown; stack?: unknown };
  if (err && typeof err.stack === 'string' && err.stack.length) return err.stack;
  if (err && typeof err.message === 'string') return err.message;
  try {
    return String(e);
  } catch {
    return 'error';
  }
}

export function installErrorHandling(
  env: Record<string, any>,
  decode: StringDecoder,
  abort: AbortFn
): Record<string, any> {
  env.onAssertErrorMsg = (
    fileLen: number,
    filePtr: number,
    line: number,
    msgLen: number,
    msgPtr: number
  ) => {
    abort('assert', decode(fileLen, filePtr), line, decode(msgLen, msgPtr));
  };

  env.onUnittestErrorMsg = (
    fileLen: number,
    filePtr: number,
    line: number,
    msgLen: number,
    msgPtr: number
  ) => {
    abort('unittest', decode(fileLen, filePtr), line, decode(msgLen, msgPtr));
  };

  // Pre-1.43 throw path. Same ABI as onAssertErrorMsg (len + ptr).
  env.captureException = (msgLen: number, msgPtr: number) => {
    abort('exception', '', 0, decode(msgLen, msgPtr));
  };

  env._Unwind_Resume = () => abort('unwind', '', 0, '_Unwind_Resume');
  env._d_delThrowable = () => {};
  env.__cxa_begin_catch = (ptr: number) => ptr;
  env.__cxa_end_catch = () => {};
  env.__cxa_rethrow = () => abort('exception', '', 0, '__cxa_rethrow');

  if (!env.__cpp_exception) env.__cpp_exception = createCppExceptionTag();
  return env;
}

/// Fill missing env imports with no-ops so a 1.43 EH module can link
/// without listing every DOM/gc leftover.
export function wrapEnvWithStubs(env: Record<string, any>): Record<string, any> {
  const nop = () => 0;
  return new Proxy(env, {
    get(t, k) {
      if (k in t) return t[k as string];
      return nop;
    },
    has() {
      return true;
    },
  });
}
