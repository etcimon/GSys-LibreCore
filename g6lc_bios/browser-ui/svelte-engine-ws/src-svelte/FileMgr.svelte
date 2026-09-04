<script lang="ts">
  import { fetchBios, holycEval } from "./kernel.ts";
  let listing = "USB-FILES";
  fetchBios("/bios/files");
  fetchBios("/bios/files/fat32");
  fetchBios("/bios/files/ntfs");
  fetchBios("/bios/files/ext4");
  holycEval("UsbLs(\"ntfs\")");
</script>

<section id="filemgr">
  <p id="fm-tabs">fat32 ntfs ext4</p>
  <p id="fm-list">{listing}</p>
</section>
