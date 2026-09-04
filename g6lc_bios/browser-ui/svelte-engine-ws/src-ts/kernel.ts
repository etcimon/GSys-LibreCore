// HolyC / kernel JS exports (copied into the dropped ws).
declare const kernel: { holyc(line: string): string; register(path: string, method?: string): void };
export function fetchBios(url: string): void { fetch(url); }
export function holycEval(line: string): string { return kernel.holyc(line); }
export function registerEndpoint(path: string, method = "GET"): void { kernel.register(path, method); }
export const jsExports = { env: { fetchBios, holycEval, registerEndpoint } };
