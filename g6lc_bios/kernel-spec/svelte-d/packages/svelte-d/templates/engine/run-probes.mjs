// Load svelte-engine-raw.wasm with the same EH env the TS runtime
// installs (__cpp_exception tag + env stubs) and call the D probes.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
// Inline the same ABI as src-ts/modules/error-handling.ts so Node
// does not need a TypeScript loader.
function createCppExceptionTag() {
  return new WebAssembly.Tag({ parameters: ['i32'] });
}
function isWasmException(e) {
  return (
    typeof WebAssembly.Exception === 'function' &&
    e instanceof WebAssembly.Exception
  );
}
function installErrorHandling(env, decode, abort) {
  env.onAssertErrorMsg = (fileLen, filePtr, line, msgLen, msgPtr) => {
    abort('assert', decode(fileLen, filePtr), line, decode(msgLen, msgPtr));
  };
  env.captureException = (msgLen, msgPtr) => {
    abort('exception', '', 0, decode(msgLen, msgPtr));
  };
  env._Unwind_Resume = () => abort('unwind', '', 0, '_Unwind_Resume');
  env._d_delThrowable = () => {};
  if (!env.__cpp_exception) env.__cpp_exception = createCppExceptionTag();
  return env;
}
function wrapEnvWithStubs(env) {
  const nop = () => 0;
  return new Proxy(env, {
    get(t, k) {
      if (k in t) return t[k];
      return nop;
    },
    has() {
      return true;
    },
  });
}

const dir = dirname(fileURLToPath(import.meta.url));
const raw = join(dir, 'public', 'svelte-engine-raw.wasm');
const ship = join(dir, 'public', 'svelte-engine.wasm');
const extra = process.argv.slice(2).filter((a) => a.endsWith('.wasm'));
const targets = extra.length
  ? extra
  : [raw, ship].filter((p) => {
      try {
        readFileSync(p);
        return true;
      } catch {
        return false;
      }
    });
if (!targets.length) {
  console.error('FAIL: no wasm (public/svelte-engine-raw.wasm)');
  process.exit(1);
}

const abort = (what, file, line, msg) => {
  throw new Error(`ABORT: ${what} @ ${file}:${line} ${msg}`);
};
const decode = (len, ptr) => {
  if (typeof len === 'string') return len;
  return `str(${len},${ptr})`;
};

let env = { __cpp_exception: createCppExceptionTag() };
installErrorHandling(env, decode, abort);
env = wrapEnvWithStubs(env);

async function runOne(path) {
  const label = path.replace(/\\/g, '/').split('/').pop();
  const buf = readFileSync(path);
  const compiled = new WebAssembly.Module(buf);
  const hasAy = WebAssembly.Module.exports(compiled).some(
    (e) => e.name === 'asyncify_get_state'
  );
  const got = await WebAssembly.instantiate(compiled, { env });
  const instance = got instanceof WebAssembly.Instance ? got : got.instance;
  const mem = instance.exports.memory;
  if (mem && mem.grow) {
    try {
      mem.grow(64);
    } catch {
      /* already large */
    }
  }

  function call(name) {
    const fn = instance.exports[name];
    if (typeof fn !== 'function') {
      console.error(`FAIL: ${label} ${name} not exported`);
      process.exit(1);
    }
    try {
      return fn();
    } catch (e) {
      if (isWasmException(e)) {
        console.error(
          `FAIL: ${label} ${name} threw WebAssembly.Exception (uncaught D throw)`
        );
      } else {
        console.error(`FAIL: ${label} ${name} threw`, e);
      }
      process.exit(1);
    }
  }

  const eh = call('svelte_engine_eh_probe');
  if (eh !== 1) {
    console.error('FAIL:', label, 'svelte_engine_eh_probe returned', eh);
    process.exit(1);
  }
  console.log(
    'PASS:',
    label,
    'svelte_engine_eh_probe returned 1 (D catch ran)',
    hasAy ? '[asyncify]' : '[raw]'
  );

  const ph = call('svelte_engine_phobos_probe');
  if (ph !== 1) {
    console.error(
      'FAIL:',
      label,
      'svelte_engine_phobos_probe returned',
      ph,
      '(bitmask; -1 init, -2 uncaught)'
    );
    process.exit(1);
  }
  console.log(
    'PASS:',
    label,
    'svelte_engine_phobos_probe returned 1 (Phobos + D catch)',
    hasAy ? '[asyncify]' : '[raw]'
  );
}

for (const t of targets) {
  await runOne(t);
}
process.exit(0);
