<script lang="ts">
  import { fetchBios, holycEval } from "./kernel.ts";
  let title = "Devices";
  fetchBios("/bios/menu/devices");
  holycEval("Menu(\"devices\")");
</script>

<section id="menu-devices">
  <p id="devices-title">{title}</p>
</section>
