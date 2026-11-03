# Frontend and transaction contracts

AXI4 data and AXI4-Lite control remain internal interfaces, not connector pins.
The standalone boundary uses first-party definitions or scalar ports; inherited
SoC bus packages are confined to the integration adapter.

## M0 refusal behavior

Absent media must never return a successful write or fabricate a successful read.
The skeleton accepts bounded legal transactions and responds with `SLVERR`;
reads retain ID, beat count and `RLAST`, writes drain their declared data before B.
AW and W are independent: accepting W may wait for AW, but AW acceptance may not
depend on W. Keep offered responses stable until handshake. A master must finish
an accepted burst; malformed-master recovery is separate from normal progress.

Read and write channels have independent bounded state. Reset aborts in-flight
transactions under the system reset contract; do not deliver stale completions
after reset. Pads remain inactive, CS deasserted and DQ output enables clear.
No control access silently enables an unimplemented feature.

`service_ready_o` reports that the frontend can service a request, including a
refusal; it is low during reset and for illegal configuration/geometry. It does
not imply RAM initialization or usable capacity. Native joins use this signal
for admission, while media/health consumers retain `init_done_o` and media readiness.
The off and skeleton profiles still return errors and keep all media pads inactive.

Contract version 2 types the standalone profile as off/refuse/model. The model
profile is standalone-only: it reads and writes through an explicit external
memory seam (`mem_*`/`txn_id_t`/`events_o`), never an internal RAM fallback, and
is not offered by the native projection. `init_done_o` then reports bound model
readiness (`service_ready_o && mem_ready_i`), not physical media; control
requests still refuse and issue no memory command, while the selected model
datapath genuinely reads and writes its explicit external binding with inactive
physical pads and no physical-media or persistence qualification.
Sequence exhaustion is a fail-safe admission refusal, distinct from readiness.

The reference data types use 64-bit addresses/data, 8-bit IDs and one-bit user
fields; native adapters inject matching request/response types. AXI-Lite uses
64-bit addresses and 32-bit data, with no ID. M0 permits one outstanding read
and one outstanding write independently on each frontend. It drains 1..256 data
beats as declared by AXI `LEN`; AXI-Lite always represents one beat.

Every returned data word and response user field is zero; every response is
`SLVERR`. Address, burst type, transfer size and write strobes cannot cause a
media side effect in this profile. The declared beat count, not early `WLAST`,
controls write draining. Missing beats and inconsistent `WLAST` violate the
master contract; M0 supplies no malformed-master timeout or resynchronization.
Completion is bounded once the master supplies its write beats and accepts
responses; arbitrary `WVALID`/`RREADY`/`BREADY` stalls are not a liveness bound.

## Executable-media requirements

- Preserve narrow accesses, byte strobes, IDs, same-ID response order and all
  supported burst semantics. Unsupported encodings receive explicit errors.
- Split at stripe, region, chip and transport boundaries and reassemble the
  original response shape. A simulation assertion is not a production splitter.
- Check complete spans and permissions before media side effects; never alias by
  truncating a high address.
- Reserve response storage for accepted/in-flight commands as well as data
  already present in FIFOs.
- Transaction identity includes source, ID/sequence and reset generation.
  Active-link replay cannot duplicate a committed write or atomic effect.
- Existing native exclusives/atomics remain above the attachment. Other writers
  must participate in the applicable reservation and coherence contract.
- AXI B denotes the documented write-completion point, not automatically flash
  durability. PMEM and block flush semantics impose stronger requirements.

AXI-Lite controls have no automatic ordering relationship with independent AXI
data traffic. A future drain operation needs explicit frontend tracking and a
software ordering contract. Maintenance arbitration must make bounded progress
without allowing flash/background traffic to starve CPU demand.
