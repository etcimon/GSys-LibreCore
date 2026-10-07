# 3d-b: stock Mesa Venus command stream against `g6lc_apu_sys` (2026-10-07)

Ordered Venus command types sent by stock `vulkaninfo --summary` and by the stock-API
`vkcompute` (`bufcopy.spv` dispatch) during the 3d-b stock-software proof, captured and
reconstructed from the RTL bridge trace (`/tmp/g6lc-apu-bridge/server-run-venus-bind2.log`,
`G6LC_APU_DEBUG=1`). This is the planning input for UE/CS2 workload scope.

## Method

* `G6LC_APU_DEBUG=1` on the bridge server logs every `DMA_RD` (device reads guest CS words)
  and `DMA_WR` (device writes replies) with address + word payload.
* Each Venus instance allocates a fresh ring blob at aperture offset 0 (first-fit), so both
  guest tools wrote command records at the same guest offsets `0x8200_00C0..`. Two read
  epochs are separable: the **first-read value per offset** is vulkaninfo's record, the
  **last-read value** is vkcompute's. Where one epoch never re-wrote an offset, both maps
  agree — so epoch boundaries appear as short garbled regions, not data loss.
* Streams are decoded with the same generated model the TBs use
  (`tools/vn_golden.py` `Sim`/`ReplySim` over `vn_command_set.txt` + `vn_device_profile.toml`);
  `rec['words']` is the consumed record length, record `flags[0]` = `GENERATE_REPLY`.
  Decode scripts: `/tmp/g6lc-apu-bridge/decode_epochs.py`, `decode_full.py`; raw dumps:
  `/tmp/g6lc-apu-bridge/cmd-trace-vulkaninfo.txt`, `cmd-trace-vkcompute.txt`.
* Reply pairing note: reply records are only emitted for records carrying
  `GENERATE_REPLY`; Mesa sends object-creates, binds, command-buffer ops and
  `vkQueueSubmit`/`vkWaitForFences` async (completion via ring seqno + fence), so
  `async (no reply flag)` is the protocol-correct state, not a missing response. Verified
  reply records in the write window show `result = 0` (`VK_SUCCESS`) for
  `vkEnumeratePhysicalDevices`, `vkGetPhysicalDeviceProperties`, and
  `vkGetPhysicalDeviceFormatProperties2` (the latter with zeroed format-property payloads
  where the format is unsupported — truthful zero-feature answers). The end-to-end
  `G6LC_VKCOMPUTE_PASS` is the authoritative per-command evidence: any wrong result in the
  chain would surface as a device error before the fence signaled.

## vkcompute session (last-read epoch, complete)

1424 words consumed; 60+ records, ends at `vkWaitForFences` — matching the successful
run (`out[0..7]` bit-exact vs `spirv_model.py`, `G6LC_VKCOMPUTE_PASS words=32`).

| CS off | Command | Words | Result |
|---|---|---|---|
| 0x0000 | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x0024 | `vkEnumerateInstanceVersion` | 4 | result=0 |
| 0x0034 | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x005c | `vkDestroyInstance` | 6 | (prior-epoch record) |
| 0x0078–0x00d4 | *(epoch boundary — `vkCreateInstance` record bytes incl. app name "g6lc")* | ~24 | — |
| 0x00d8 | `vkDestroyInstance` ×2 | 6+6 | async |
| 0x010c | `vkEnumeratePhysicalDevices` | 9 | result=0 |
| 0x0130 | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x0154 | `vkEnumeratePhysicalDevices` | 11 | result=0 |
| 0x0180 | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x01a4 | `vkGetPhysicalDeviceProperties` | 6 | reply |
| 0x01bc | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x01e0 | `vkEnumerateDeviceExtensionProperties` | 11 | result=0 (count: KHR_external_memory_fd v1) |
| 0x020c | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x0230 | `vkEnumerateDeviceExtensionProperties` | 11 | result=0 |
| 0x025c | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x0280 | `vkGetPhysicalDeviceFeatures2` | 27 | reply |
| 0x02ec | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x0310 | `vkGetPhysicalDeviceProperties2` | 30 | reply |
| 0x0388 | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x03ac | `vkGetPhysicalDeviceQueueFamilyProperties2` | 9 | reply (count) |
| 0x03d0 | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x03f4 | `vkGetPhysicalDeviceQueueFamilyProperties2` | 12 | reply (props) |
| 0x0424 | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x0448 | `vkGetPhysicalDeviceMemoryProperties2` | 13 | reply |
| 0x047c | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x04a0 | `vkEnumeratePhysicalDeviceGroups` | 9 | reply (count) |
| 0x04c4 | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x04e8 | `vkEnumeratePhysicalDeviceGroups` | 78 | result=0 |
| 0x0620 | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x0644 | `vkCreateDevice` | 36 | result=0 |
| 0x06d4 | `vkCreateCommandPool` | 17 | async |
| 0x0718 | `vkGetDeviceQueue2` | 20 | async |
| 0x0768 | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x078c | `vkCreateBuffer` | 23 | result=0 |
| 0x07e8 | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x080c | `vkGetBufferMemoryRequirements2` | 19 | reply |
| 0x0858 | `vkAllocateMemory` | 18 | async |
| 0x08a0 | `vkBindBufferMemory2` | 16 | async |
| 0x08e0 | `vkCreateBuffer` | 23 | async |
| 0x093c | `vkAllocateMemory` | 18 | async |
| 0x0984 | `vkBindBufferMemory2` | 16 | async |
| 0x09c4 | `vkCreateDescriptorSetLayout` | 31 | async |
| 0x0a40 | `vkCreateDescriptorPool` | 22 | async |
| 0x0a98 | `vkAllocateDescriptorSets` | 20 | async |
| 0x0ae8 | `vkUpdateDescriptorSets` | 52 | async |
| 0x0bb8 | `vkCreatePipelineLayout` | 24 | async |
| 0x0c18 | `vkCreateShaderModule` | 276 | async (bufcopy.spv payload) |
| 0x1068 | `vkCreateComputePipelines` | 37 | async |
| 0x10fc | `vkCreateCommandPool` | 17 | async |
| 0x1140 | `vkAllocateCommandBuffers` | 17 | async |
| 0x1184 | `vkBeginCommandBuffer` | 12 | async |
| 0x11b4 | `vkCmdBindPipeline` | 7 | async |
| 0x11d0 | `vkCmdBindDescriptorSets` | 16 | async |
| 0x1210 | `vkCmdDispatch` | 7 | async |
| 0x122c | `vkEndCommandBuffer` | 4 | async |
| 0x123c | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x1260 | `vkCreateBuffer` | 23 | result=0 (feedback buffer) |
| 0x12bc | `vkSetReplyCommandStreamMESA` | 9 | async |
| 0x12e0 | `vkGetBufferMemoryRequirements2` | 19 | reply |
| 0x132c | `vkAllocateMemory` | 18 | async |
| 0x1374 | `vkBindBufferMemory2` | 16 | async |
| 0x13b4 | `vkAllocateCommandBuffers` | 17 | async |
| 0x13f8 | `vkBeginCommandBuffer` | 12 | async |
| 0x1428 | `vkCmdPipelineBarrier` | 34 | async |
| 0x14b0 | `vkCmdFillBuffer` | 11 | async |
| 0x14dc | `vkCmdPipelineBarrier` | 29 | async |
| 0x1550 | `vkEndCommandBuffer` | 4 | async |
| 0x1560 | `vkCreateFence` | 16 | async |
| 0x15a0 | `vkQueueSubmit` | 27 | async |
| 0x160c | `vkWaitForFences` | 12 | async (fence signaled via ring seqno; host readback PASS) |

## vulkaninfo --summary session (first-read epoch)

Same shape at the head (instance bring-up identical), then the characteristic
vulkaninfo probing loop — decoded records (epoch-overlap garbles omitted):

`vkSetReplyCommandStreamMESA` → `vkEnumerateInstanceVersion` → `vkCreateInstance` →
`vkEnumeratePhysicalDevices` ×2 → `vkGetPhysicalDeviceProperties` →
`vkEnumerateDeviceExtensionProperties` ×2 → `vkGetPhysicalDeviceFeatures2` →
`vkGetPhysicalDeviceProperties2` → `vkGetPhysicalDeviceQueueFamilyProperties2` ×2 →
`vkGetPhysicalDeviceMemoryProperties2` → `vkEnumeratePhysicalDeviceGroups` ×2 →
**`vkCreateDevice` (91 words — vulkaninfo passes a full pNext feature chain, accepted)** →
`vkGetPhysicalDeviceFeatures` → then a per-format probing loop (~20 iterations):
`vkGetPhysicalDeviceFormatProperties2` / `vkGetPhysicalDeviceImageFormatProperties2` /
`vkCreateImage` → `vkGetImageMemoryRequirements2` → `vkDestroyImage`; verified replies
`result=0` with zeroed property bodies on unsupported formats (truthful) and
`0xFFFF_FFF5 = VK_ERROR_FORMAT_NOT_SUPPORTED` where queried → teardown:
`vkDestroyCommandPool` → `vkDestroyDevice` → `vkDestroyInstance`.

Notable: `vkCreateImage`/`vkGetImageMemoryRequirements2`/`vkDestroyImage` exercised on the
real wire (vulkaninfo's image-support probing) — the image object path works end-to-end.
`vkGetPhysicalDeviceExternalBufferProperties`/`ExternalFence`/`ExternalSemaphoreProperties`
were not observed in this Mesa build's probing path; the commands are implemented
(computed via the exec-word buffer) and exercised in the vnfront/model suites.
