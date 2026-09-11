// Generated from src/App.svelte (lang=ts)
import { ensureSvelteD } from "../libwasm.ts";

export function fetchBios(url: string) { fetch(url); }
export function holycEval(line: string) { return kernel.holyc(line); }
export function registerEndpoint(path: string, method = "GET") { kernel.register(path, method); }
export function pgliteOpen(dataDir = "registry") { return pglite(dataDir); }
declare const pglite: (dataDir?: string) => {
  exec(sql: string): Promise<unknown>;
  query(sql: string, params?: string): Promise<unknown>;
  queryAsync(sql: string, params?: string): Promise<unknown>;
  stat(): Promise<{ ok?: boolean; live?: boolean; ready?: boolean }>;
  waitReady(): unknown;
  listen(channel: string): Promise<unknown>;
  unlisten(channel?: string): Promise<unknown>;
  begin(): Promise<unknown>;
  commit(): Promise<unknown>;
  rollback(): Promise<unknown>;
  dump(): Promise<unknown>;
  load(json: string): Promise<unknown>;
  close(): Promise<unknown>;
  exportUsb?(volume: string, rel?: string): Promise<unknown>;
};

const _reg = ensureSvelteD();
_reg.registerTs("App_svelte", "fetchBios", fetchBios);
_reg.registerTs("App_svelte", "holycEval", holycEval);
_reg.registerTs("App_svelte", "registerEndpoint", registerEndpoint);
export function mount() {
  fetchBios("/bios/menu");
  fetchBios("/bios/menu/main");
  registerEndpoint("/bios/custom", "POST");
}
