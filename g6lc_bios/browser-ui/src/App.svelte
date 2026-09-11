<script lang="ts">
  import { fetchBios, holycEval, registerEndpoint, attachPlatformGlobal, onHwEvent } from "./kernel.ts";
  attachPlatformGlobal(globalThis);
  onHwEvent(() => { attachPlatformGlobal(globalThis); });
  holycEval('Menu("main")');
  registerEndpoint("/bios/custom", "POST");
  fetchBios("/bios/menu");
  fetchBios("/bios/menu/main");
</script>

<main id="bios-ui" data-start-menu="main" data-worker-url="WORKER_URL_PLACEHOLDER" data-worker-limit="WORKER_LIMIT_PLACEHOLDER" data-wasm-url="WASM_URL_PLACEHOLDER">
  <h1 id="banner">G6LC-BIOS | GSys LibreCore</h1>
  <img id="bios-mark" src="/ui/g6lc.svg" width="48" height="24" alt="G6LC">
  <p id="profile"></p>
  <nav id="bios-menu" role="tablist" aria-label="Setup menus">
    <span id="menu-title">SETUP</span>
    <a id="tab-main" class="bios-tab bios-tab-active" href="#menu-main" data-menu-link="main" role="tab" tabindex="0" aria-selected="true" on:click="{selectTab}">Main</a>
    <a id="tab-cpu" class="bios-tab" href="#menu-cpu" data-menu-link="cpu" role="tab" tabindex="-1" aria-selected="false" on:click="{selectTab}">CPU</a>
    <a id="tab-memory" class="bios-tab" href="#menu-memory" data-menu-link="memory" role="tab" tabindex="-1" aria-selected="false" on:click="{selectTab}">Memory</a>
    <a id="tab-uncore" class="bios-tab" href="#menu-uncore" data-menu-link="uncore" role="tab" tabindex="-1" aria-selected="false" on:click="{selectTab}">Uncore</a>
    <a id="tab-devices" class="bios-tab" href="#menu-devices" data-menu-link="devices" role="tab" tabindex="-1" aria-selected="false" on:click="{selectTab}">Devices</a>
    <a id="tab-boot" class="bios-tab" href="#menu-boot" data-menu-link="boot" role="tab" tabindex="-1" aria-selected="false" on:click="{selectTab}">Boot</a>
    <a id="tab-settings" class="bios-tab" href="#menu-settings" data-menu-link="settings" role="tab" tabindex="-1" aria-selected="false" on:click="{selectTab}">Settings</a>
  </nav>
  <p id="status" role="status">UI-BOOT</p>
  <p id="bios-nav" hidden></p>
  <p id="hw-nat-status" role="status"></p>
  <p id="read-only-note">Read-only BoardSpec setup. F10 refreshes values. Editing and flash are unavailable here.</p>
  <button id="refresh" type="button" on:click="{refresh}">Refresh values</button>

  <section id="menu-main" data-menu="main" aria-labelledby="main-title">
    <h2 id="main-title">Main</h2>
    <table>
      <thead>
        <tr><th class="col-head">Setting</th><th class="col-head">Value</th><th class="col-head">Access</th></tr>
      </thead>
      <tbody id="menu-main-body"></tbody>
    </table>
  </section>
  <section id="menu-cpu" data-menu="cpu" aria-labelledby="cpu-title" hidden>
    <h2 id="cpu-title">CPU</h2>
    <table>
      <thead>
        <tr><th class="col-head">Setting</th><th class="col-head">Value</th><th class="col-head">Access</th></tr>
      </thead>
      <tbody id="menu-cpu-body"></tbody>
    </table>
  </section>
  <section id="menu-memory" data-menu="memory" aria-labelledby="memory-title" hidden>
    <h2 id="memory-title">Memory</h2>
    <table>
      <thead>
        <tr><th class="col-head">Setting</th><th class="col-head">Value</th><th class="col-head">Access</th></tr>
      </thead>
      <tbody id="menu-memory-body"></tbody>
    </table>
  </section>
  <section id="menu-uncore" data-menu="uncore" aria-labelledby="uncore-title" hidden>
    <h2 id="uncore-title">Uncore</h2>
    <table>
      <thead>
        <tr><th class="col-head">Setting</th><th class="col-head">Value</th><th class="col-head">Access</th></tr>
      </thead>
      <tbody id="menu-uncore-body"></tbody>
    </table>
  </section>
  <section id="menu-devices" data-menu="devices" aria-labelledby="devices-title" hidden>
    <h2 id="devices-title">Devices</h2>
    <table>
      <thead>
        <tr><th class="col-head">Setting</th><th class="col-head">Value</th><th class="col-head">Access</th></tr>
      </thead>
      <tbody id="menu-devices-body"></tbody>
    </table>
  </section>
  <section id="menu-boot" data-menu="boot" aria-labelledby="boot-title" hidden>
    <h2 id="boot-title">Boot</h2>
    <table>
      <thead>
        <tr><th class="col-head">Setting</th><th class="col-head">Value</th><th class="col-head">Access</th></tr>
      </thead>
      <tbody id="menu-boot-body"></tbody>
    </table>
  </section>
  <section id="menu-settings" data-menu="settings" aria-labelledby="settings-title" hidden>
    <h2 id="settings-title">Settings</h2>
    <table>
      <thead>
        <tr><th class="col-head">Setting</th><th class="col-head">Value</th><th class="col-head">Access</th></tr>
      </thead>
      <tbody id="menu-settings-body"></tbody>
    </table>
  </section>

  <div id="g6b-ui-conditional"></div>
  <footer>
    <p id="bios-hint">ArrowLeft/ArrowRight Select tab   Home/End First/Last   F10 Refresh (not save)   Esc stays in setup</p>
  </footer>
</main>

<style>
/*
 * System BIOS setup chrome. Only selector shapes the first-party CSS cascade
 * can match (element, #id, .class) so the raster and a real browser agree.
 */
body{font:16px "Inconsolata","Courier New",monospace;background-color:#050a18;color:#c9e9f5;margin:0;padding:12px}
#bios-ui{max-width:1100px;margin:0 auto}
h1#banner{background-color:#0b7f96;color:#eaffff;text-align:center;padding:8px;margin:0;font-weight:bold;border:1px solid #22d3ee;border-radius:6px}
#profile{color:#7fd4e8;margin:6px 0;font-size:14px}
h2{color:#22d3ee;margin:8px 0}
a{color:#ffd166}
button{font:inherit}
.bios-tab{display:inline-block;padding:6px 12px;margin:0 4px 0 0;background-color:#0d2136;color:#8fe3f5;border:1px solid #1d4d63;border-radius:5px 5px 0 0}
.bios-tab-active{background-color:#0b7f96;color:#ffffff;border-color:#22d3ee}
#bios-menu{margin:10px 0 0 0;padding:0;border-bottom:2px solid #22d3ee}
#menu-title{display:inline-block;margin:0 10px 0 0;padding:6px 10px;color:#3f7f92;font-size:13px}
#status{display:block;margin:0;padding:6px 10px;background-color:#0a1626;color:#ffd166;border:1px solid #4a3a12;border-radius:0 0 5px 5px}
#hw-nat-status{color:#7fd4e8;font-size:13px;margin:4px 0}
#read-only-note{color:#7fd4e8;font-size:14px;margin:6px 0}
#refresh{display:inline-block;padding:6px 12px;margin:4px 0;background-color:#0d2136;color:#8fe3f5;border:1px solid #1d4d63;border-radius:5px}
section{margin:10px 0;padding:2px 12px 10px 12px;background-color:#08111f;border:1px solid #17394b;border-radius:6px}
table{width:100%;margin:6px 0}
th{text-align:left;padding:5px 10px;background-color:#0a1a28;color:#8fe3f5;border-bottom:1px solid #10263a}
td{text-align:left;padding:5px 10px;color:#c9e9f5;border-bottom:1px solid #10263a}
.col-head{background-color:#0e485c;color:#eaffff;font-weight:bold;border-bottom:1px solid #22d3ee}
pre{white-space:pre-wrap;margin:6px 0;padding:6px 10px;background-color:#050d18;color:#8fe3f5;border:1px solid #17394b;border-radius:4px}
footer{margin:10px 0 0 0;padding:6px 10px;background-color:#0b7f96;color:#eaffff;border-radius:5px}
#bios-hint{margin:0;color:#eaffff;font-size:13px}
[hidden]{display:none!important}

/* Browser-only refinements silently absent from the BIOS raster. */
.bios-tab { text-decoration: none; cursor: pointer; }
.bios-tab:hover { background-color: #12405a; color: #eaffff; }
.bios-tab-active:hover { background-color: #0b7f96; }
#refresh:hover { background-color: #12405a; cursor: pointer; }
#bios-ui[data-fx-active="true"] { background: rgba(5, 10, 24, .78); }
@media (prefers-reduced-motion: reduce) { #bios-ui { scroll-behavior: auto; } }
</style>
