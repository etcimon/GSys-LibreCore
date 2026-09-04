<script lang="ts" context="module">
  export function inboxReady() {
    return true
  }
</script>

<script lang="d">
  bool show = true;
</script>

<div class="inbox">
  <svelte:head>
    <title>Inbox</title>
  </svelte:head>
  <form method="POST">
    <input name="title" />
    <button type="submit">Send</button>
  </form>
  {#if show}
    <ClickField />
  {/if}
</div>
