<!--
  Example: BIOS browser window with tabs, URL bar, iframe session, close /
  minimize / resize, and a status-bar task that toggles minimize/restore.
  Session controller is the <iframe>; chrome is BIOS UI. Not App.svelte.
  Compile fixture — python tools/g6b.py check.
-->
<script>
  let winOpen = true;
  let minimized = false;
  let url = "/ui/help.html";
</script>

<main id="ex-ui">
  <p id="ex-status" role="status">UI-BOOT  win:browser  tab:1  /ui/help.html  ok</p>
  <button id="ex-task-0" type="button" data-window-action="toggle" on:click="{toggleWindow}">browser</button>
  {#if winOpen}
  <div id="ex-window" class="bios-window" data-kind="browser" data-location="/ui/help.html">
    <div id="ex-titlebar" class="bios-window-titlebar">
      <span id="ex-title">browser</span>
      <button id="ex-min" type="button" data-window-action="minimize" on:click="{minimizeWindow}">_</button>
      <button id="ex-close" type="button" data-window-action="close" on:click="{closeWindow}">Close</button>
    </div>
    {#if !minimized}
    <div id="ex-chrome">
      <div id="ex-tabs" role="tablist" aria-label="Browser tabs">
        <a id="ex-tab-0" class="bios-tab bios-tab-active" href="#ex-frame" data-tab-action="select" data-tab="0" on:click="{selectBrowserTab}">help</a>
        <button id="ex-tab-new" type="button" data-tab-action="new" on:click="{newBrowserTab}">New tab</button>
      </div>
      <form id="ex-urlbar">
        <label id="ex-url-label" for="ex-url">URL</label>
        <input id="ex-url" type="text" value="/ui/help.html">
        <button id="ex-go" type="button" data-frame-action="navigate" on:click="{goUrl}">Go</button>
      </form>
      <iframe id="ex-frame" src="/ui/help.html" width="320" height="180" title="session"></iframe>
      <button id="ex-resize-w" type="button" data-window-action="widen" on:click="{resizeWindow}">Wider</button>
      <button id="ex-resize-h" type="button" data-window-action="taller" on:click="{resizeWindow}">Taller</button>
    </div>
    {/if}
  </div>
  {/if}
</main>

<style>
#ex-window{position:absolute;top:56px;left:24px;width:480px;height:320px;background-color:#0a1626;color:#c9e9f5;border:1px solid #22d3ee}
#ex-titlebar{display:block;height:28px;background-color:#0b7f96;color:#eaffff}
#ex-min{position:absolute;top:4px;right:72px;width:3ch;height:22px}
#ex-close{position:absolute;top:4px;right:8px;width:8ch;height:22px}
#ex-tabs{display:block;height:28px}
#ex-urlbar{display:block;height:28px}
#ex-url{width:240px;height:22px}
#ex-frame{width:320px;height:180px}
#ex-resize-w{position:absolute;right:8px;bottom:8px;width:8ch;height:22px}
#ex-resize-h{position:absolute;right:80px;bottom:8px;width:8ch;height:22px}
#ex-status{display:block}
</style>
