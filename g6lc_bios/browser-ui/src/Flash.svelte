<script lang="ts">
  import { fetchBios, holycEval } from "./kernel.ts";
  let images = "openwrt.bin";
  fetchBios("/bios/usb/ls");
  holycEval("UsbFlash(\"openwrt.bin\")");
</script>

<section id="usb-flash">
  <p id="usb-title">USB-FAT32</p>
  <p id="usb-list">{images}</p>
</section>
