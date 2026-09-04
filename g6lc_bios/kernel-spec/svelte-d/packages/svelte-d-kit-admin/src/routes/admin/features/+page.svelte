<script lang="ts" context="module">
  export function adminFeaturesReady() {
    return true
  }
</script>

<script lang="d">
  bool show = true;
  bool hide = false;
</script>

<div class="admin-features">
  <svelte:head>
    <title>Features</title>
  </svelte:head>
  {#if show && !hide}
    <ClickField />
    <Panel title="Features" />
    <ComboMore />
    <ComboForm />
    <ComboCss />
    <ComboExpr />
    <ComboNest />
    <ComboCover />
    <ComboSurf />
    <AdminBridge />
    <AdminPeer />
  {/if}
  {#each items as item}
    <li class:on>{item}</li>
  {/each}
  <form method="POST">
    <input name="probe" />
    <button type="submit">Run</button>
  </form>
  {#await job}
    <p>Wait</p>
  {:then v}
    <p>Done</p>
  {/await}
</div>
