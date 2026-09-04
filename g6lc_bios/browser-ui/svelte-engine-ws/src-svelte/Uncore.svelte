<script lang="ts">
  import { fetchBios, holycEval } from "./kernel.ts";
  let title = "Uncore";
  fetchBios("/bios/menu/uncore");
  fetchBios("/bios/uncore");
  holycEval("MenuUncore()");
</script>

<section id="menu-uncore">
  <p id="uncore-title">{title}</p>
</section>
