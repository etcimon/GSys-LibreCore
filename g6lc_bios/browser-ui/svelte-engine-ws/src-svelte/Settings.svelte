<script lang="ts">
  import { fetchBios, holycEval } from "./kernel.ts";
  let title = "Settings";
  fetchBios("/bios/menu/settings");
  fetchBios("/bios/settings");
  fetchBios("/bios/settings/usb");
  holycEval("Menu(\"settings\")");
</script>

<section id="menu-settings">
  <p id="settings-title">{title}</p>
</section>
