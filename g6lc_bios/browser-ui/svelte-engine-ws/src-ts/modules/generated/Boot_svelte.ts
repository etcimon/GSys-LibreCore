// Generated from src/Boot.svelte (lang=ts)
import { ensureSvelteD } from "../libwasm.ts";

export function fetchBios(url: string) { fetch(url); }
export function holycEval(line: string) { return kernel.holyc(line); }
export function registerEndpoint(path: string, method = "GET") { kernel.register(path, method); }

const _reg = ensureSvelteD();
_reg.registerTs("Boot_svelte", "fetchBios", fetchBios);
_reg.registerTs("Boot_svelte", "holycEval", holycEval);
_reg.registerTs("Boot_svelte", "registerEndpoint", registerEndpoint);
export function mount() {
  fetchBios("/bios/menu/boot");
  fetchBios("/bios/bootloader");
  holycEval("Menu(\"boot\")");
}
