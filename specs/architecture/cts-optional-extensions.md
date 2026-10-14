# Optional-extension groups — `conditional-rendering`, `cooperative-vector`, `data-graph`, `dgc`, `image-processing`, `tensor`, `video` (79,990 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass lists `vk-default/{conditional-rendering,
cooperative-vector,data-graph,dgc,image-processing,tensor,video}.txt`. One file because
every one of them is **NotSupported by truthful absence** on this device until a decision
adds the extension; the cards record what adding it would mean so the decision is an
architecture decision, not a profile edit. Per-group files are split out when a group is
adopted.

## Inventory

| group | cases | extension(s) | this product |
|---|---:|---|---|
| `conditional_rendering` | 1030 (`draw` 384, `dispatch` 280, `conditional_ignore` 158, `draw_clear` 139, `clear_attachments` 60) | VK_EXT_conditional_rendering | **adopt in W8** — Zink GL 3.0 requires it; UE uses it for occlusion-driven culling |
| `cooperative_vector` | 53562 (`matmul` 25282, `training` 15008, `basic`/`longvec` 6554 each, `layoutconvert` 144, `typeconvert` 20) | VK_NV_cooperative_vector | not planned (NV-only; the matrix feature is KHR_cooperative_matrix in cts-compute.md) |
| `data_graph` | 10176 | VK_ARM_data_graph | not planned |
| `dgc` | 4473 (`ext.graphics` 3744, `ext.compute` 469, `nv.*` 238) | VK_EXT_device_generated_commands (+NV) | **adopt in W8** — the requested "GPU-generated command buffers" feature (plan W8.3) |
| `image_processing` | 611 | VK_QCOM_image_processing | not planned |
| `tensor` | 844 | VK_ARM_tensors | not planned |
| `video` | 9301 | VK_KHR_video_queue / decode / encode | not planned (built with DEQP_DISABLE_VK_VIDEO_TESTS=ON → NotSupported) |

## Architectural logic (for the two adopted groups)

```text
LOGIC COND-L1 · Conditional rendering
  CLAIM       vkCmdBeginConditionalRenderingEXT(buffer, offset, flags) makes subsequent
              draws, dispatches, clears (ClearAttachments) and indirect commands
              execute only if the 32-bit value at buffer+offset is nonzero (inverted
              flag negates), until vkCmdEndConditionalRenderingEXT; the predicate is
              read at execution time (a prior GPU write counts); secondary command
              buffers inherit the predicate when conditionalRenderingEnable is set.
  SOURCE      conditional_rendering.{draw,dispatch,draw_clear,clear_attachments,
              conditional_ignore}.*.
  MECHANISM   cmdexec: a predicate state {valid, inverted, value fetched at Begin} that
              gates the issue of draw/dispatch/clear records (skipped records still
              advance the completion accounting); the fetch is the same operand path as
              indirect arguments (COMPUTE-L2) and must respect ordering with producers.
  REQUIRES    Which commands are affected is exactly the spec list (copies and queries
              are NOT skipped — conditional_ignore tests this).
  FORBIDS     Evaluating the predicate at record time; skipping non-listed commands.
  CHECK       conditional_rendering.draw.*, dispatch.*, conditional_ignore.* (W8).
  COST        one read per Begin; a gate in the issue path.
  FEEDS       Zink GL 3.0; UE; W8.
  STATUS      not-run (NotSupported)

LOGIC DGC-L1 · Device-generated commands (EXT)
  CLAIM       Indirect command layouts (tokens: push constants, vertex/index buffer
              binding, draw/dispatch/draw-indexed/indirect-count, execution set
              selection of pipelines/shader objects) are executed by
              vkCmdExecuteGeneratedCommandsEXT from a GPU-written stream with preprocess
              buffers and sequence counts.
  SOURCE      dgc.ext.{graphics,compute}.*.
  MECHANISM   cmdexec token interpreter over device memory: a bounded set of token
              kinds, each equivalent to an existing record (bind, push, draw, dispatch)
              but sourced from memory at execution; execution sets select among
              pre-created pipelines (ObjTab handles in a table); preprocessing may be a
              no-op (sizes reported accordingly).
  REQUIRES    W8 bindless/GPU-driven foundations (BDA for the stream addresses, W5 VA).
  FORBIDS     Any host round trip to generate the commands (the stock-visible API is
              device-side by definition).
  CHECK       dgc.ext.compute.* first, then graphics (W8/CTS-4).
  COST        a second record decoder reading memory; token table size.
  FEEDS       plan W8.3 (GPU-generated commands); CTS-4.
  STATUS      not-run (NotSupported)
```

## Exceptions

```text
EXCEPTION OPT-X1 · Not advertised, not implemented
  CONDITION   Any test in these seven groups today.
  RESULT      NotSupported.
  TRUTH       No `[extensions]` entry; video tests are additionally compiled out.
  MECHANISM   Profile ROM / build option.
  CHECK       ledger (these groups should show 100 % not-supported, 0 fail — a Fail here
              means a test ran that should not have, i.e. an advertisement bug).
  FORBIDS     Adopting an extension by advertising it before its cards above are green.
```

## Performance / area / scalability

Conditional rendering is free. DGC is a scheduling/decoder feature whose cost is the
memory-sourced token path; it belongs with the W8 GPU-driven measurement.
