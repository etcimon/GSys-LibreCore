<script lang="ts">
  import { fetchBios, holycEval, registerEndpoint } from "./kernel.ts";
  let status = "UI-BOOT";
  fetchBios("/bios/clocks");
  await fetchBios("/bios/menu");
  holycEval("UsbLs(\"fat32\")");
  holycEval("MenuCpu()");
  registerEndpoint("/bios/custom");
</script>

<section id="bios-ui">
  <p id="status">{status}</p>
  <nav id="bios-nav">Main CPU Memory Uncore Devices Boot Settings</nav>
</section>

<style>
#bios-fx { position: fixed; inset: 0; width: 100vw; height: 100vh; z-index: 0; pointer-events: none; }
#bios-ui { position: relative; z-index: 1; }
#bios-ui[data-fx-active="true"] { background: rgba(0, 0, 64, .74); box-shadow: 0 0 3rem #170c45; }
#bios-ui[data-fx-active="true"] section, #bios-ui[data-fx-active="true"] nav { background: rgba(0, 0, 96, .58); }
#bios-ui[data-fx-active="true"] #banner { background: rgba(0, 128, 150, .78); }
#fx-status { font-size: .8em; color: #a9defa; }
#fx-motion { margin-block: 1ch; }
@media (prefers-reduced-motion: reduce) { #bios-ui { scroll-behavior: auto; } }
</style>
