<script lang="ts">
  import { fetchBios, holycEval } from "./kernel.ts";
  let title = "Main";
  fetchBios("/bios/menu/main");
  holycEval("Menu(\"main\")");
</script>

<section id="menu-main">
  <p id="main-title">{title}</p>
</section>
