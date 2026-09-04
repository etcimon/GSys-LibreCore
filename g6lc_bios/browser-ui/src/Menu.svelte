<script lang="ts">
  import { fetchBios, holycEval } from "./kernel.ts";
  let title = "Main CPU Memory Uncore Devices Boot Settings";
  fetchBios("/bios/menu");
  fetchBios("/bios/menu/cpu");
  fetchBios("/bios/menu/uncore");
  holycEval("MenuCpu()");
  holycEval("MenuUncore()");
</script>

<nav id="bios-menu">
  <p id="menu-title">{title}</p>
</nav>
