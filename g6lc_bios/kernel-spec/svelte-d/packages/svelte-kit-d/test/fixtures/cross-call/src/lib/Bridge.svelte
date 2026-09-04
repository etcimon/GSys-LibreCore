<script lang="ts" context="module">
  export function readyFlag() {
    return 1
  }
</script>

<script lang="ts">
  import { tag } from './helper'

  export function greet(name: string = 'world'): string {
    return tag('hi ' + name)
  }

  export async function loadUser(id: number = 0): Promise<string> {
    return 'u' + id
  }
</script>

<script lang="d">
  extern(C) export int add(int a, int b = 0) { return a + b; }

  string msg = "";
  void go() { this.update.msg = greet("Ada"); }
  void goDef() { this.update.msg = greet(); }
</script>

<div class="bridge">
  <button type="button" on:click={go}>Go</button>
  <span>{msg}</span>
</div>
