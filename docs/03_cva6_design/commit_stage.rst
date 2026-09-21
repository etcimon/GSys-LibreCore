Commit Stage
=============

The commit stage is the last stage in the processor's pipeline. Its
purpose is to take incoming instruction and update the architectural
state. This includes writing CSR registers, committing stores and
writing back data to the register file. The golden rule is that no other
pipeline stage is allowed to update the architectural state under any
circumstances. If it keeps an internal state it must be re-settable
(e.g.: by a flush signal, see ).

We can distinguish two categories of retiring instructions. The first
category just write the architectural register file. The second might as
well write the register file but needs some further business logic to
happen. At the time of this writing the only two places where this is
necessary it the store unit where the commit stage needs to tell the
store unit to actually commit the store to memory and the CSR buffer
which needs to be freed as soon as the corresponding CSR instruction
retires.

In addition to retiring instructions the commit stage also manages the
various exception sources. In particular at time of commit exceptions
can arise from three different sources. First an exception has occurred
in any of the previous four pipeline stages (only four as PC Gen can't
throw an exception). Second an exception happened during commit. The only
source where during commit an exception can happen is from the CS
register file and from an interrupt.

To allow precise interrupts to happen they are considered during the
commit only and associated with this particular instruction. Because we
need a particular PC to associate the interrupt with it, it can be the
case that an interrupt needs to be deferred until another valid
instruction is in the commit stage.

Furthermore commit stage controls the overall stalling of the processor.
If the halt signal is asserted it will not commit any new instruction
which will generate back-pressure and eventually stall the pipeline.
Commit stage also communicates heavily with the controller to execute
fence instructions (cache flushes) and other pipeline re-sets.

AMO result availability
-----------------------

AMO execution writeback prepares an instruction for commit; it is not the final
architectural register result. The commit stage selects that result from the AMO
response. The architectural operand-forwarding path therefore waits for an AMO
producer to retire instead of forwarding its early placeholder. This distinction
is covered by the directed LR/SC dependency tests in ``AGENTS-specs-to-tests.md``.
No LR reservation or flush rule is changed by this readiness correction.

OoO cancelled-slot retirement
----------------------------

Retiring a cancelled slot drains bookkeeping but does not authorize architectural
side effects. The OoO dispatch path qualifies committed-map updates, old-physical
register frees, checkpoint release and LSQ store commit with the existing cancellation
mask. Raw ROB retirement remains active so cancelled work can drain. Directed tests
cover cancellation on the first commit lane and alongside an older live retirement
on the second-lane case. This is component qualification, not full OoO/SMT closure.

OoO data readiness and halt boundaries
-------------------------------------

Execution completion is not necessarily operand availability. CSR and AMO results
are selected at commit. The OoO path now suppresses their execution-stage value
wakeup and uses the existing commit-time PRF write to release rename/IQ waiters.
This adds a metadata wakeup channel, not another PRF data-write port. Integer
results that are usable at execution and FP writebacks retain their existing path.

FP committed-map updates include all architectural FP destinations, including f0.
The FP physical file also retains physical register zero; only the integer PRF
uses hardwired-zero behavior. Hart-local recovery restores both committed classes
and reclaims physicals according to ownership after same-cycle allocation.

WFI retires through the precise flush/restart path under OoO. Younger allocated
work must be discarded before parking: otherwise halt blocks its retirement while
the coarse-handoff scheduler waits for the scoreboard to empty. Cancelled,
faulting, invalid or halted WFI entries do not initiate this restart. The existing
next-PC path advances past the uncompressed WFI; no software-visible encoding or
CSR change is introduced. OoO-off behavior is retained.

These are directed and bounded integration repairs, not general mixed-hart OoO,
FP compliance, unbounded liveness, scan, physical timing or power sign-off.
Current evidence and remaining gates are in ``architecture/out-of-order/README.md``.

WT retained-copy visibility
--------------------------

Commit and memory acknowledgment are not the end of a store's visibility
obligation when a post-ACK fixup still forwards its bytes. A later same-word
acknowledgment must refresh that copy, including at full queue capacity and on a
cache hit. Byte coalescing must preserve untouched valid bytes, and retirement
must not discard a concurrent update. The directed checks and remaining limits
are recorded in ``architecture/dcache-ack-before-check.md`` and
``AGENTS-specs-to-tests.md``; no ISA, device-tree or permission change is involved.
