# axi-cdc-uvm

An AXI4-Lite slave whose write payloads cross into an unrelated clock domain through a
Gray-coded asynchronous FIFO, verified against a scoreboard rather than by inspection.

The design exists to hold one property up to scrutiny: **every write the slave accepts
with an OKAY response appears exactly once at the consumer, in order, with its byte
strobes applied — regardless of how the two clocks happen to line up.** Everything in
`tb/` is there to try to break that claim.

## Result

100 constrained-random seeds, an AXI domain at 100 MHz against a consumer domain at
27 MHz (deliberately unrelated, so edges drift through every phase relationship rather
than settling into a repeating pattern):

| | |
|---|---:|
| transactions crossed the domain | 11,495 |
| scoreboard mismatches | 0 |
| protocol / CDC assertion checks | 1,266,540 |
| assertion failures | 0 |
| functional coverage (union across seeds) | 18/18 = 100% |
| directed tests passing | 5/5 |

Reproduce with `make test && make regress`.

## What is being checked

**The scoreboard owns correctness.** Expectations are registered by a monitor watching
the DUT's *actual* push, not predicted by the driver. That distinction is not
cosmetic — the consumer runs in another clock domain and can pop a payload before the
driver's write task has even returned its response. The first version of this testbench
predicted from the driver and reported failures that were purely an artefact of the
checker racing the design.

**Protocol and CDC rules are checked continuously**, not sampled at the end:

- `AWVALID`/`WVALID`/`BVALID` hold, with stable payload, until the matching `READY`
- every accepted write receives a response within a bounded number of cycles
- no push into a full FIFO, no pop from an empty one
- **Gray pointers change by exactly one bit per clock** — the property the whole
  crossing rests on. If two bits ever move together, a synchroniser sampling
  mid-transition can latch a pointer value that never existed, and the full/empty logic
  will act on it.

`sva/axi_props.sv` carries these as real SystemVerilog assertions in a bind module.
They do not run on the open-source flow — Verilator rejects `##` delay expressions in
sequences and Icarus does not parse `property` blocks at all — so `tb/tb_cdc.sv`
implements the same rules procedurally. The two must be kept in agreement; the SVA file
is authoritative on a commercial simulator.

## Coverage, and two bins that cannot be hit

The coverage model bins address kind, strobe shape, response, FIFO occupancy, and the
cross of address kind against response. Two of the six crosses are **unreachable by
construction**:

| cross | why it cannot occur |
|---|---|
| (register, SLVERR) | a mapped, aligned register write always returns OKAY |
| (unmapped, OKAY) | an unmapped address always returns SLVERR |

These are `illegal_bins`, not `ignore_bins`. The difference matters: they are excluded
from the denominator *and* hitting one fails the test, because it would mean the address
decoder had accepted something it must reject. Reporting 16/20 and calling the
difference a coverage hole would have meant chasing stimulus that cannot exist.

The remaining two initially-unhit bins — FIFO full, and (FIFO, SLVERR) — were real
holes, and the cause was the stimulus rather than the design. A per-cycle random
consumer enable never stalls long enough to fill a 16-deep FIFO, so occupancy never left
the low bins and the backpressure path went unexercised. Replacing it with a bursty
consumer (run 15–50 cycles, stall 40–140) closed both.

## Three defects the harness caught

All three were found by the checkers rather than by reading waveforms, and each is
recorded because how it presented is the useful part.

**Combinational loop between the FIFO flags and the pointer increment.** The first
version computed `full` and `empty` combinationally from the incremented pointers. But
the increment itself has to be qualified by the flag — never write when full, never
read when empty — which closes a zero-delay path:

```
empty -> rd_en qualification -> rbin_next -> rgray_next -> empty
```

The simulator reported that the active region did not converge, which is what a
combinational loop looks like from the scheduler's point of view rather than an obvious
"loop detected". Fixed by registering both flags, as the standard synchronous
pointer-comparison design does: the increment consumes last cycle's flag while this
cycle's flag is computed from the new pointer.

**A testbench sampling race that looked like a design hang, twice.** Sampling handshakes
at the posedge raced the non-blocking update and missed `BVALID`, which is asserted for
exactly one cycle. Moving the sample to posedge-plus-a-skew fixed that and broke the
opposite case: reading after the update meant an `AWREADY` that *was* high at the edge
read back low, so the handshake was missed in the other direction. Every handshake
signal here is registered, so between one posedge and the next it holds exactly the
value the upcoming posedge will sample — the negedge is the only point where the answer
is unambiguous, and that is where the driver samples now.

**An illegal coverage bin caught a bug in a directed test.** The `error_response` test
drove six addresses it labelled unmapped, and the regression started failing on the
illegal-bin check for (unmapped, OKAY). The design was right: `0x14` is a perfectly
valid aligned register in the map, so it returned OKAY as it must. The *test* was
wrong. This is the argument for `illegal_bins` over `ignore_bins` in one example — an
excluded bin says nothing when the model and the stimulus disagree, whereas an illegal
bin turns the coverage model into an active check on the testbench itself.

Worth stating plainly: the design was correct through the second and third of these.
The bug was in the thing doing the checking, which is the failure mode that quietly
passes a broken design when it happens to fall the other way.

## Area

Yosys, generic cell library, so the numbers are technology-independent and comparable
between modules rather than a claim about any particular process.

| module | cells | flip-flops |
|---|---:|---:|
| `cdc_bridge` (total) | 4,588 | 1,391 |
| `axi4lite_slave` | 3,007 | 638 |
| `async_fifo` | 1,422 | 680 |
| consumer / glue | 161 | 73 |

The FIFO's 680 flops are dominated by the 16 x 40-bit storage array (640); the
remaining 40 are the two 5-bit pointers, their Gray encodings, the two-stage
synchronisers in each direction, and the two registered flags.

## Address map

| offset | access | behaviour |
|---|---|---|
| `0x00` | write | enqueue `{addr, strobe-merged data}` into the CDC FIFO; SLVERR if full |
| `0x00` | read | status word `{30'b0, empty, full}` |
| `0x10`–`0x3C` | read/write | 12-word scratch register file, byte-strobe merged |
| anything else | read/write | SLVERR, transaction still completes |

The hole in the map is deliberate. Without an unmapped region there is nothing to
verify about error responses, and a decoder that silently accepts everything looks
identical to a correct one.

## Layout

```
rtl/    async_fifo.v      dual-clock FIFO, Gray pointers, 2-flop synchronisers
        axi4lite_slave.v  five-channel AXI4-Lite slave, register file, SLVERR decode
        cdc_bridge.v      slave + FIFO + consumer, the top level

tb/     tb_cdc.sv         layered testbench: transaction / scoreboard / coverage
                          classes, procedural driver and checkers, runs on Verilator

sva/    axi_props.sv      the same rules as real SVA in a bind module (commercial sim)

uvm/    axi_if.sv         AXI4-Lite interface plus a passive CDC observation interface
        axi_pkg.sv        UVM env: sequence item, driver, monitors, scoreboard with
                          TLM analysis ports, coverage subscriber, layered sequences
                          and tests
        tb_top_uvm.sv     UVM testbench top

scripts/regress.py        multi-seed regression, coverage unioned across seeds
        synth.ys          Yosys area run
```

## Running it

Open-source flow — no licence needed:

```
make test                    # 5 directed tests
make regress SEEDS=100       # constrained-random regression + coverage
make synth                   # cell and flip-flop counts
make lint                    # Verilator lint
```

UVM flow — needs Xcelium, VCS or Questa. EDA Playground is sufficient:

```
xrun -uvm -sv -timescale 1ns/1ps rtl/*.v uvm/axi_if.sv uvm/axi_pkg.sv \
     uvm/tb_top_uvm.sv sva/axi_props.sv +UVM_TESTNAME=axi_random_test
```

Available tests: `axi_random_test`, `axi_fifo_full_test`, `axi_error_test`.

## Scope

AXI4-Lite only: no bursts, no outstanding transactions, no ID fields, no protection or
cache attributes. One outstanding write at a time. The FIFO is a single crossing rather
than a full CDC strategy — no reset-domain crossing analysis, no MTBF budget, and the
synchroniser depth is fixed at two rather than derived from a target failure rate.
Those are the honest next steps rather than oversights, and the checkers are written so
they survive them: an out-of-order or multi-outstanding slave still has to satisfy every
property in `sva/axi_props.sv` unchanged.
