<script lang="ts">
  import { fetchBios, holycEval } from "./kernel.ts";
  let title = "CPU";
  fetchBios("/bios/menu/cpu");
  fetchBios("/bios/cpu");
  holycEval("MenuCpu()");
</script>

<section id="menu-cpu">
  <p id="cpu-title">{title}</p>
</section>
