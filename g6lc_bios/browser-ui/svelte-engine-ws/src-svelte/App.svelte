<main id="bios-ui" data-start-menu="main" data-worker-url="WORKER_URL_PLACEHOLDER" data-worker-limit="WORKER_LIMIT_PLACEHOLDER" data-wasm-url="WASM_URL_PLACEHOLDER">
  <header id="bios-header">
    <h1 id="banner">G6LC-BIOS | GSys LibreCore</h1>
    <p id="bios-eyebrow">SYSTEM SETUP</p>
    <p id="profile"></p>
  </header>
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
  <div id="bios-toolbar">
    <button id="refresh" type="button" on:click="{refresh}">Refresh / F10</button>
    <span id="row-navigation-hint">Up/Down: field / Left/Right: tab</span>
  </div>
  <p id="status" role="status" aria-live="polite">UI-BOOT: read-only setup</p>
  <p id="bios-nav" hidden></p>
  <p id="hw-nat-status" role="status"></p>

  <section id="menu-main" data-menu="main" aria-labelledby="main-title">
    <h2 id="main-title">Main</h2>
    <table>
      <tbody id="menu-main-body"></tbody>
    </table>
  </section>
  <section id="menu-cpu" data-menu="cpu" aria-labelledby="cpu-title" hidden>
    <h2 id="cpu-title">CPU</h2>
    <table>
      <tbody id="menu-cpu-body"></tbody>
    </table>
  </section>
  <section id="menu-memory" data-menu="memory" aria-labelledby="memory-title" hidden>
    <h2 id="memory-title">Memory</h2>
    <table>
      <tbody id="menu-memory-body"></tbody>
    </table>
  </section>
  <section id="menu-uncore" data-menu="uncore" aria-labelledby="uncore-title" hidden>
    <h2 id="uncore-title">Uncore</h2>
    <table>
      <tbody id="menu-uncore-body"></tbody>
    </table>
  </section>
  <section id="menu-devices" data-menu="devices" aria-labelledby="devices-title" hidden>
    <h2 id="devices-title">Devices</h2>
    <table>
      <tbody id="menu-devices-body"></tbody>
    </table>
  </section>
  <section id="menu-boot" data-menu="boot" aria-labelledby="boot-title" hidden>
    <h2 id="boot-title">Boot</h2>
    <table>
      <tbody id="menu-boot-body"></tbody>
    </table>
  </section>
  <section id="menu-settings" data-menu="settings" aria-labelledby="settings-title" hidden>
    <h2 id="settings-title">Settings</h2>
    <table>
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
body{font:16px "Inconsolata","Courier New",monospace;background-color:#090f1b;color:#d9e5f4;margin:0;padding:18px}
#bios-ui{max-width:1100px;margin:0 auto}
#bios-header{display:flex;align-items:center;justify-content:space-between;gap:12px;background-color:#122237;padding:12px 16px;border:1px solid #2b415b;border-radius:8px;box-shadow:0px 5px 8px 0px rgba(0,0,0,0.35)}
#bios-eyebrow{font-size:12px;color:#74dbc9;margin:0}
h1#banner{color:#f0f6ff;text-align:left;padding:0;margin:0;font-size:21px;font-weight:bold}
#profile{color:#74dbc9;margin:0;font-size:13px}
h2{color:#eff6ff;margin:0 0 10px 0;font-size:19px}
a{color:#8ee8d6}
button{font:inherit}
.bios-tab{flex:0 0 auto;display:inline-block;padding:7px 12px;margin:0;background-color:#142237;color:#a9bdd4;border:1px solid #2b415b;border-radius:5px}
.bios-tab-active{background-color:#74dbc9;color:#0c222b;border-color:#74dbc9}
#bios-menu{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin:12px 0 0 0;padding:0 0 10px 0}
#menu-title{margin:0;padding:0 8px 0 0;color:#8c9fb7;font-size:12px}
#bios-toolbar{display:flex;align-items:center;gap:16px;margin:0}
#row-navigation-hint{color:#8c9fb7;font-size:13px}
#status{display:block;margin:6px 0;padding:0;color:#8c9fb7;font-size:12px}
#hw-nat-status{color:#a9bdd4;font-size:13px;margin:0}
#refresh{padding:5px 12px;margin:0;background-color:#20334c;color:#eff6ff;border:1px solid #476383;border-radius:5px}
section{margin:8px 0;padding:12px;background-color:#111e30;border:1px solid #2b415b;border-radius:8px;box-shadow:0px 5px 8px 0px rgba(0,0,0,0.25)}
table{width:100%;margin:0}
tbody{display:flex;flex-wrap:wrap;gap:8px}
.bios-field{flex:1 1 46%;min-width:0;padding:4px;background-color:#16263b;border:1px solid #2b415b;border-radius:5px}
.bios-field-active{background-color:#24475b;border-color:#74dbc9}
th{text-align:left;padding:5px 8px;color:#afc7e0}
td{text-align:left;padding:5px 8px;color:#d9e5f4;font-size:14px}
pre{white-space:pre-wrap;margin:6px 0;padding:8px;background-color:#0c1625;color:#a9bdd4;border:1px solid #2b415b;border-radius:5px}
footer{margin:10px 0 0 0;padding:8px 12px;background-color:#122237;color:#a9bdd4;border:1px solid #2b415b;border-radius:5px}
#bios-hint{margin:0;color:#a9bdd4;font-size:12px}
[hidden]{display:none!important}

/* Browser-only refinements silently absent from the BIOS raster. */
.bios-tab { text-decoration: none; cursor: pointer; }
.bios-tab:hover { background-color: #2b415b; color: #ffffff; }
.bios-tab-active:hover { background-color: #8ee8d6; color: #0c222b; }
#refresh:hover { background-color: #36516d; cursor: pointer; }
#bios-ui[data-fx-active="true"] { background: rgba(5, 10, 24, .78); }
@media (prefers-reduced-motion: reduce) { #bios-ui { scroll-behavior: auto; } }
</style>
