// Generated from src/FileMgr.svelte (lang=ts)
import { ensureSvelteD } from "../libwasm.ts";

export function fetchBios(url: string) { fetch(url); }
export function holycEval(line: string) { return kernel.holyc(line); }
export function registerEndpoint(path: string, method = "GET") { kernel.register(path, method); }

const _reg = ensureSvelteD();
_reg.registerTs("FileMgr_svelte", "fetchBios", fetchBios);
_reg.registerTs("FileMgr_svelte", "holycEval", holycEval);
_reg.registerTs("FileMgr_svelte", "registerEndpoint", registerEndpoint);
export function mount() {
  fetchBios("/bios/files");
  fetchBios("/bios/files/fat32");
  fetchBios("/bios/files/ntfs");
  fetchBios("/bios/files/ext4");
  holycEval("UsbLs(\"ntfs\")");
}
