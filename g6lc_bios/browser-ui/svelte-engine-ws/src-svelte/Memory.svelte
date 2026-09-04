<script lang="ts">
  import { fetchBios, holycEval } from "./kernel.ts";
  let title = "Memory";
  fetchBios("/bios/menu/memory");
  holycEval("Menu(\"memory\")");
</script>

<section id="menu-memory">
  <p id="memory-title">{title}</p>
</section>
