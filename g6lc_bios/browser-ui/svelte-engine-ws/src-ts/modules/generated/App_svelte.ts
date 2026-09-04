// Generated from src/App.svelte (lang=ts)
import { ensureSvelteD } from "../libwasm.ts";

export function fetchBios(url: string) { fetch(url); }
export function holycEval(line: string) { return kernel.holyc(line); }
export function registerEndpoint(path: string, method = "GET") { kernel.register(path, method); }

const _reg = ensureSvelteD();
_reg.registerTs("App_svelte", "fetchBios", fetchBios);
_reg.registerTs("App_svelte", "holycEval", holycEval);
_reg.registerTs("App_svelte", "registerEndpoint", registerEndpoint);
export function mount() {
  fetchBios("/bios/clocks");
  fetchBios("/bios/menu");
  holycEval("UsbLs(\"fat32\")");
  holycEval("MenuCpu()");
  registerEndpoint("/bios/custom", "GET");
}
