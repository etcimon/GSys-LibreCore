// Generated from src/Settings.svelte (lang=ts)
import { ensureSvelteD } from "../libwasm.ts";

export function fetchBios(url: string) { fetch(url); }
export function holycEval(line: string) { return kernel.holyc(line); }
export function registerEndpoint(path: string, method = "GET") { kernel.register(path, method); }

const _reg = ensureSvelteD();
_reg.registerTs("Settings_svelte", "fetchBios", fetchBios);
_reg.registerTs("Settings_svelte", "holycEval", holycEval);
_reg.registerTs("Settings_svelte", "registerEndpoint", registerEndpoint);
export function mount() {
  fetchBios("/bios/menu/settings");
  fetchBios("/bios/settings");
  fetchBios("/bios/settings/usb");
  holycEval("Menu(\"settings\")");
}
