<p align="center">
  <img src="../../arv_custom_csr/doc/img/aRVern_light.png" alt="aRVern" width="180">
</p>

# arv_primitives — the technology adaptation layer

Six small modules that every other aRVern IP is built from: two flip-flops, a
clock-domain-crossing synchroniser, a clock gate, and two reset-network gates —
plus two reference blocks assembled from them: `arv_reset_gen` and
`arv_osc_ctrl`.

They are not here to save typing. They exist so that **every structure that a
physical-design or safety flow needs to control lives in one place, in six files you
are expected to edit.** Nothing else in the IP library instantiates a discrete flop, a
synchroniser or a clock gate. The one exception is an inferred memory and its
read-data register (`arv_scope_core`, `arv_dtm_rxfifo`): those stay in a plain
`always` block so that synthesis infers a RAM, and they are outside anything you
change here.

That matters most for sensitive circuits — reset networks, CDC, clock gating — where
the right implementation is not portable. It depends on your library, your rules and
your sign-off flow. Rather than guess, the library concentrates those decisions here
and keeps the RTL above them technology-neutral.

| Primitive | Purpose |
|---|---|
| `arv_ipdff` | enabled flip-flop, selectable reset style |
| `arv_synchronizer` | W-bit 2-FF level CDC |
| `arv_or` | OR for reset networks |
| `arv_cgate` | integrated clock gate |
| `arv_and` | AND for reset networks |
| `arv_ipdff_sinit` | `arv_ipdff` + synchronous re-init |
| `arv_reset_gen` | reference SoC reset generator (not a cell — built from the six above) |
| `arv_osc_ctrl` | reference oscillator controller (likewise) |

Editing one file changes every instance in the tree. That is the point — and the risk.

## Contents

- [Adapting them to your rules](#adapting-them-to-your-rules)
  - [Keep a cell out of synthesis' hands](#keep-a-cell-out-of-synthesis-hands)
  - [Use your own integrated clock gate](#use-your-own-integrated-clock-gate)
  - [Use a hardened or monolithic synchroniser](#use-a-hardened-or-monolithic-synchroniser)
  - [Change the reset architecture](#change-the-reset-architecture)
  - [Swap in retention or special flops](#swap-in-retention-or-special-flops)
- [The contract](#the-contract)
  - [X propagation in simulation](#x-propagation-in-simulation)
- [Reference](#reference)
  - [`arv_ipdff`](#arv_ipdff--enabled-flip-flop)
  - [`arv_ipdff_sinit`](#arv_ipdff_sinit--flip-flop-with-synchronous-re-init)
  - [`arv_synchronizer`](#arv_synchronizer--level-cdc)
  - [`arv_cgate`](#arv_cgate--integrated-clock-gate)
  - [`arv_and` / `arv_or`](#arv_and--arv_or--reset-network-gates)
  - [`arv_reset_gen`](#arv_reset_gen--reference-soc-reset-generator)
  - [`arv_osc_ctrl`](#arv_osc_ctrl--reference-oscillator-controller)
- [Verification](#verification)
  - [Bench](#bench)
  - [Tests](#tests)
  - [Lint](#lint)
  - [Running](#running)
- [License](#license)

## Adapting them to your rules

Common cases, and where to make the change.

### Keep a cell out of synthesis' hands

Reset trees and clock gates usually need to survive as identifiable instances.
`arv_and` / `arv_or` exist purely so a reset combine stays **one cell** instead of
being restructured, absorbed into downstream logic, or duplicated per fanout branch —
which would skew reset arrival between flop groups.

Each is a single `assign`, so nothing in the RTL itself keeps it alive: the flow
has to. Three steps, in this order:

1. **Keep the hierarchy through compile.** A one-gate module is the first thing
   automatic ungrouping flattens, before any post-compile constraint can name it.
   Either `set_ungroup [get_designs {arv_and* arv_or*}] false` before compile, or
   `compile_ultra -no_autoungroup`, which is what the IPs' reference `synthesis.tcl`
   scripts do.
2. **Match by pattern, not by exact name.** Elaboration appends the parameter value
   to the design name (`arv_and_N2`), so a filter on `ref_name == arv_and` matches
   nothing; use `ref_name =~ arv_and*`.
3. **After mapping, `set_size_only` on the leaf gate inside each instance.** Prefer
   it to `set_dont_touch`: the reset tree still needs sizing and buffering, just not
   restructuring.

A post-compile `get_cells -hierarchical -filter "ref_name =~ arv_and*"` whose count
equals the RTL instance count is the check that the three steps worked. It matters
beyond skew: the gate-level reset-style check classifies a flop as asynchronously
reset by tracing the fanout of the reset ports, so a gate merged into the reset tree,
or duplicated, also changes what that check reports.

### Use your own integrated clock gate

`arv_cgate` is written as the standard **latch + AND** ICG structure, so a technology
ICG maps onto it directly. If your flow prefers an explicit library instance, replace
the body with that cell.

Two things must survive the swap:

- **The latch is intentional.** It is transparent while `clk_i` is low, which is what
  makes the output glitch-free whatever the enable does. It is lint-waived on purpose —
  do not "fix" it, and do not let synthesis decompose it into random logic.
- **`test_en_i` must keep forcing the clock on.** Tie it to the DFT scan-enable on
  ASIC; a gate without it blocks the scan chain.

No IP in the library instantiates the cell in its RTL: the IPs export a clock-enable
request (`hclk_en_o`) and the SoC gates the clock above them. `arv_cgate` is the cell
that gate is expected to be, and the `arv_scope` bench and this library's own test
are what exercise it (see [Verification](#verification)).

### Use a hardened or monolithic synchroniser

`arv_synchronizer` is a plain 2-FF chain. If your library provides a hardened
multi-bit-upset-resistant or monolithic synchroniser cell, instantiate it here.

Before you do, note why this module **deliberately does not reuse `arv_ipdff`**: a
synchronous-reset flop adds a 2:1 mux on the D pin, and a mux on the **second** stage —
in the `meta_q → sync_q` path — eats into the metastability settling window and degrades
MTBF exponentially. The two reset styles are therefore hand-written, with the
sync-reset mux kept on the first stage only. Any replacement must preserve that
property, or the CDC gets quietly worse in a way no simulation will show.

That choice has a consequence the swap must also preserve, because the IPs are
written to it: **under `ARST_EN=0` the second stage is not reset at all.** `meta_q`
takes `RST_VAL` on the first `clk_i` edge with `rst_n_i` low and `sync_q` copies it on
the next, so `sync_o` reaches `RST_VAL` on the **second** edge — one later than an
`arv_ipdff` beside it — and is unknown for two edges out of power-up. A synchronous
reset must therefore span **at least two destination-clock edges**. After a one-edge
reset the first cycle is stale: a consumer that compares `sync_o` against a register
reset in the same cycle (an edge detector `sync_o ^ sync_o_d`) sees a phantom edge.
Under `ARST_EN=1` both stages clear on the reset edge and none of this applies. If a
hard reset on the second stage is ever wanted, it has to come from a library flop with
a dedicated synchronous-reset pin — never from a D-side mux.

Nothing downstream of the RTL protects the two stages: they are two `reg`s named
`meta_q` and `sync_q` with no attribute. Whatever cell you put here, the flow has to
carry the protections a synchroniser needs, and the reference `synthesis.tcl` scripts
apply only the first of them:

- keep the hierarchy (`-no_autoungroup`, as above), so `u_*_sync/meta_q_reg` stays a
  stable name a CDC tool can be pointed at;
- `set_size_only` (or `set_dont_touch`) on `*/meta_q_reg*` and `*/sync_q_reg*`;
- no register merging, replication, retiming or multibit banking across them — a
  replicated `sync_q` is harmless for MTBF but breaks the "one synchroniser per
  crossing" identification the CDC tool relies on, and a `meta_q` banked with an
  unrelated flop is no longer a synchroniser cell;
- the timing exception on the crossing (`set_false_path` or `set_max_delay`) **to**
  `*/meta_q_reg*/D` from the source domain.

A post-compile count of `*/meta_q_reg*` equal to the RTL synchroniser count, and a
`report_timing -to */meta_q_reg*/D` on which every path carries an exception, are the
two checks.

Also keep in mind what this primitive is *not*: it crosses a **level**, one bit at a
time. Widening `W` synchronises W bits independently — it does not make them coherent.
No multi-bit payload in this library is carried by a wide `arv_synchronizer`; every
instance in the tree is `W = 1`. A payload crosses by one of two routes built on top,
and which one is a deliberate choice:

- **A level-toggle req/ack handshake** — only the two 1-bit levels are synchronised, and
  the handshake itself holds the payload stable across the crossing. `arv_dtm` uses this
  for the transport ↔ DMI crossing. It is self-protecting: it needs no timing exception,
  and a mistake shows up in simulation.
- **Data timing plus an SDC exception** — the payload register is allowed to move only at
  an instant when the far side is known to be settled, and `set_max_delay` holds the path
  to that budget. `ahb_aclint` uses this to carry MTIME and MTIMECMP across the LF
  boundary, where a handshake would cost an acknowledge path back through a clock that
  may be a thousand times slower, and would add reset-domain failure modes the counted
  scheme does not have. The trade-off is the reason to prefer a handshake when nothing
  forces the choice: this structure is **not** self-protecting, so a missing or wrong
  constraint fails silently in simulation and only shows up in silicon.

### Change the reset architecture

Every IP exposes a build-time parameter (`ASYNC_RST_EN` on the AHB IPs and
`arv_custom_csr`, `ARST_EN` on `arv_dtm` and the primitives themselves) that threads
down to `ARST_EN` on each primitive:

| `ARST_EN` | Reset style | Assertion |
|---|---|---|
| `1` (default) | asynchronous active-low | immediate, no clock required |
| `0` | synchronous | sampled on a clock edge |

The selection is not threaded everywhere. A flop that must record an event during an
interval in which its clock has no edges keeps an asynchronous reset in every build,
because a clock-sampled reset would never take effect: the synchronisers inside
`arv_reset_gen` (the POR arrives before the crystal runs), the preset inside
`arv_osc_ctrl` (the wake arrives while the oscillator is stopped), `arv_dtm`'s
probe-clock domain — the TAP, the cJTAG front end and the JTAG wake toggle, clocked
by a TCK the probe may stop — together with the TAP's `hclk` reset synchroniser, and
`ahb_aclint`'s trust-reset synchroniser (`aclint_lf_tick.v`, `u_trust_rstn_sync`).
Each of those is pinned at the instance (a literal `1'b1`, or a `localparam` fixed to
it) rather than threaded from the IP parameter, and that is the whole list.

If your flow needs a third style — reset-on-both-edges, retention flops, a scan-safe
reset mux — add it here as another parameter value rather than at the call sites.

### Swap in retention or special flops

`arv_ipdff` is the single point where every discrete sequential element in the
library is defined (the inferred memories named above are the technology-mapped
exception). Retention cells, multi-bit flops, or a library-specific enabled flop go
here. Preserve the port semantics below and nothing above needs to change.

## The contract

Edit freely, but these properties are relied on by the IPs above:

| Must hold | Why |
|---|---|
| `en_i = 0` holds `q_o` (`arv_ipdff`; in `arv_ipdff_sinit` `sinit_i` ranks above `en_i`) | used for load-enable logic everywhere, not just power |
| `arv_ipdff_sinit` priority is `rst_n_i` > `sinit_i` > `en_i` | its user re-initialises with the enable low |
| `RST_VAL` is the reset **and** `sinit_i` value | idle-high lines rely on it (see below) |
| `ARST_EN` selects the assertion style only — never the value, the enable or the priority | IPs are verified in both settings |
| `arv_synchronizer` keeps ≥ 2 stages, no mux on the last | MTBF |
| `arv_synchronizer` under `ARST_EN=0` reaches `RST_VAL` on the second edge; a synchronous reset spans ≥ 2 destination edges | the second stage is deliberately unreset (MTBF); a bench's reset must be held that long |
| `arv_cgate` output is glitch-free for any `en_i` | it drives real clocks |
| `arv_cgate.test_en_i` forces the clock on | scan chain continuity |
| `arv_and` / `arv_or` stay single identifiable cells | reset skew |
| `WIDTH`, `W`, `N` below 1 are a simulation-time `$fatal` | a zero width silently elaborates as a two-bit reversed range |

`RST_VAL` deserves particular attention on `arv_synchronizer`: an idle-**high** input
(a UART RX line, an I2C bus, a TMSC pad) must reset to `1`, or the conditioning comes
out of reset showing a phantom falling edge and the receiver decodes a start bit that
never happened. Both the UART and I2C front ends depend on this — it is why they need
no reset guard window.

### X propagation in simulation

The cells are written for synthesis, and their behaviour on unknown inputs in RTL
simulation is a by-product worth knowing when a bench misbehaves:

- Every flop arm and the asynchronous synchroniser arm test `if (!rst_n_i)`, so an
  unknown reset behaves as **released** and the flop loads `d_i` (the same
  X-optimism as the aRVern core's `arv_dff`). The synchronous synchroniser arm uses a
  ternary, which merges an unknown reset bitwise into `meta_q` instead.
- `if (en_i)` with an unknown enable **holds** — an undriven enable is invisible in
  RTL simulation.
- `arv_cgate`'s latch is a Verilog-2001 `always @(*)`, which does not run at time 0:
  `en_lat` is unknown until the first low phase of `clk_i`. A bench whose clock starts
  low and whose first move is a rising edge gets an unknown first high phase on
  `clk_o`, and a `0 → X` transition counts as a rising edge for every flop on it. It is
  harmless under an asserted reset, which is the only time it can happen.

## Reference

### `arv_ipdff` — enabled flip-flop

| Parameter | Default | Meaning |
|---|---|---|
| `WIDTH` | `1` | register width (≥ 1) |
| `RST_VAL` | `0` | reset value |
| `ARST_EN` | `1'b1` | `1` = async active-low, `0` = synchronous |
| `CLK_NEGEDGE` | `1'b0` | `0` = posedge, `1` = negedge |

Ports: `clk_i`, `rst_n_i`, `en_i`, `d_i[WIDTH-1:0]` → `q_o[WIDTH-1:0]`.

`CLK_NEGEDGE` exists for protocol logic that must update on the falling edge — the JTAG
TDO retime, for example. It is not a general-purpose knob. The four
`ARST_EN × CLK_NEGEDGE` arms are textually identical apart from the sensitivity list.

### `arv_ipdff_sinit` — flip-flop with synchronous re-init

`arv_ipdff` plus an active-high `sinit_i` that synchronously reloads `RST_VAL`, on top
of the primary reset. It lets a datapath-derived soft reset ride clock-sampled logic —
scannable and glitch-immune — instead of becoming a gated asynchronous reset.

Same parameters and ports as `arv_ipdff`, plus `sinit_i`. Priority is `rst_n_i` >
`sinit_i` > `en_i`: `sinit_i` reloads `RST_VAL` on the active edge whatever `en_i` is,
so "enable low holds" does not apply while it is asserted. Its user in the library
(`arv_dtm_cjtag`'s escape counter) depends on exactly that.

### `arv_synchronizer` — level CDC

| Parameter | Default | Meaning |
|---|---|---|
| `W` | `1` | width (≥ 1; each bit crosses independently) |
| `RST_VAL` | `0` | reset value; with `ARST_EN=1` on both stages, with `ARST_EN=0` on the first stage only (reaches `sync_o` on the second edge) |
| `ARST_EN` | `1'b1` | `1` = asynchronous reset on both stages; `0` = synchronous reset on the first stage — hold it for ≥ 2 `clk_i` edges |

Ports: `clk_i` (destination), `rst_n_i`, `async_i[W-1:0]` → `sync_o[W-1:0]`.

A change on `async_i` reaches `sync_o` on the second `clk_i` edge in either style.

### `arv_cgate` — integrated clock gate

Ports: `clk_i`, `en_i`, `test_en_i` → `clk_o`. No parameters.

`clk_o` follows an enable change only from the next low phase of `clk_i`: a change
while the clock is high neither truncates the current pulse nor starts a new one.
`test_en_i` is ORed into the enable before the latch, so it is glitch-free too.

### `arv_and` / `arv_or` — reset-network gates

| Parameter | Default | Meaning |
|---|---|---|
| `N` | `2` | number of inputs (≥ 1) |

Ports: `a_i[N-1:0]` → `z_o`. Reduction AND / OR, with no inversion inside the cell —
call sites invert (`~scan_mode_i`, `~warm_reset_i`), so a reset network built from
them has no hidden polarity.

Typical use is forcing a reset inactive during scan shift (`rst_n | scan_shift`) or
combining a power-on reset with a functional one — cases where the gate must not be
restructured. How to keep synthesis from doing so is in [Keep a cell out of
synthesis' hands](#keep-a-cell-out-of-synthesis-hands).

### `arv_reset_gen` — reference SoC reset generator

Not a technology cell like the six above: a small reference block assembled from
them, giving a platform the three resets an aRVern SoC needs from one raw
power-on reset. Each is **asserted asynchronously by the POR** and **released
through a synchroniser on the clock that samples it**, which is what the IPs
require of their reset inputs — none of them contains a reset synchroniser.

| Parameter | Default | Meaning |
|---|---|---|
| `LF_GATE_EN` | `1'b1` | `1` = hold `hresetn_o` until `resetn_lf_o` has released and crossed into `hclk_i`; `0` = `hresetn_o` does not wait for `resetn_lf_o`. The `clk_lf_i` synchroniser is built in both settings |

Ports: `porn_async_i`, `warm_reset_i`, `scan_mode_i`, `clk_lf_i`, `hclk_i` →
`resetn_lf_o`, `dbgresetn_o`, `hresetn_o`.

| Output | Sources | Released on | Release latency |
|---|---|---|---|
| `resetn_lf_o` | POR only | `clk_lf_i` | two `clk_lf_i` edges after `porn_async_i` rises |
| `dbgresetn_o` | POR only | `hclk_i` | two `hclk_i` edges after `porn_async_i` rises |
| `hresetn_o` | POR \| `warm_reset_i` | `hclk_i` | `LF_GATE_EN=0`: two `hclk_i` edges after `porn_async_i` rises. `LF_GATE_EN=1`: four `hclk_i` edges after `resetn_lf_o` rises (two per synchroniser). Warm: two `hclk_i` edges after `warm_reset_i` falls |

**The synchronisers are always asynchronous-reset, and there is no `ARST_EN`
parameter.** A reset generator exists to turn a clockless assertion into a clocked
release, and it has to record the POR while no clock is running — a crystal on
`clk_lf_i` may take far longer to start than a supervisor holds the POR. A
synchroniser with a clock-sampled reset clears only on clock edges: had the POR
released before `clk_lf_i` delivered two edges, its stages would keep their power-up
value and `resetn_lf_o` could rise the instant `porn_async_i` did, before the LF
domain had seen a single edge — the exact failure the block is there to prevent. The
block is therefore used unchanged in an `ASYNC_RST_EN=0` platform; every reset it
produces asserts asynchronously and releases on an edge, and the downstream flops
keep whatever style their IP was built with.

**`warm_reset_i` is synchronous to `hclk_i`, in both directions.** It enters
`u_sys_sync` as data, so `hresetn_o` falls two `hclk_i` edges after it rises and
rises two edges after it falls, and the pulse width is preserved: hold it for **at
least two `hclk_i` rising edges**, so that a synchronous-reset `arv_synchronizer`
downstream (which needs two edges of reset) is reset as well as the flops. A Debug
Module's `ndmreset` is a level set and cleared by separate DMI writes and meets this
by nature; a watchdog or a pin is where a pulse-shaper is needed. `warm_reset_i` never
reaches `resetn_lf_o`: a warm reset that also reset the low-frequency domain would
defeat the reason a real-time counter is put there — it has to stay monotonic across
one. The same argument keeps `dbgresetn_o` off the warm reset, so a Debug Module
survives the reset it issues.

**Why `resetn_lf_o` leads `hresetn_o`.** A reset synchroniser is a data
synchroniser fed a constant `1`, so its output cannot rise until its clock has
actually run — two `clk_lf_i` edges here, which is the "at least two `clk_lf_i`
edges" the ACLINT asks of `resetn_lf_i` (its [Resets](../../ahb_aclint/doc/ahb_aclint.md#resets)),
met by construction. Gating `hresetn_o` behind it turns three integration rules into
structure: the LF domain is initialised before any bus master can reach it; a
timebase read cannot stall on a clock that never started; and there is no window
where the bus is live while the LF domain is still in reset, which is when writes to
LF-domain state are accepted and then dropped. On a warm reset `resetn_lf_o` is
already high, so the gate costs nothing — warm reset still releases at `hclk_i` rate
and never waits on `clk_lf_i`.

**How the gate is built.** `resetn_lf_o` is a `clk_lf_i`-domain level and
`warm_reset_i` an `hclk_i`-synchronous one; they are not combined until both are in
the same domain. `resetn_lf_o` first crosses into `hclk_i` through its own
synchroniser (`u_lf_to_hclk`), then `~warm_reset_i` is ANDed with the synchronised
level, and that `hclk_i`-synchronous term feeds `u_sys_sync`, whose output is ANDed
with `porn_async_i` to make `hresetn_o`. Mixing the two before a synchroniser would put
an asynchronous level and a synchronous one on the same D pin: a warm reset arriving
as the LF release rose could produce a runt that the synchroniser captures as a
one-cycle release of `hresetn_o`. The cost of the separate crossing is two flops and
two `hclk_i` edges on the cold-boot release only.

The cost of the gate is a boot dependency: no `clk_lf_i`, no `hresetn_o`. That is
deliberate and **diagnosable rather than silent**, because `dbgresetn_o` is not gated
— a debugger still attaches and finds the hart held in reset. A platform that must
boot without its low-frequency source sets `LF_GATE_EN = 0` and takes the ordering
rules back as software requirements.

`LF_GATE_EN` changes only what `hresetn_o` waits for. The `clk_lf_i` synchroniser
(`u_lf_sync`) and `resetn_lf_o` are built in either setting, so `clk_lf_i` is a clock
domain to constrain in either setting; synthesis removes the synchroniser only when
`resetn_lf_o` has no consumer. That is the case in the one platform that instantiates
the block, the FPGA SoC
([`arvern_fpga.v`](https://github.com/Arvern-Silicon/arvern-soc/blob/main/fpga/alteral_de0_nano_soc/rtl/verilog/arvern_fpga.v)):
its ACLINT is built with `LF_SYNC_EN=1`, where nothing is clocked by `clk_lf_i` and
`resetn_lf_i` has no consumer, so it sets `LF_GATE_EN=0` to keep an unused
fabric-routed clock domain off the boot path. A platform with a real LF domain (`LF_SYNC_EN=0`)
wants the default.

`scan_mode_i` collapses every output to `porn_async_i` and takes `warm_reset_i` out
of the picture, so all three resets are controllable from one pin during test; the
synchroniser flops keep the pin as their asynchronous reset and are scanned like any
other. Declare the port a test-mode constant to the DFT flow, as the ACLINT document
shows for its own ([DFT](../../ahb_aclint/doc/ahb_aclint.md#dft)); tie it low
functionally.

### `arv_osc_ctrl` — reference oscillator controller

The second reference block. An IP clocked by an oscillator cannot notice that
its own clock stopped — there is no edge on which to notice — so it has to be
told, early enough to act while it still has a clock. That is the whole content
of this module:

| Edge | What moves |
|---|---|
| posedge N | `clk_en_o` falls — the announcement |
| posedge N+1 | `osc_en_o` falls — the oscillator stops |

Exactly one clock edge is delivered with `clk_en_o` already low. A consumer whose
flops carry synchronous resets needs precisely that edge to reach its reset
values before the clock disappears; with asynchronous resets the level alone
suffices and the edge costs nothing. Drive the ACLINT's `hclk_aon_en_i` from
`clk_en_o` and its port contract — *"de-asserted one edge before the clock
stops"*
([`hclk_aon_en_i`](../../ahb_aclint/doc/ahb_aclint.md#hclk_aon_en_i--telling-the-ip-its-clock-is-going-away))
— is met by construction rather than by the integrator reading a document.

A request that arrives **inside** that window cancels the stop instead of being
stranded by it: the second flop sees `enable_i` directly, not just a delayed copy
of the announcement. Without that, a clock request landing one edge after the stop
decision would still stop the oscillator — and nothing could restart it, because
there is no longer an edge to sample `enable_i` with, leaving `clk_en_o` high over
a dead clock. A stop that is seen through is unaffected: with `enable_i` low at
both edges the sequence is identical.

Ports: `osc_clk_i` (the oscillator's own output, fed back), `resetn_i`,
`scan_mode_i`, `wake_i`, `enable_i` → `clk_en_o`, `osc_en_o`. No parameters.

**The preset.** `resetn_i` low or `wake_i` high presets both flops to 1 — the
oscillator runs — **asynchronously**, and `ARST_EN` is fixed at 1 inside,
deliberately: a wake arrives exactly when the oscillator is stopped, so there is no
clock to sample it with, and a synchronous preset would never take effect. This is
the same reasoning that pins `arv_reset_gen`'s synchronisers, `arv_dtm_jtag`'s wake
toggle and `ahb_aclint`'s trust-reset synchroniser to an asynchronous reset. The
preset **asserts directly from that condition and is released through a two-flop
synchroniser on `osc_clk_i`**: the synchroniser is set while the condition holds and
clears two `osc_clk_i` edges after the later of `resetn_i` rising and `wake_i`
falling, so the release is timed like any reset's rather than landing anywhere in the
flops' recovery window. Because the condition itself asserts the preset, the preset
net falls with it whatever state the synchroniser powers up in. During those two edges both flops hold 1, and the first edge at
which `enable_i` can be sampled is the third — an oscillator woken and immediately
released runs two edges longer than it otherwise would, which nothing observes.

**The wake contract.** Once `osc_en_o` has fallen there is no edge left, and
`enable_i` can never restart the oscillator. Two rules follow for the integrator:

- **Every wake source must reach `wake_i`** — it is the OR of all wake requests. A
  source wired to `enable_i` only, such as an external interrupt during osc-off
  sleep, is lost. The ACLINT's `mtimer_wake_lf_o` is one such source, not the only
  one a SoC has.
- **`wake_i` is a level, held until the woken consumer has raised `enable_i`.** A
  pulse restarts the oscillator, the preset releases, `announce` samples `enable_i`
  low and the clock stops again — two edges of preset plus the two-edge stop
  sequence after a wake that nobody claimed. While `wake_i` is high the block ignores
  `enable_i` and the oscillator cannot stop, which is what the ACLINT relies on under
  `LF_SYNC_EN=1` (it holds the wake asserted so the counter's clock is never taken
  away). The ACLINT's wake is a level held until MTIMECMP is rewritten, so both
  benches meet the rule by property; a pulse-shaped wake needs a latch in front of
  this port.

**Which reset `resetn_i` is.** The raw POR (`arv_reset_gen`'s `porn_async_i`), or any
reset derived from it. Assertion is asynchronous, so a reset released through a
synchroniser that itself runs on this oscillator is not circular: the preset starts
the clock, the clock releases the reset, the reset releases the preset. A warm reset
need not reach it; if one does, it simply restarts a stopped oscillator, since reset
means run. The `arvern` core bench
([`tb_arvern.v`](https://github.com/Arvern-Silicon/arvern/blob/main/bench/verilog/tb_arvern.v))
drives it with the raw POR; the `ahb_aclint` bench drives it with `hresetn`, POR and
warm together. Both are valid SoCs.

`enable_i` is sampled on `osc_clk_i` and must be stable in that domain; `wake_i`
is asynchronous by nature and enters as a preset, not as a datapath input.

`scan_mode_i` takes `wake_i` — a scanned flop in the consumer, toggling freely during
shift — out of the preset, and masks the synchroniser's output, which is scan data
itself, so the two flops are never preset from the chain: in test mode their preset
is held inactive and they are loaded through the chain alone, while the synchroniser
flops keep `resetn_i` as their asynchronous reset, controllable from the pin. Declare the port a test-mode constant
to the DFT flow; tie it low functionally, as both benches do.

The oscillator itself is *not* here: `bench/verilog/osc.v` models one, and does
nothing but toggle while `en_i` is high, sampling `en_i` once per period at the end of
the low phase — half a period after the controller's flops move, so the two never
race. It treats an unknown `en_i` as "run", which lets the controller's flops resolve
out of their power-up X over the first edges before any reset. A bench that wants a
defined start drives `resetn_i` high at time 0 and low shortly after: in a two-state
simulator such as Verilator every flop powers up at 0 and an asynchronous preset acts
only on an edge, so a reset held low from time 0 never presets the flops and the
oscillator never starts. Keeping the two apart is what lets the
stop sequence be real RTL that an integrator lifts into a SoC, while the part that
cannot be synthesised stays in the bench.

## Verification

The library has its own regression under `sim/rtl_sim/`, run with **Icarus
Verilog**; **Verilator** lints every module, and the `arvern` core bench runs
`arv_osc_ctrl` under Verilator as its clock source. The IPs above exercise the cells again in
every build of their own regressions, in both reset styles.

### Bench

There is no shared testbench: each test in `sim/rtl_sim/src/<test>.v` is a
self-checking top module that instantiates the cells or the reference block it
targets, drives them from `initial` blocks, counts failed conditions in `error`
through `chk(cond, msg)` and prints `SIMULATION PASSED` when the count is zero.
`bench/verilog/timescale.v` sets the timescale and `bench/verilog/osc.v` is the
gateable oscillator the `arv_osc_ctrl` test runs on; the `arv_reset_gen` test makes
its own two stoppable clocks, `hclk_i` at 10 ns and `clk_lf_i` at 290 ns, asynchronous
to each other. `-D` defines on the `runsim` command line select a test's build
(`reset_gen_sequence` takes `LF_GATE=0|1`).

### Tests

| Test | What it pins | Builds |
|---|---|---|
| `cells_contract` | Every parameter arm of `arv_ipdff` and `arv_ipdff_sinit` (`ARST_EN × CLK_NEGEDGE`, including the sync-negedge arms no IP elaborates): asynchronous arms reset at once, synchronous arms on their active edge, `RST_VAL`, load on the active edge only, enable-low hold; `arv_ipdff_sinit` priority reset > `sinit_i` > `en_i`. `arv_synchronizer` in both styles: the synchronous reset reaches `sync_o` on the second edge, a change crosses in two edges. `arv_cgate`: no pulse while the enable is low, an enable change during the high phase neither starts nor truncates a pulse, `test_en_i` forces the clock on. `arv_and` / `arv_or` over every input value. | one |
| `reset_gen_sequence` | `arv_reset_gen`: POR asserted with no clock running and released before the LF clock ever starts (`dbgresetn_o` releases on `hclk_i`, `resetn_lf_o` waits for two `clk_lf_i` edges, `hresetn_o` waits or not per `LF_GATE_EN`); warm pulses of 1, 2 and 10 `hclk_i` cycles; a warm reset with the LF clock stopped; POR re-asserted mid-run; a warm reset held across the cold-boot LF release at several offsets; scan mode with clocks running and stopped. Monitors on every output: never X after the first POR, releases only on an edge of the output's own clock, `resetn_lf_o` and `dbgresetn_o` fall only with the POR, `hresetn_o` never releases with a warm reset seen at either of the last two edges nor (gate on) before `resetn_lf_o`. | `LF_GATE=1`, `LF_GATE=0` |
| `osc_ctrl_sequence` | `arv_osc_ctrl` against `osc.v`: exactly one edge between the announce and the stop, on every stop; an asynchronous wake restarts a stopped oscillator with no clock; the request held keeps it running; the preset holds for two edges after the wake falls and the oscillator then stops; a request inside the announce window cancels the stop; in scan mode a wake does not restart it. | one |

The tests are the source of truth for the timing figures in the reference sections
above; the RTL-level rules they cannot see are stated as such (`scan_mode_i`'s mask
at the preset synchroniser's reset is a DFT property with no simulation signature).

What the IP regressions add: the posedge arms of both flops and the synchroniser in
both reset styles; the async negedge arms through `arv_dtm`'s JTAG and cJTAG
transports; `arv_osc_ctrl` through the `ahb_aclint` and `arvern` benches, whose
deep-sleep tests (`mtimer_deep_sleep`, `mtimer_cmp_sleep_hold`,
`trap_irq_aclint_wfi_wake`) cover the announce, the stop and the asynchronous wake in
both reset styles; `arv_cgate` through the `arv_scope` bench. `arv_reset_gen`'s
`LF_GATE_EN=0` build is elaborated by the FPGA SoC; the default `LF_GATE_EN=1` arm is
covered by `reset_gen_sequence` and by lint alone. After editing a cell, run this
regression and then the dependent IPs.

### Lint

```bash
cd sim/rtl_sim/run
./run_lint                  # Verilator --lint-only -Wall, every module as its own top
```

`run_lint` elaborates each of the eight modules as a top, `arv_reset_gen` in both
`LF_GATE_EN` settings. `waivers.vlt` waives `arv_cgate`'s intentional latch and
nothing else; any flow that elaborates the cell needs the same waiver. The FuseSoC
`lint` target of `arv_primitives.core` elaborates `arv_synchronizer` only — it is a
dependency check for the IPs that `depend:` on the library, not the library's lint:

```bash
fusesoc --cores-root . run --target=lint arvern:ips:arv_primitives:1.0.0
```

### Running

```bash
cd sim/rtl_sim/run
./run_all                                    # every test, one PASS/FAIL line each and a total
../bin/runsim cells_contract                 # one test
../bin/runsim reset_gen_sequence LF_GATE=0   # one test with a build define
```

`runsim` compiles the whole RTL directory, `osc.v` and the test with Icarus
(`-g2005 -Wall`) into `simv` and runs it; a test passes when its output contains
`SIMULATION PASSED`, and `run_all` exits non-zero if any does not.

## License

BSD 3-Clause — see [`LICENSE`](../../LICENSE) at the repository root.
