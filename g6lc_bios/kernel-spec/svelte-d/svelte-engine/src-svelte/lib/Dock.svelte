<script lang="ts" context="module">
  /** IDE-visible TS. Attached as jsExports in src-ts/modules/generated. */
  export function dockNavigate(name: string) {
    console.log('dock', name)
  }
</script>

<script lang="d">
  mixin Slot!("navigate", string);

  void onHome() { this.emit(navigate, "Home"); }
  void onInbox() { this.emit(navigate, "Inbox"); }
  void onSettings() { this.emit(navigate, "Settings"); }
</script>

<div class="dock dock-xl">
  <button class="dock-active" on:click={onHome}>Home</button>
  <button on:click={onInbox}>Inbox</button>
  <button on:click={onSettings}>Settings</button>
</div>
