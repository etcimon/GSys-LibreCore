<script lang="ts">
  import { fetchBios, holycEval, registerEndpoint } from "./kernel.ts";
  let status = "UI-BOOT";
  fetchBios("/bios/clocks");
  fetchBios("/bios/menu");
  holycEval("UsbLs(\"fat32\")");
  holycEval("MenuCpu()");
  registerEndpoint("/bios/custom");
</script>

<section id="bios-ui">
  <p id="status">{status}</p>
  <nav id="bios-nav">Main CPU Memory Uncore Devices Boot Settings</nav>
</section>
