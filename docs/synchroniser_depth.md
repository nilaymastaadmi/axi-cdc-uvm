# Synchroniser depth: what two flops actually buy

`rtl/async_fifo.v` uses a two-flop synchroniser on both Gray pointer crossings because
that is the standard depth, not because a failure rate was derived for it. This works
through the MTBF the two-flop choice actually produces for this design's own clocks
(100 MHz and 27 MHz, as driven in `tb/tb_cdc.sv` and `uvm/tb_top_uvm.sv`), rather than
citing the convention and leaving it there.

## Result

For the tighter of the two crossings in this design, a two-flop synchroniser gives an
MTBF of at least **10^8 years** under deliberately pessimistic technology assumptions,
and a practically meaningless **~10^422 years** under assumptions representative of a
modern digital process. Both numbers are derived below, not asserted. A single flop
used without that second stage — i.e. its output consumed before it has a full clock
period to settle — gives an MTBF of about **0.7 microseconds** under the same
pessimistic assumptions: roughly a million potential metastable failures a second. That
contrast is the actual argument for depth two, not "convention."

## The formula

Standard two-flop synchroniser MTBF (Ginosar, *Metastability and Synchronizers: A
Tutorial*, IEEE Design & Test, 2011):

```
MTBF = e^(t_r / tau) / (Tw * Fc * Fd)
```

- **tau** — the flip-flop's metastability resolving time constant: how fast a
  metastable output decays back toward a valid logic level. Technology-dependent.
- **Tw** — the metastability window: the span of arrival times of the asynchronous
  input, relative to the sampling edge, that can trigger a metastable event at all.
  Also technology-dependent, and empirically close to `tau` in magnitude.
- **t_r** — the resolution time actually granted before the (possibly metastable)
  output is used by anything else. For a two-flop synchroniser this is one full period
  of the *sampling* (destination) clock: the second flop only looks at the first flop's
  output a whole clock later.
- **Fc** — the sampling (destination) clock frequency.
- **Fd** — the rate at which the asynchronous input can change. Conservatively bounded
  by the *source* clock frequency: the worst case is that the signal changes on every
  source cycle, regardless of the actual traffic pattern.

Neither this design's RTL nor its Yosys synthesis flow (`scripts/synth.ys`, generic
cell library) targets a specific silicon process, so `tau` and `Tw` are not measured
here — they are stated, sourced, and used as explicit assumptions rather than
presented as measurements.

## The two crossings in this design

`async_fifo` instantiates two independent two-flop synchronisers, one per direction:

| path | destination clock (samples) | t_r (one destination period) | source rate `Fd` |
|---|---|---:|---:|
| `wgray` &rarr; `wgray_s1/s2`, into the read domain | `bclk`, 27.000 MHz | 37.037 ns | `aclk`, 100 MHz |
| `rgray` &rarr; `rgray_s1/s2`, into the write domain | `aclk`, 100 MHz | 10.000 ns | `bclk`, 27.000 MHz |

(Frequencies as driven in `uvm/tb_top_uvm.sv`: `aclk` toggles every 5.0000 ns for an
exact 10 ns / 100.000 MHz period; `bclk` toggles every 18.5185 ns for a 37.037 ns /
27.000 MHz period — the same clocks `tb/tb_cdc.sv` uses.)

The `aclk`-destination path gets less than a third of the settling time of the other,
so it is the binding case: whatever MTBF *it* produces is this design's actual
synchroniser MTBF. Reporting only the more generous path would be the same mistake as
reporting 20/20 coverage by hiding the illegal bins — the weaker number is the one that
matters.

## Two technology assumptions, both worked through

**Conservative / mature-process bound** — `tau = 200 ps`, `Tw = 500 ps`. Not from a
specific published part; chosen to be roughly 20x worse than the modern-process figures
below, as a deliberate lower bound rather than a best case.

**Modern-process illustrative bound** — `tau = 10 ps`, `Tw = 20 ps`, the example values
Ginosar's tutorial gives for a 28 nm-class high-performance CMOS process (both
parameters are, per that tutorial, empirically close to the process's gate delay).

| case | tau | Tw | binding path `t_r/tau` | MTBF |
|---|---:|---:|---:|---|
| conservative | 200 ps | 500 ps | 50.0 | ~1.2 x 10^8 years |
| modern-process illustrative | 10 ps | 20 ps | 1000.0 | ~10^422 years |

(Full arithmetic: `t_r/tau = 50` gives `log10(MTBF) = 15.58` seconds, i.e. `3.8 x
10^15` s, divided by `3.156 x 10^7` s/year = `1.2 x 10^8` years. The modern-process case
has an exponent 20x larger, which does not scale the *year* figure by 20x — it raises
`e^1000` instead of `e^50`, which is why the second row is not just "20x more years"
but categorically off the scale of anything physical.)

The other crossing (`bclk`-destination, `t_r = 37.037 ns`) has 3.7x the exponent of the
binding path and produces correspondingly larger numbers in both cases (`~10^67` years
conservative, `~10^1596` years modern-illustrative) — stated here for completeness, not
because it's the number that should be quoted for this design.

## Why not one flop, and why not three

**One flop is not a synchroniser.** If the first flop's output were used immediately —
`t_r = 0`, no second stage giving it a further clock period to settle — the same
conservative constants give `MTBF = 1 / (Tw * Fc * Fd) ≈ 0.74 microseconds`. That is
the number a single-stage capture actually produces: on the order of a million
potential metastable failures per second. This is the concrete version of "why every
CDC signal needs at least two flops," not an appeal to convention.

**A third flop is not free, and here it buys nothing that matters.** Adding a third
flop to the binding path gives it two destination-clock periods to settle instead of
one, which (conservative constants) raises the MTBF from `~1.2 x 10^8` years to
`~10^29.8` years — another ~22 orders of magnitude. But `10^8` years already exceeds
any realistic operating lifetime for this design by six-plus orders of magnitude, so
that additional margin buys nothing in practice. What the third flop *would* cost is
real: one more cycle of latency on the pointer feedback into the full/empty comparison
in `rtl/async_fifo.v`, making the (already-conservative, see that file's `gray2bin`
comment) occupancy report stale by one additional cycle. Depth two is the right choice
for these clocks, not merely the conventional one.

## What would actually move this number

- **Faster destination clocks.** `t_r` is one destination-clock period, so a
  GHz-class destination domain shrinks the settling window proportionally. This is the
  regime (not this design's 100 MHz / 27 MHz) where real designs go to three or four
  synchroniser stages.
- **Worse `tau`/`Tw` corners.** Near-threshold voltage operation, radiation
  environments, or an older process node than either assumption above all push `tau`
  up, shrinking the exponent. The conservative case above is meant to bound this, not
  eliminate the question.
- **Actual sign-off** needs `tau` and `Tw` from the target library's flip-flop
  metastability characterization report, not the illustrative constants used here. That
  report does not exist for a design synthesised against a generic Yosys cell library
  rather than a real process.

## Where this leaves the README's scope note

The README lists "no MTBF budget, and the synchroniser depth is fixed at two rather
than derived from a target failure rate" as an honest gap. The depth is still fixed at
two — that has not changed — but it is no longer undefended: for this design's actual
clocks, two flops is derived to clear any realistic failure-rate target by a wide
margin, and the arithmetic showing *how* wide is above rather than asserted.

## Source

Ran Ginosar, "Metastability and Synchronizers: A Tutorial," *IEEE Design & Test of
Computers*, 2011.
