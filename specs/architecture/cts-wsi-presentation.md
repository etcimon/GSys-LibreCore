# `wsi` (35,481), `drm-format-modifiers` (1,572), `ycbcr` (62,333), `transform-feedback` (133,695), `shader-object/*` (242,382) — presentation, modifiers, YCbCr, transform feedback, shader objects

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass lists `vk-default/{wsi,drm-format-
modifiers,ycbcr,transform-feedback}.txt`, `vk-default/shader-object/*.txt`. Grouped here
because each is either a platform/presentation obligation (W9) or an optional extension
family with a known decision; they split into their own files when adopted.

## Inventory and decisions

| group | cases | extension / feature | decision |
|---|---:|---|---|
| `wsi` | 35481 | VK_KHR_surface/swapchain per platform: `xlib` 3874, `xcb` 3874, `win32` 3874, `wayland` 3873, `headless` 3873, `android` 4360, `metal` 4739, `direct`/`direct_drm` 3494 each, `display*` 26 | **W9**: `wayland`, `xcb`/`xlib` and `headless` must pass on the x86-64 Ubuntu target (the others are NotSupported by platform); the device side = dma-buf export/import, RESOURCE_UUID-class identity, sync fds, scanout where KMS exists |
| `drm_format_modifiers` | 1572 | VK_EXT_image_drm_format_modifier: list/create/export-import/bound-to-dma-buf ×131 formats | **W9**: required for Wayland/X11 compositors to import our buffers zero-copy; at minimum the LINEAR modifier over our (linear) layout |
| `ycbcr` | 62333 | VK_KHR_sampler_ycbcr_conversion (1.1 core *API*, feature optional): `copy` 42752, `conversion` 11088, `copy_dimensions` 2560, `plane_view` 2400, `format` 2232, `query` 1008, `storage_image_write` 228, … | optional feature `samplerYcbcrConversion` — video/camera content; **not planned for the SKU** unless a workload needs it (UE media framework uses it) — W1 decision |
| `transform_feedback` | 133695 | VK_EXT_transform_feedback: `primitives_generated_query` 107866 (EXT_primitives_generated_query), `simple*` 23657, `fuzz` 2168 | Zink GL 3.0 requires it; **W8** with the geometry/mesh output path (XFB = writing the pre-raster output records to buffers with counters) |
| `shader_object/*` | 242382 | VK_EXT_shader_object: `rendering` 240686, `binary` 437, `misc` 744, … | not planned initially (Zink prefers it but does not require it); revisit after W4.1 when pipeline state is fully dynamic anyway |

## Architectural logic (W9 presentation; the others are cards in their future files)

```text
LOGIC WSI-L1 · Swapchain images are ordinary images the compositor can import
  CLAIM       vkCreateSwapchainKHR/AcquireNextImage/QueuePresent with the surface's
              formats/colour spaces/present modes/transforms/alpha; image count and
              extent rules; recreation on resize; multiple swapchains; acquire/present
              synchronisation (semaphores, fences, present-wait/id with the EXTs);
              headless surfaces; the images render like any attachment.
  SOURCE      wsi.{wayland,xcb,xlib,headless}.{surface,swapchain,…}.*.
  MECHANISM   In the stock stack the *guest* (Mesa WSI + virtio-gpu DRM) owns swapchains:
              the renderer must export swapchain images as dma-bufs the compositor can
              scan out or import — i.e. our device memory must be exportable as
              virtio-gpu blobs with a DRM format modifier the compositor understands
              (LINEAR at minimum; W9.4 resource/blob/UUID behaviour) and present must
              complete with a sync fd / fence the compositor can wait on (W9.4 sync-fd).
              On x86-64 this rides on the virtio-pci function (W9.2); on RISC-V on
              virtio-mmio. KMS (`display*` tests) only where we expose a connector
              (num_scanouts > 0 — W9.6).
  REQUIRES    API-L9's import path (compositor → us, for cross-device buffers) and the
              export path; external fences/semaphores (SYNC-L3); linear-modifier
              images with the pitch the compositor expects.
  FORBIDS     A per-frame CPU copy to present (plan W9.5); a custom compositor plugin.
  CHECK       wsi.headless.* first (no compositor; CTS-4), then wayland/xcb on the
              x86-64 target (CTS-5).
  COST        control plane only; zero-copy is the point.
  FEEDS       plan W9; UE/CS2 on screen; CTS-5.
  STATUS      not-run (NotSupported — no surface extensions advertised by the renderer;
              the guest's Mesa may still expose WSI over our device once dma-buf export
              works)

LOGIC MOD-L1 · DRM format modifiers
  CLAIM       vkGetPhysicalDeviceFormatProperties2 lists modifiers per format with plane
              counts and features; images created with explicit/list modifiers; export
              to dma-buf and import with the modifier; memory requirements per plane.
  SOURCE      drm_format_modifiers.* (131 formats × 12 patterns).
  MECHANISM   Advertise DRM_FORMAT_MOD_LINEAR for the formats whose device layout is
              the standard linear pitch (ours: 64-B aligned pitch — the modifier
              contract must match what the kernel/compositor assume; if a compositor
              requires tighter pitch alignment the layout parameterises it); a vendor
              tiled modifier only if a tiled layout is ever introduced (IMG-L3).
  REQUIRES    API-L9 export/import of our pages as blobs.
  FORBIDS     Claiming a modifier whose layout we do not produce.
  CHECK       drm_format_modifiers.list_modifiers.*, create_explicit_modifier.*
              (CTS-4); export_import.* with API-L9.
  COST        none.
  FEEDS       WSI-L1; CTS-4/5.
  STATUS      not-run (NotSupported)
```

## Exceptions

```text
EXCEPTION WSI-X1 · Platforms we do not have
  CONDITION   wsi.{android,metal,win32,direct,direct_drm,display*,acquire_drm_display}.
  RESULT      NotSupported (the loader has no such surface extension on Linux).
  TRUTH       platform absence.
  MECHANISM   —
  CHECK       ledger.
  FORBIDS     —

EXCEPTION OPT-X2 · ycbcr / transform feedback / shader objects
  CONDITION   samplerYcbcrConversion false, EXT_transform_feedback absent,
              EXT_shader_object absent.
  RESULT      NotSupported (438,410 cases across the three).
  TRUTH       profile lines; XFB is a Zink requirement (W8 decision), ycbcr and shader
              objects are W1 decisions.
  MECHANISM   Profile ROM.
  CHECK       ledger (0 fail).
  FORBIDS     —
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| WSI-H1 Export path first | API-L9 decision | high | dma-buf export of our blobs with LINEAR modifier | — |
| WSI-H2 Headless | CTS-4 | medium | wsi.headless.* on the RISC-V guest | — |
| WSI-H3 Compositor on x86-64 | W9.2 virtio-pci | later | wayland/xcb swapchains under a real compositor | — |

## Performance / area / scalability

Presentation is bandwidth and latency: zero-copy requires a layout the compositor reads
directly (LINEAR is universally accepted; tiled needs a shared modifier). The display
consumer (HDMI leaf) connects only after W9.6.
