<script lang="ts" context="module">
  /** IDE / tsserver. svelte-d copies this into src-ts/modules/generated and
   *  registers it with libwasm.init via jsExports (see modules/index.ts). */
  export function pageReady(msg: string) {
    console.log('svelte-kit-d pageReady', msg)
  }
  export const jsExports = {
    env: {
      pageReady: (len: number, ptr: number) => {
        void len
        void ptr
        pageReady('from wasm')
      },
    },
  }
</script>

<script lang="d">
  // libwasm IR — printed/kept in svelte-engine-ws/src-d (NodeDef, this.update, moment).
  string title = "Home";
  string status = "svelte-engine — dock updates this via this.update (wasm-eh cell)";

  void show(string name)
  {
    this.update.title = name;
    this.update.status = "Active view: " ~ name ~ " @ " ~ formatNow("HH:mm");
  }
</script>

<section class="container mx-auto p-4 bg-base-100 shadow-sm">
  <h1 class="text-4xl font-bold p-4">{title}</h1>
  <p class="px-4 pb-4 opacity-80">{status}</p>
</section>
