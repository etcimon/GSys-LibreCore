<script lang="ts" context="module">
  export function accountReady() {
    return true
  }
</script>

<script lang="d">
  import kit.app_environment;
  import kit.app_paths;
  import kit.env_static_public;
  bool show = true;
  string who = PUBLIC_APP_NAME;
</script>

<div class="account">
  <svelte:head>
    <title>Account</title>
  </svelte:head>
  {#if show}
    <Panel title={who} />
  {/if}
  <p>{who}</p>
</div>
