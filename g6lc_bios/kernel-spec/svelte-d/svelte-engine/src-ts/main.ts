import { libwasm, modules } from './modules'
import { installSvelteDDebug } from './modules/debug-bridge'
import '../styles/index.css'
import { PGlite } from '@electric-sql/pglite';
(window as any).pglite = new PGlite('./db');
// Install before wasm so DevTools console rewrites even if _start fails.
void installSvelteDDebug().then(() => libwasm.libwasm.init(modules))