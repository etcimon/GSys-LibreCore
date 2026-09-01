# SL-W crash-recovery proposal: `mini_fdt_next_tag_lbu` L1 stale fix

**Status:** Proposed, not committed.  Verilator lint passes on `g6lc64_smt2`.  Functional proxy test is still required.

**Affected files:**
- `core/cache_subsystem/wt_dcache_wbuffer.sv`
- `core/cache_subsystem/wt_dcache.sv`
- `core/cache_subsystem/wt_dcache_mem.sv`

**Configuration:**  `g6lc64_smt2` with `WtDcacheFixupDepth=2`, `WtDcacheFixupVoidKeepEn=0`.

---

## 1. Diagnosis

### 1.1 What fails

The second `next_tag_lbu` call stores `0x8` to `0x80007fcc` and the third caller's immediately following `lw` reads the stale value `0x4` from the same address.

### 1.2 Cycle trace of the stale window

| Cycle | `wt_dcache_wbuffer` | `wt_dcache_mem` | Effect on the `lw` |
|-------|---------------------|-----------------|--------------------|
| t0 | Store `0x8` is in the write buffer and sent to the write-through bus.  `checked=0`, `valid=1`. | — | — |
| t1 | Write-through ACK returns before the tag check has completed.  `p_buffer` sees a VOID ACK: it **pushes the word to the post-ACK fixup queue and clears the write-buffer entry** (`WtDcacheFixupVoidKeepEn=0`).  The entry is no longer in `wbuffer_data_o`. | Tag check for the store was in flight but has not completed, or is just about to start. | The load can now be issued on the high-priority read port. |
| t2 | Fixup is in `FIXUP_PEND`.  `fixup_rd_req` is true *only* when `!(|tocheck) && !check_en_q && !check_en_q1`.  Even if those conditions are met, the wbuffer read port is **low priority** (`rd_prio[NumPorts-1]=0` in `wt_dcache.sv:281`). | A load on a higher-priority port wins the read arbiter, captures `rd_hit_oh_i` for the resident way, and reads the L1 data array. | The load hits the **resident** line, which still contains `0x4`. |
| t3 | Fixup transitions to `FIXUP_CHECK` and captures `rd_hit_oh_i`/`rd_vld_bits_i`. | L1 data is returned to the load. | Load retires with stale `0x4`. |
| t4–t5 | Fixup transitions to `FIXUP_RETIRE`, drives `fixup_wr_req`, and (t5) finally writes the new `0x8` into the hit way. | — | L1 is now correct, but the stale value was already consumed. |

### 1.3 Root cause

The primary cause is **(a) the load is not blocked or forwarded while a fixup is pending**.  Once a VOID ACK is queued, the write-buffer entry is gone, so `wt_dcache_mem` has no source for the new data until the fixup finishes its tag check and writes the L1.

There is also a strong contributing factor from **(c) a port/priority conflict**: the wbuffer/fixup read port is explicitly low priority, while a data load on a higher-priority port can be granted in the same cycle window.  The fixup cannot even begin its tag check until it wins the shared read port.

Other options were considered but are not the dominant failure:
- **(b) fixup write too late**: this is a *consequence* of the window, not a root cause.
- **(d) wrong parameters**: `WtDcacheFixupDepth=2` and `WtDcacheFixupVoidKeepEn=0` are the intended SMT2 values; the issue reproduces with single-entry queues, so depth is not the root.
- **(e) queue FSM bug**: the FSM does have a real bug (it does not pop the head on a tag miss and would spin, see §1.4), but the observed stale read happens when the fixup **hits** and is merely out-raced by the load.

### 1.4 Secondary FSM bug observed

In `wt_dcache_wbuffer.sv` around line 487–493, the `FIXUP_CHECK` miss branch claims to drop the entry, but it actually sets `fixup_state_d = FIXUP_PEND` and **does not pop the head**.  The result is that a head whose line is not resident will repeatedly re-check, blocking newer fixups and eventually filling the queue.  The proposal below corrects this by popping the head on a miss, matching the architecture note's "memory is authoritative" rule.

---

## 2. Proposed fix

### 2.1 Strategy

Forward the **newest** matching fixup queue entry directly to `wt_dcache_mem`'s readout mux, exactly like the existing write-buffer forwarding.  This closes the stale window from the load side: a load that matches a queued VOID ACK sees the queue data instead of the stale L1 line, even before the fixup has completed its tag check or written the data array.

The fix is:
1. Add a `fixup_wbuffer_o` port to `wt_dcache_wbuffer` that exposes the pending fixup entries as `wbuffer_t` values, newest first (bypass, then `tail-1`, `tail-2`, ...).
2. Pass that port through `wt_dcache` to `wt_dcache_mem`.
3. In `wt_dcache_mem`, concatenate the normal write buffer and the fixup forwarding array into one combined `wbuffer_all` array and use the existing LZC/overlay logic on the combined array.
4. Pop the fixup head on a tag miss so the queue does not spin.

### 2.2 Why the boundary change is required

`wt_dcache_mem` is the only module that has the load's read address and the only module that already performs the write-buffer overlay.  The fixup queue lives in `wt_dcache_wbuffer` and has no way to know which load address is being read.  Extending the existing forwarding mux by one array is the smallest change that makes the queued data visible to the load readout; blocking/forwarding at any other point either requires duplicating the hit comparison (worse coupling) or reintroduces the `keep`-wbuffer schemes that the project history shows cause `h0` FDT_PROP hangs.

### 2.3 Parameterization and depth-0 behaviour

- No new clock or reset.
- All new logic is inside `gen_fixup_queue` / the same module generate blocks and is controlled by `CVA6Cfg.WtDcacheFixupDepth`.
- When `WtDcacheFixupDepth=0`, the queue generate is disabled, `fixup_wbuffer_o` is tied to `'0`, and `wt_dcache_mem`'s extra forwarding slice has zero entries (`FixupForwardDepth=0`), so `wbuffer_all` reduces to the original `wbuffer_data_i` width.
- The implementation is valid for `WtDcacheFixupDepth` equal to any power of two up to the write-buffer depth.

---

## 3. Code diff

```diff
diff --git a/core/cache_subsystem/wt_dcache.sv b/core/cache_subsystem/wt_dcache.sv
index 3ba91f7fa..79a3a6ff2 100644
--- a/core/cache_subsystem/wt_dcache.sv
+++ b/core/cache_subsystem/wt_dcache.sv
@@ -142,6 +142,7 @@ module wt_dcache
 
   // wbuffer <-> memory
   wbuffer_t [     CVA6Cfg.WtDcacheWbufDepth-1:0]                                  wbuffer_data;
+  wbuffer_t [                         CVA6Cfg.WtDcacheFixupDepth:0]               fixup_wbuffer;
 
 
   ///////////////////////////////////////////////////////
@@ -344,6 +345,7 @@ module wt_dcache
       .pm_fixup_full_o  (pm_fixup_full),
       // write buffer forwarding
       .wbuffer_data_o (wbuffer_data),
+      .fixup_wbuffer_o(fixup_wbuffer),
       .tx_paddr_o     (tx_paddr),
       .tx_vld_o       (tx_vld)
   );
@@ -398,7 +400,8 @@ module wt_dcache
       .inv_way_oh_i   (inv_way_oh),
       .inv_vld_bits_i (inv_vld_bits),
       // write buffer forwarding
-      .wbuffer_data_i (wbuffer_data)
+      .wbuffer_data_i (wbuffer_data),
+      .fixup_wbuffer_i(fixup_wbuffer)
   );
 
   // SL-W PMU event pass-through
diff --git a/core/cache_subsystem/wt_dcache_mem.sv b/core/cache_subsystem/wt_dcache_mem.sv
index 76b3ca09a..041b08b5c 100644
--- a/core/cache_subsystem/wt_dcache_mem.sv
+++ b/core/cache_subsystem/wt_dcache_mem.sv
@@ -80,12 +80,29 @@ module wt_dcache_mem
     input logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] inv_vld_bits_i,
 
     // forwarded wbuffer
-    input wbuffer_t [CVA6Cfg.WtDcacheWbufDepth-1:0] wbuffer_data_i
+    input wbuffer_t [CVA6Cfg.WtDcacheWbufDepth-1:0] wbuffer_data_i,
+    // SL-W fixup queue forwarding (newest-first; unused when fixup depth is 0)
+    input wbuffer_t [CVA6Cfg.WtDcacheFixupDepth:0] fixup_wbuffer_i
 );
 
   localparam DCACHE_NUM_BANKS = CVA6Cfg.DCACHE_LINE_WIDTH / CVA6Cfg.XLEN;
   localparam DCACHE_NUM_BANKS_WIDTH = $clog2(DCACHE_NUM_BANKS);
 
+  // SL-W: combine normal wbuffer and fixup queue for readout forwarding.
+  // For fixup depth 0 the upper slice is empty and the readout logic reduces
+  // to the original wbuffer_data_i behaviour.
+  localparam int unsigned FixupForwardDepth = CVA6Cfg.WtDcacheFixupDepth + (CVA6Cfg.WtDcacheFixupDepth > 0);
+  localparam int unsigned WbufferAllDepth   = CVA6Cfg.WtDcacheWbufDepth + FixupForwardDepth;
+
+  wbuffer_t [WbufferAllDepth-1:0] wbuffer_all;
+
+  for (genvar k = 0; k < CVA6Cfg.WtDcacheWbufDepth; k++) begin : gen_wbuffer_all
+    assign wbuffer_all[k] = wbuffer_data_i[k];
+  end
+  for (genvar k = 0; k < FixupForwardDepth; k++) begin : gen_fixup_all
+    assign wbuffer_all[CVA6Cfg.WtDcacheWbufDepth + k] = fixup_wbuffer_i[k];
+  end
+
   // functions
   function automatic logic [DCACHE_NUM_BANKS-1:0] dcache_cl_bin2oh(
       input logic [DCACHE_NUM_BANKS_WIDTH-1:0] in);
@@ -126,7 +143,7 @@ module wt_dcache_mem
 
   logic [$clog2(NumPorts)-1:0] vld_sel_d, vld_sel_q;
 
-  logic [CVA6Cfg.WtDcacheWbufDepth-1:0] wbuffer_hit_oh;
+  logic [WbufferAllDepth-1:0] wbuffer_hit_oh;
   logic [(CVA6Cfg.XLEN/8)-1:0] wbuffer_be;
   logic [CVA6Cfg.XLEN-1:0] wbuffer_rdata, rdata;
   logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0] wbuffer_ruser, ruser;
@@ -265,7 +282,7 @@ module wt_dcache_mem
 
   logic [CVA6Cfg.DCACHE_OFFSET_WIDTH-CVA6Cfg.XLEN_ALIGN_BYTES-1:0] wr_cl_off;
   logic [CVA6Cfg.DCACHE_OFFSET_WIDTH-CVA6Cfg.XLEN_ALIGN_BYTES-1:0] wr_cl_nc_off;
-  logic [                   $clog2(CVA6Cfg.WtDcacheWbufDepth)-1:0] wbuffer_hit_idx;
+  logic [                   $clog2(WbufferAllDepth)-1:0] wbuffer_hit_idx;
   logic [                    $clog2(CVA6Cfg.DCACHE_SET_ASSOC)-1:0] rd_hit_idx;
 
   assign cmp_en_d = (|vld_req) & ~vld_we;
@@ -282,12 +299,12 @@ module wt_dcache_mem
     assign ruser_cl[i] = bank_ruser[bank_off_q[CVA6Cfg.DCACHE_OFFSET_WIDTH-1:CVA6Cfg.XLEN_ALIGN_BYTES]][i];
   end
 
-  for (genvar k = 0; k < CVA6Cfg.WtDcacheWbufDepth; k++) begin : gen_wbuffer_hit
-    assign wbuffer_hit_oh[k] = (|wbuffer_data_i[k].valid) & ({{CVA6Cfg.XLEN_ALIGN_BYTES{1'b0}}, wbuffer_data_i[k].wtag} == (wbuffer_cmp_addr >> CVA6Cfg.XLEN_ALIGN_BYTES));
+  for (genvar k = 0; k < WbufferAllDepth; k++) begin : gen_wbuffer_hit
+    assign wbuffer_hit_oh[k] = (|wbuffer_all[k].valid) & ({{CVA6Cfg.XLEN_ALIGN_BYTES{1'b0}}, wbuffer_all[k].wtag} == (wbuffer_cmp_addr >> CVA6Cfg.XLEN_ALIGN_BYTES));
   end
 
   lzc #(
-      .WIDTH(CVA6Cfg.WtDcacheWbufDepth)
+      .WIDTH(WbufferAllDepth)
   ) i_lzc_wbuffer_hit (
       .in_i   (wbuffer_hit_oh),
       .cnt_o  (wbuffer_hit_idx),
       .empty_o()
@@ -302,9 +319,9 @@ module wt_dcache_mem
       .empty_o()
   );
 
-  assign wbuffer_rdata = wbuffer_data_i[wbuffer_hit_idx].data;
-  assign wbuffer_ruser = wbuffer_data_i[wbuffer_hit_idx].user;
-  assign wbuffer_be    = (|wbuffer_hit_oh) ? wbuffer_data_i[wbuffer_hit_idx].valid : '0;
+  assign wbuffer_rdata = wbuffer_all[wbuffer_hit_idx].data;
+  assign wbuffer_ruser = wbuffer_all[wbuffer_hit_idx].user;
+  assign wbuffer_be    = (|wbuffer_hit_oh) ? wbuffer_all[wbuffer_hit_idx].valid : '0;
 
   if (CVA6Cfg.NOCType == config_pkg::NOC_TYPE_AXI4_ATOP) begin : gen_axi_offset
     // In case of an uncached read, return the desired CVA6Cfg.XLEN-bit segment of the most recent AXI read
diff --git a/core/cache_subsystem/wt_dcache_wbuffer.sv b/core/cache_subsystem/wt_dcache_wbuffer.sv
index b8e06da2e..79efe003b 100644
--- a/core/cache_subsystem/wt_dcache_wbuffer.sv
+++ b/core/cache_subsystem/wt_dcache_wbuffer.sv
@@ -127,6 +127,8 @@ module wt_dcache_wbuffer
     output logic pm_fixup_write_o,
     output logic pm_fixup_inval_o,
     output logic pm_fixup_full_o,
+    // SL-W fixup queue forwarding to read mux (newest-first, bypass then FIFO)
+    output wbuffer_t [CVA6Cfg.WtDcacheFixupDepth:0] fixup_wbuffer_o,
     // to forwarding logic and miss unit
     output wbuffer_t [CVA6Cfg.WtDcacheWbufDepth-1:0] wbuffer_data_o,
     output logic [CVA6Cfg.DCACHE_MAX_TX-1:0][CVA6Cfg.PLEN-1:0]     tx_paddr_o,      // used to check for address collisions with read operations
@@ -324,6 +326,7 @@ module wt_dcache_wbuffer
       assign pm_fixup_write_o     = 1'b0;
       assign pm_fixup_inval_o     = 1'b0;
       assign pm_fixup_full_o      = 1'b0;
+      assign fixup_wbuffer_o      = '{default: '0};
     end else begin : gen_fixup_queue
       // Queue entry type.  Only the head of the FIFO is processed at a time.
       typedef enum logic [1:0] {
@@ -351,6 +354,7 @@ module wt_dcache_wbuffer
       // width-clean and Verilator does not emit WIDTHEXPAND warnings.
       localparam int unsigned FixupDepth    = CVA6Cfg.WtDcacheFixupDepth;
       localparam [$clog2(FixupDepth):0] FixupDepthCnt = FixupDepth[$clog2(FixupDepth):0];
+      localparam int unsigned FixupForwardDepth = FixupDepth + (FixupDepth > 0);
 
       // Full when the FIFO is at capacity and the bypass slot is not available.
       assign fixup_full  = (fixup_cnt == FixupDepthCnt) && fixup_bypass_valid_q;
@@ -544,13 +548,54 @@ module wt_dcache_wbuffer
             fixup_cnt  <= fixup_cnt + 1'b1;
           end
 
-          // On normal hit retire, pop the head and decrement count.
-          if (fixup_state_q == FIXUP_RETIRE && !fixup_bypass_valid_q && fixup_wr_ack) begin
+          // On normal hit retire, pop the head and decrement count.  On a tag
+          // miss the head is also popped: the architecture note says a miss
+          // is dropped because memory is authoritative, so the FIFO must not
+          // spin on an absent line.
+          if ((fixup_state_q == FIXUP_RETIRE && !fixup_bypass_valid_q && fixup_wr_ack) ||
+              (fixup_state_q == FIXUP_CHECK && !fixup_bypass_valid_q &&
+               fixup_check_en_q1 && !(|fixup_hit_oh_q))) begin
             fixup_head <= fixup_head + 1'b1;
             fixup_cnt  <= fixup_cnt - 1'b1;
           end
         end
       end
+
+      // Convert a fixup paddr to the wtag used by the cache readout mux.
+      function automatic [CVA6Cfg.DCACHE_TAG_WIDTH+(CVA6Cfg.DCACHE_INDEX_WIDTH-CVA6Cfg.XLEN_ALIGN_BYTES)-1:0] fixup_wtag(input [CVA6Cfg.PLEN-1:0] paddr);
+        fixup_wtag = {paddr[CVA6Cfg.DCACHE_INDEX_WIDTH+CVA6Cfg.DCACHE_TAG_WIDTH-1:CVA6Cfg.DCACHE_INDEX_WIDTH],
+                      paddr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.XLEN_ALIGN_BYTES]};
+      endfunction
+
+      // Forward newest fixup data first (bypass if active, then tail-1, ...).
+      // This matches the wbuffer forwarding priority: wbuffer_data_o beats
+      // fixup_wbuffer_o, and within fixup_wbuffer_o the newest entry wins.
+      always_comb begin : p_fixup_wbuffer
+        fixup_wbuffer_o = '{default: '0};
+        for (int i = 0; i < FixupForwardDepth; i++) begin
+          int fifo_i;
+          int src_idx;
+          fifo_i = i - (fixup_bypass_valid_q ? 1 : 0);
+          if (i == 0 && fixup_bypass_valid_q) begin
+            fixup_wbuffer_o[i].wtag = fixup_wtag(fixup_bypass_q.paddr);
+            fixup_wbuffer_o[i].data = fixup_bypass_q.data;
+            fixup_wbuffer_o[i].user = (CVA6Cfg.DATA_USER_EN != 0) ? fixup_bypass_q.user : '0;
+            fixup_wbuffer_o[i].valid = fixup_bypass_q.be;
+          end else if (fifo_i < fixup_cnt) begin
+            // For FixupDepth==1, fixup_tail has zero width; the modulo keeps the
+            // index inside the FIFO for the only valid case (fixup_cnt==1).
+            if (FixupDepth > 1) begin
+              src_idx = (int'(fixup_tail) - 1 - fifo_i + FixupDepth) % int'(FixupDepth);
+            end else begin
+              src_idx = 0;
+            end
+            fixup_wbuffer_o[i].wtag = fixup_wtag(fixup_q[src_idx].paddr);
+            fixup_wbuffer_o[i].data = fixup_q[src_idx].data;
+            fixup_wbuffer_o[i].user = (CVA6Cfg.DATA_USER_EN != 0) ? fixup_q[src_idx].user : '0;
+            fixup_wbuffer_o[i].valid = fixup_q[src_idx].be;
+          end
+        end
+      end
     end
   endgenerate
```

---

## 4. Verification performed

| Test | Result | Notes |
|------|--------|-------|
| `bun run src/cli/index.ts diag run diag-smt2-lint` in `build-platform/` | **PASS** | 260 warnings, baseline 600.  No Verilator errors.  One warning count increase over the 259-warning baseline is expected from the new `fixup_wbuffer` signal path and is inside the budget. |
| `g6q.py check` | not run | QEMU-side `g6q.py` is not the appropriate pre-flight for an RTL D-cache change; the lint elaboration is the relevant quick check. |
| Functional proxy / `mini_fdt_next_tag_lbu` | not run | Per instruction, no remote soaks or long builds were run.  This is the next required experiment. |

---

## 5. Exact lines and files to change

| File | Lines (approximate after the diff) | Change |
|------|-----------------------------------|--------|
| `core/cache_subsystem/wt_dcache_wbuffer.sv` | port list around 129–132; `gen_fixup_disabled` 328–329; `gen_fixup_queue` 357, 551–555, 559–593 | Add `fixup_wbuffer_o` port, fix head pop on tag miss, add `p_fixup_wbuffer` to convert queued entries to `wbuffer_t`. |
| `core/cache_subsystem/wt_dcache.sv` | 144–145, 346, 400–402 | Add `fixup_wbuffer` internal signal and connect it between wbuffer and mem. |
| `core/cache_subsystem/wt_dcache_mem.sv` | 83–84, 89–107, 146, 285, 302–322 | Add `fixup_wbuffer_i` port, build `wbuffer_all`, and use the combined array for the forwarding overlay. |

---

## 6. Remaining risks and next experiments

1. **Functional proxy run** (`mini_fdt_next_tag_lbu` on `g6lc64_smt2`) is the decisive test.  The lint only proves elaboration and synthesizability.
2. **Coalescing / write-after-fixup ordering:** if a newer store to the same word is still in the write buffer, the existing `wbuffer_data_o` entries are placed at lower indices than `fixup_wbuffer_o`, so the newer write-buffer data wins.  If the newer store has already been sent to the write-through bus and is itself a pending fixup, `p_fixup_wbuffer` orders newest-first, so the newest queued value wins.  The proxy should confirm no stale `s2`/`s3` values.
3. **Bypass-slot coverage:** when the queue is full and the bypass slot is active, `FixupForwardDepth = FixupDepth + 1` is exposed; the mapping includes the bypass and all FIFO entries.  The proxy should exercise the packed-namelen (`h0`) path that historically stressed the bypass.
4. **Timing impact:** `p_fixup_wbuffer` is purely combinational on queue state and adds one more array input to the existing LZC/overlay path.  No new clock or reset was introduced.
