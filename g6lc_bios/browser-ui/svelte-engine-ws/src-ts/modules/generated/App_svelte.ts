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
  fetchBios("/bios/menu");
  fetchBios("/bios/menu/main");
  fetchBios("/bios/menu/cpu");
  fetchBios("/bios/menu/memory");
  fetchBios("/bios/menu/uncore");
  fetchBios("/bios/menu/devices");
  fetchBios("/bios/menu/boot");
  fetchBios("/bios/menu/settings");
  fetchBios("/bios/clocks");
  fetchBios("/bios/bootloader");
  fetchBios("/bios/display");
  fetchBios("/bios/settings");
  fetchBios("/bios/settings/usb");
  fetchBios("/bios/usb/ls");
  fetchBios("/bios/files");
  fetchBios("/bios/files/fat32");
  fetchBios("/bios/files/ntfs");
  fetchBios("/bios/files/ext4");
  holycEval("Menu(\"main\")");
  registerEndpoint("/bios/custom", "POST");
}
