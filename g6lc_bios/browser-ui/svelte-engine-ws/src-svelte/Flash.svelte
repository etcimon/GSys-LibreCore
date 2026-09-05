<script lang="ts">
  import { fetchBios, holycEval } from "./kernel.ts";
  let images = "Read-only USB image listing; not refreshed";
  fetchBios("/bios/usb/ls");
  holycEval("UsbLs(\"fat32\")");
</script>

<section id="usb-flash">
  <p id="usb-title">USB-FAT32</p>
  <p id="usb-list">{images}</p>
</section>
