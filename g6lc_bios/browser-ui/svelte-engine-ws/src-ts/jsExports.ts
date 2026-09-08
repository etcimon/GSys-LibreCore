// Generated jsExports — window.__svelteD.ts registry (svelte-d).
declare const kernel: { holyc(line: string): string; register(path: string, method?: string): void };
declare const window: { __svelteD?: SvelteDRegistry } & Record<string, unknown>;

export type SvelteDFn = (...args: unknown[]) => unknown;
export type SvelteDRegistry = {
  ts: Record<string, Record<string, SvelteDFn>>;
  d: Record<string, Record<string, SvelteDFn>>;
  registerTs(mod: string, name: string, fn: SvelteDFn): void;
};

export function ensureSvelteD(): SvelteDRegistry {
  const w = window as typeof window;
  if (!w.__svelteD) {
    const reg: SvelteDRegistry = {
      ts: {},
      d: {},
      registerTs(mod, name, fn) {
        if (!this.ts[mod]) this.ts[mod] = {};
        this.ts[mod][name] = fn;
      },
    };
    w.__svelteD = reg;
  }
  return w.__svelteD as SvelteDRegistry;
}

ensureSvelteD();

export const jsExports = {
  env: {
    set_inner_text(_id: string, _val: string) {},
    fetch(url: string) { return fetch(url); },
    holycEval(line: string) { return kernel.holyc(line); },
  },
};
// module App_svelte
