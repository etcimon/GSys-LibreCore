// Generated from src/Menu.svelte (lang=ts)
import { ensureSvelteD } from "../libwasm.ts";

export function fetchBios(url: string) { fetch(url); }
export function holycEval(line: string) { return kernel.holyc(line); }
export function registerEndpoint(path: string, method = "GET") { kernel.register(path, method); }

const _reg = ensureSvelteD();
_reg.registerTs("Menu_svelte", "fetchBios", fetchBios);
_reg.registerTs("Menu_svelte", "holycEval", holycEval);
_reg.registerTs("Menu_svelte", "registerEndpoint", registerEndpoint);
export function mount() {
  fetchBios("/bios/menu");
  fetchBios("/bios/menu/cpu");
  fetchBios("/bios/menu/uncore");
  holycEval("MenuCpu()");
  holycEval("MenuUncore()");
}
