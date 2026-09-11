<script>
fetchBios("/bios/store");
pgliteOpen("memory://registry");
await pgliteWaitReady();
pgliteExec("CREATE TABLE IF NOT EXISTS bios_ui (k TEXT PRIMARY KEY, v TEXT)");
let rows = await pgliteQuery("SELECT k, v FROM bios_ui", "[]");
</script>
<section id="store" data-menu="settings" aria-labelledby="store-title" hidden>
  <h2 id="store-title">Store</h2>
  <p id="store-status">{rows}</p>
</section>
