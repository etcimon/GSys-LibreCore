<script lang="ts">
  import { fetchBios, holycEval } from "./kernel.ts";
  let title = "Boot";
  fetchBios("/bios/menu/boot");
  fetchBios("/bios/bootloader");
  holycEval("Menu(\"boot\")");
</script>

<section id="menu-boot">
  <p id="boot-title">{title}</p>
</section>
