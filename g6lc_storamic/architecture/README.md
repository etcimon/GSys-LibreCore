# g6lc_storamic architecture

Reusable first-party memory/storage digital stack for GSys LibreCore and other
AXI consumers. The standalone RTL must compile without the host repository's
core configuration or third-party RTL. The [system specification](../../architecture/storamic/README.md)
owns product topology and SoC integration.

| Contract | Scope |
| --- | --- |
| [configuration](configuration.md) | Compile-time geometry, backend exclusion, capability grants |
| [contracts](contracts.md) | AXI and normalized transaction ownership |
| [discovery and pins](discovery-and-pins.md) | Passive/active sticks, identification and signal budgets |
| [media and persistence](media-and-persistence.md) | RAM, flash, protected domains and recovery |
| [host interfaces](host-interfaces.md) | Native RAM and selected VirtIO-MMIO transport |
| [VirtIO-MMIO decision](virtio-mmio.md) | Settled transport architecture; supersedes the retired CXL target |
| [general-purpose review](general-purpose-review.md) | Ten-caveat architecture audit; proposals, not accepted features |
| [verification](verification.md) | Remote evidence, first-party closure, g6lc_qemu boundary |
| [implementation tasks](implementation-tasks.md) | Dependency-ordered ST-001..ST-041 backlog, code owners and completion gates |
| [model interface](model-interface.md) | Executable-model implementation design (not a capability grant) |

Current stage: M0 refusal foundation implemented with selected-stage evidence;
legacy configuration repairs, the joined service-readiness slice, the standalone
executable-model component and the typed top profile are verified by scoped leaf
runs (`storamic-7eea26e38385`, `storamic-3c25eee4aaa3`). Native model exposure,
aggregate and physical qualification gates remain open. Descriptions
of media, VirtIO and serial-link engines are requirements, not implementations.

## Separation of concerns

The frontend tracks requests and responses; routing owns region/slot selection;
media backends implement device timing; persistence owns durability; transport
owns link framing/retry; discovery owns validated capabilities. No block infers
another block's completion from queue emptiness without an explicit contract.

Memory-device command decoders belong on an oramic device; host controllers
encode those commands. Digital output enables are portable; pads, sampling delays,
clocking, SRAM arrays and SerDes require target bindings. Production arrays use the
sanctioned SRAM macro interface, not flop arrays disguised as portable memory.

All new source in the standalone closure is first-party, including CDC, FIFOs and
AXI logic. Existing SoC types are converted outside that closure. Protocol standards
are interfaces, not permission to copy a third-party implementation.
