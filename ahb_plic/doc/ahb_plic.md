<p align="center">
  <img src="../../arv_custom_csr/doc/img/aRVern_light.png" alt="aRVern" width="180">
</p>

# Platform-Level Interrupt Controller (AHB-Lite)

*RISC-V PLIC with per-hart M and S contexts for routing platform interrupts to aRVern cores.*

---

## Contents

- [Overview](#overview)
  - [Design parameters](#design-parameters)
  - [Module hierarchy](#module-hierarchy)
- [Programming model](#programming-model)
  - [Address map](#address-map)
  - [Context numbering](#context-numbering)
  - [Priority window](#priority-window)
  - [Pending window](#pending-window)
  - [Enable window](#enable-window)
  - [Target window](#target-window)
  - [Access control](#access-control)
  - [Level-triggered gateway](#level-triggered-gateway)
  - [Per-context arbiter](#per-context-arbiter)
  - [Claim / Complete handshake](#claim--complete-handshake)
- [Integration](#integration)
  - [Port summary](#port-summary)
  - [Clock gating](#clock-gating)
  - [Integration requirements](#integration-requirements)
- [Verification](#verification)
  - [Scoreboard and coverage gate](#scoreboard-and-coverage-gate)
  - [Configurations](#configurations)
  - [Tests](#tests)
  - [Signoff gates](#signoff-gates)
  - [Lint conventions](#lint-conventions)
  - [Core-level tests](#core-level-tests)
- [Synthesis](#synthesis)
- [Repository layout](#repository-layout)
- [License](#license)

---

## Overview

The **`ahb_plic`** module implements the RISC-V **PLIC** (Platform-Level
Interrupt Controller) specification, version 1.0.0, as a single AHB-Lite
subordinate. It routes up to `NUM_SOURCES` level-triggered interrupt
lines into per-hart **M-mode** and (with `SU_MODE_EN=1`) **S-mode**
interrupt outputs that connect to the aRVern core's `irq_m_external_i` /
`irq_s_external_i` pins (`mip.MEIP` / `mip.SEIP`).

The register layout is the specification's memory map (PLIC 1.0.0
Chapter 3); the context-to-hart assignment, which the specification
leaves to the platform, is `ctx = 2*hart + s_mode` (see
[Context numbering](#context-numbering)). Every register is a 32-bit word
accessed with word transfers only.

The IP lives entirely in the `hclk_i` clock domain and contains no
synchroniser; foreign-clock interrupt sources are synchronised by the
integrator, on the clock named in
[Integration requirements](#integration-requirements).

### Design parameters

| Parameter         | Default | Range        | Purpose |
|-------------------|---------|--------------|---------|
| `NUM_SOURCES`     | `31`    | `1..1023`    | Number of usable interrupt sources. Source ID 0 is reserved by the specification (no interrupt); usable IDs are `1..NUM_SOURCES`. The default keeps all pending and enable bits in one 32-bit word. |
| `NUM_HARTS`       | `1`     | `1..16`      | Number of harts. Match `ahb_aclint`'s `NUM_HARTS`. `NUM_HARTS ≤ 16` keeps `NUM_CONTEXTS ≤ 32`, the capacity of the 4 KB enable window. |
| `SU_MODE_EN`      | `0`     | `0` or `1`   | Instantiate a per-hart S-mode context. Match the core's `SU_MODE_EN` (same default). When `0`, contexts are numbered `ctx = hart`, context indices `>= NUM_HARTS` are RAZ/WI and `irq_s_external_o` is tied `0`. |
| `PRIO_BITS`       | `3`     | `1..7`       | Priority width per source; `2^PRIO_BITS - 1` is the highest priority. `PRIO_BITS=1` is a two-level "enabled / disabled" mode for area-sensitive integrations. |
| `PRIV_CHECK_EN`   | `1`     | `0` or `1`   | IP-level privilege filter using `hprot_i[1]` + `hsmode_i`, policy in [Access control](#access-control). When `0`, the privilege check is skipped (the integrator relies on a fabric-level check); the size check stays active. |
| `ASYNC_RST_EN`    | `1`     | `0` or `1`   | Reset style: `1` = asynchronous active-low assertion, `0` = synchronous. Threaded to every flop through the shared `arv_ipdff` primitive; see [`README.md`](../../README.md#reset-architecture). |

> **Parameter ranges are the contract.** Simulation and lint reject an
> out-of-range value with `$fatal`; **synthesis does not** — the guards are
> under `translate_off` and no value is clamped, so an illegal value builds
> a broken netlist silently (contexts alias in the enable decode above
> `NUM_HARTS=16`; no priority register is writable at `NUM_SOURCES=1024`).
> The integrator must respect the ranges.

### Module hierarchy

```
ahb_plic
├── plic_priority        priority register file [1..NUM_SOURCES] x PRIO_BITS
├── plic_pending         pending + in_service flops, level-triggered gateway
├── plic_enable          per-context enable matrix [NUM_CONTEXTS][NUM_SOURCES]
└── plic_target          per-context block (instantiated NUM_CONTEXTS times)
                         — threshold reg + arbiter + claim/complete pulses
```

`NUM_CONTEXTS` is computed internally as
`SU_MODE_EN ? 2*NUM_HARTS : NUM_HARTS`. The three storage sub-blocks
(`plic_priority`, `plic_pending`, `plic_enable`) are instantiated once
each; `plic_target` is instantiated in a `generate` loop, one per
context — `NUM_HARTS` M-contexts when `SU_MODE_EN=0`, `2*NUM_HARTS`
contexts alternating M/S per hart when `SU_MODE_EN=1`. Every sub-block
answers in one cycle (`reg_ready_o` tied high), so every accepted
transfer completes with zero wait states.

---

## Programming model

### Address map

The subordinate occupies a **4 MB window** (22-bit byte address): a slice
of the specification's memory map large enough for the 32 contexts the IP
can implement. The implemented register footprint is much smaller;
everything else in the window is RAZ/WI for M- and S-mode masters
(U-mode is denied everywhere in the window, see
[Access control](#access-control)).

| Offset                          | Window                             | Notes |
|---------------------------------|------------------------------------|-------|
| `0x000000 + 4*src`              | **Priority** (4 KB)                | one word per source |
| `0x001000 + 4*w`                | **Pending** (4 KB)                 | one bit per source, 32 sources per word, read-only |
| `0x002000 + 0x80*ctx + 4*w`     | **Enable** (4 KB, `0x002000`–`0x002FFF`; 128 bytes per context) | same packing as pending |
| `0x200000 + 0x1000*ctx`         | **Target[ctx]** (8 bytes used)     | `+0` threshold, `+4` claim/complete |
| outside the above               | reserved                           | RAZ/WI (M and S; U-mode is denied) |

`haddr_i[1:0]` is ignored: word transfers are assumed aligned, as
AHB-Lite requires. A protocol-violating misaligned word address lands on
its containing word with OKAY.

**Reset values.** Every register resets to 0: priorities, enables,
thresholds, pending and in-service bits. No interrupt output is asserted
after reset until firmware programs a non-zero priority and an enable. A
source line already high when reset is released pends on the first clock
edge after it. With `ASYNC_RST_EN=0` the flops take these values on the
first `hclk_i` edge while reset is asserted, so every output is defined
from that edge on; the clock must run during reset (see
[Clock gating](#clock-gating)).

**When a write takes effect.** A register write commits on the clock edge
that ends its data phase. The data phase of the next transfer already
reads the new value, and `irq_*_external_o` reflects it from that edge.

### Context numbering

| `SU_MODE_EN` | Context index `ctx`                 | Number of contexts |
|--------------|-------------------------------------|--------------------|
| `1`          | `ctx = 2*hart + s_mode` (M=0, S=1)  | `2 * NUM_HARTS`    |
| `0`          | `ctx = hart`                        | `NUM_HARTS`        |

With `SU_MODE_EN=1, NUM_HARTS=1`: ctx 0 = hart 0 M-mode, ctx 1 = hart 0
S-mode. With `SU_MODE_EN=1, NUM_HARTS=2`: hart0/M, hart0/S, hart1/M,
hart1/S. With `SU_MODE_EN=0, NUM_HARTS=2`: ctx 0 = hart0/M, ctx 1 =
hart1/M; ctx 2 and above are RAZ/WI.

Context indices `>= NUM_CONTEXTS` have no enable block and no target
stride: those offsets are RAZ/WI.

### Priority window

One `PRIO_BITS`-wide priority register per source, in the low bits of a
32-bit word at byte offset `4*src`. Bits above `PRIO_BITS-1` are RAZ/WI.

| Offset               | Register                          | Bits |
|----------------------|-----------------------------------|------|
| `0x0000`             | `priority[0]` — reserved          | RAZ/WI |
| `0x0004`             | `priority[1]`                     | `[PRIO_BITS-1:0]` |
| `4*src`              | `priority[src]` (src = 1..NUM_SOURCES) | (same) |
| `4*(NUM_SOURCES+1)` and above | reserved                 | RAZ/WI |

Priority 0 = "never interrupt" (PLIC 1.0.0 Chapter 4); priority 1 is the
lowest active level and `2^PRIO_BITS - 1` the highest. A source at
priority 0 neither interrupts nor wins a claim — see
[Per-context arbiter](#per-context-arbiter).

### Pending window

Pending bits packed 32 sources per word, **read-only** (writes are
accepted with OKAY and ignored). Bit `b` of word `w` is source
`32*w + b` (PLIC 1.0.0 Chapter 5); bit 0 of word 0 (source 0) reads 0,
as do all bits above `NUM_SOURCES`.

| Offset                                  | Word              | Bits |
|-----------------------------------------|-------------------|------|
| `0x1000`                                | pending word 0    | `[0]` = source 0 (always 0), `[1]` = source 1, … |
| `0x1004`                                | pending word 1    | `[0]` = source 32, … |
| `0x1000 + 4*w`                          | pending word `w`  | (same packing) |
| `0x1000 + 4*ceil((NUM_SOURCES+1)/32)` and above | reserved  | RAZ/WI |

A pending bit is set by the gateway and cleared only by a claim: the
only way to clear `pending[s]` is a claim by a context that has the
source enabled (Chapter 5: "A pending bit in the PLIC core can be
cleared by setting the associated enable bit then performing a claim").
A claim returns only a source of non-zero priority, so the pending bit of
a source at priority 0 stays set until its priority is raised and it is
claimed. The source line dropping never clears it.

### Enable window

Per-context enable bits, packed 32 sources per word like the pending
window. Each context owns a 128-byte block (32 words). Bit 0 of word 0
(source 0) is RAZ/WI in every context: the specification defines the
bit, the IP hard-ties it to 0 since no interrupt can arrive on source 0.

| Offset                                                | Register              | Notes |
|-------------------------------------------------------|-----------------------|-------|
| `0x2000 + 0x80*ctx + 4*w`                             | `enable[ctx][word w]` | RW, `[b]` = source `32*w + b` |
| `0x2000 + 0x80*ctx + 4*w`, `w >= ceil((NUM_SOURCES+1)/32)` | reserved         | RAZ/WI |
| `0x2000 + 0x80*ctx + …`, `ctx >= NUM_CONTEXTS`        | reserved              | RAZ/WI |

### Target window

Each context owns a 4 KB-strided block holding its threshold and its
claim/complete register. Only the first 8 bytes are used; the rest of
the stride is RAZ/WI.

| Offset                          | Register              | Behaviour |
|---------------------------------|-----------------------|-----------|
| `0x200000 + 0x1000*ctx + 0x0`   | `threshold[ctx]`      | RW, `PRIO_BITS` wide (upper bits RAZ/WI). The context is notified only of sources whose priority is **strictly greater** than the threshold; `threshold = 2^PRIO_BITS - 1` masks every source. |
| `0x200000 + 0x1000*ctx + 0x4`   | `claim_complete[ctx]` | **Read = claim**: returns the ID of the highest-priority pending-and-enabled source for this context, or 0 if there is none — independent of the threshold (Chapter 8) — and on the same clock edge sets `in_service[id]` and clears `pending[id]`. **Write = complete**: a write is a completion only when the **whole 32-bit word** is an ID in `1..NUM_SOURCES` (any bit above `[10]` set makes it invalid, not an alias of its low bits) **and** that source is enabled for this context (Chapter 9); it then clears `in_service[N]`. Any other write is ignored with OKAY. |
| other offsets in the stride     | reserved              | RAZ/WI |

> **Claim atomicity.** The claim read returns its ID and performs the
> `in_service[id] ← 1` / `pending[id] ← 0` update on the same clock edge,
> the one that completes the AHB data phase. There is no intermediate
> state: the next bus cycle observes both the returned ID and the cleared
> pending bit.

### Access control

Two orthogonal checks are applied to every transfer; either failing
denies the access with a two-cycle AHB ERROR response.

**Access size (always enforced).** PLIC 1.0.0 Chapter 3: *"The
memory-mapped registers specified in this chapter have a width of
32-bits. The bits are accessed atomically with LW and SW instructions."*
Only word transfers (`hsize_i = 3'b010`) are accepted; a byte, halfword,
double-word or wider transfer is denied, whatever `PRIV_CHECK_EN` says. This
catches a wrongly sized store early instead of silently committing part
of a register. `HBURST` is not an input: bursts of word transfers are
accepted beat by beat, each beat landing exactly as a single transfer
would; a beat is denied only when it is not word-sized or fails the
privilege filter.

**Privilege filter (`PRIV_CHECK_EN=1`).** Defence in depth on top of any
fabric-level policy: a misbehaving master cannot corrupt PLIC state even
if the fabric's decoder lets it through. The privilege of a transfer is
decoded from `hprot_i[1]` and `hsmode_i` (the aRVern AHB dialect):

| `hprot_i[1]` | `hsmode_i` | Privilege |
|--------------|------------|-----------|
| 1            | 0          | M-mode    |
| 1            | 1          | S-mode    |
| 0            | x          | U-mode    |

| Window                                    | M-mode | S-mode | U-mode |
|-------------------------------------------|:------:|:------:|:------:|
| Priority                                  | RW     | RW     | DENY   |
| Pending                                   | RO²    | RO²    | DENY   |
| Enable block of an M-context              | RW     | DENY¹  | DENY   |
| Enable block of an S-context              | RW     | RW     | DENY   |
| Target of an M-context (offsets `+0`, `+4`) | RW   | DENY¹  | DENY   |
| Target of an S-context                    | RW     | RW     | DENY   |
| Reserved / unmapped offsets               | RAZ/WI | RAZ/WI | DENY   |

¹ The S-mode deny mask is the whole 128-byte enable block of every
M-context and the first 8 bytes of every M-context's 4 KB target stride,
including words that hold no register. Context indices `>= NUM_CONTEXTS`
are RAZ/WI for M and S alike, so an S-mode master can learn the number
of contexts by probing, but not the number of sources.

² A write to the pending window completes with OKAY and is ignored.

When `SU_MODE_EN=0` every context is an M-context, so an S-mode master
is denied the enable block and target of every implemented context (it
can still read priority and pending). U-mode is denied everywhere in the 4 MB window,
reserved offsets included. When `hsmode_i` is tied `0` (a fabric without
the `HAUSER` sideband) every privileged access decodes as M and the
S-mode column collapses onto the M-mode column — see
[Integration requirements](#integration-requirements).

**Disabling the filter.** Set `PRIV_CHECK_EN=0` if the fabric already
enforces a privilege policy at its address decoder, or if the integration
has no privilege control. `hprot_i` and `hsmode_i` remain inputs (wire
them up) but do not take part in the decision. **The size check remains
active.**

**Denial behaviour.** A denied access — wrong size or privilege
violation — produces the AHB-Lite two-cycle ERROR response:

| Cycle               | `hreadyout_o` | `hresp_o` |
|---------------------|:-------------:|:---------:|
| Data phase, cycle 1 | 0 (stall)     | 1 (ERROR) |
| Data phase, cycle 2 | 1 (release)   | 1 (ERROR) |

Throughout the denied data phase the addressed sub-block is deselected:
a denied write reaches no register, a denied claim read claims nothing,
and a denied read returns `hrdata_o = 0`. An address phase held through
the first ERROR cycle is captured in the second and then completes
normally. An aRVern hart reports the ERROR response as a **resumable
NMI** (`mncause = 0x80000003`, faulting address in `marv_eaddr`) — never
as a synchronous access fault (`mcause` 5 and 7 come from the core's PMP
checkers only) — so misbehaving firmware is put on notice instead of
corrupting PLIC state silently.

### Level-triggered gateway

Each source `s` in `1..NUM_SOURCES` has two state bits in `plic_pending`:

- `pending[s]` — set on any `hclk_i` edge at which `irq_src_i[s]` is
  high and `in_service[s] = 0`; cleared only by a claim of `s`.
- `in_service[s]` — set by a claim of `s`, cleared by an accepted
  completion of `s`.

```
pending[s]    <= claim of s                 ? 0
               : irq_src_i[s] & ~in_service[s] ? 1
               :                              pending[s];
in_service[s] <= claim of s                 ? 1
               : accepted complete of s     ? 0
               :                              in_service[s];
```

Consequences:

- A level held high across one rising edge of the free-running clock
  (both edges synchronous to it, see
  [Integration requirements](#integration-requirements)) is latched into
  `pending[s]` and survives the line dropping — firmware still sees the
  interrupt, and the handler has to discover that the device no longer
  needs service (PLIC 1.0.0 §1.2).
- While `in_service[s] = 1` the line is ignored. If it is still high
  when the completion is accepted, `pending[s]` sets again on the next
  edge and the source is delivered again — the specification's
  level-triggered re-trigger rule (§1.2).
- Every source is level-triggered; there is no edge-triggered mode.

`irq_*_external_o` is combinational from the pending, enable, priority
and threshold flops, with no path from `irq_src_i`: it asserts after the
first `hclk_i` edge at which `irq_src_i[s]` is sampled high, and drops
after the edge that completes the claim read (unless another source
qualifies).

### Per-context arbiter

`plic_target` selects over the sources twice; ties go to the lowest ID
(PLIC 1.0.0 §1.4):

- **Claim arbiter** — the highest-priority source of `pending & enable &
  priority != 0`, threshold **not** applied. Drives the claim read data and
  the claim pulse.
  Chapter 8: *"the claim operation is not affected by the setting of the
  priority threshold register."*
- **Notification** — whether any source of the same set also has
  `priority > threshold`. Drives `irq_*_external_o`. Chapter 7: the
  threshold masks every source of priority less than or equal to it
  (strict `>`).

A source at priority 0 is neither claimable nor notified, at any threshold.
Source 0 is excluded by construction (priority, pending and enable all
hard-tied 0). When nothing qualifies the claim arbiter, a claim read
returns 0.

Area scales with `NUM_CONTEXTS × NUM_SOURCES`. The claim arbiter is a
binary tree of priority compares, so its logic depth grows with
`log2(NUM_SOURCES + 1)`, not with the source count; the interrupt output of
each context is an OR-reduce over the sources that qualify above its
threshold. `hclk_en_o` is a separate OR-reduce over the sources.

### Claim / Complete handshake

A read of `claim_complete[ctx]`:

1. The data phase returns the claim arbiter's winner for `ctx`,
   zero-extended to 32 bits (0 if none).
2. On the clock edge completing the data phase, `plic_target` pulses the
   claim with that ID and `plic_pending` applies it:
   `in_service[id] ← 1`, `pending[id] ← 0`.

A write of `claim_complete[ctx]` with data `N`:

1. `plic_target` accepts the completion only when the whole word `N` is
   in `1..NUM_SOURCES` **and** `enable[ctx][N] = 1`. Chapter 9: *"If the
   completion ID does not match an interrupt source that is currently
   enabled for the target, the completion is silently ignored."*
2. An accepted completion pulses `plic_pending`: `in_service[N] ← 0` on
   the edge that ends the write's data phase. Anything else changes no
   state and completes with OKAY.
3. If source `N`'s line is still high, `pending[N]` sets on the following
   edge. A claim in the transfer immediately after the completion does not
   see it yet (it returns another source, or 0); a claim one cycle later
   does.

Per-context claim and complete pulses are OR-combined at the top before
`plic_pending`. The combine is lossless: the target decode is an equality
on the context field of the address, so exactly one `plic_target` is
selected per transfer, and AHB-Lite carries one data phase at a time.
Two contexts that both want the same source are therefore serialised by
the bus: the first claim wins, the second read returns the next
pending-and-enabled source for that context, or 0 if there is none.

> **Multicast and the shared in-service bit.** A source may be enabled
> for several contexts (the specification's multicast, §1.3): all of them
> are notified, the first claim wins, the others find the source no
> longer pending. The single `in_service[s]` bit per source is the
> specification's per-source gateway state. The hazard is a context
> completing an ID it did not receive from its own claim — the
> specification does not check this (Chapter 9) — which clears
> `in_service[s]` under the claimer's handler and lets the gateway
> re-pend the source while it is still being serviced. **A handler must
> complete only the ID its own claim returned.** For M-supervises-S
> delegation, the simplest arrangement is to enable the source only on
> the S-context and deliver it through `mideleg.SEI=1`.

> **Complete before disabling.** A completion for a source that is not
> enabled for the completing context is ignored (Chapter 9). If a handler
> clears `enable[ctx][N]` between its claim and its completion of `N`,
> the completion is dropped and `in_service[N]` stays set: source `N`
> cannot interrupt again until an accepted completion clears it, which
> requires re-enabling it first. Complete first, then disable.

---

## Integration

### Port summary

| Direction | Port                 | Width           | Description |
|-----------|----------------------|-----------------|-------------|
| in        | `hclk_i`             | 1               | AHB clock; gated by the SoC from `hclk_en_o`, see [Clock gating](#clock-gating) |
| in        | `hresetn_i`          | 1               | Active-low reset. Assertion is asynchronous with `ASYNC_RST_EN=1` (default) and synchronous with `ASYNC_RST_EN=0`; the de-assert edge is synchronised to `hclk_i` by the integrator |
| in        | `hsel_i`             | 1               | AHB-Lite subordinate select |
| in        | `haddr_i`            | 22              | Byte address inside the 4 MB window (the fabric decodes the upper bits); `[1:0]` ignored |
| in        | `hwrite_i`           | 1               | Write enable |
| in        | `hsize_i`            | 3               | Transfer size; anything but word (`3'b010`) is denied, see [Access control](#access-control) |
| in        | `htrans_i`           | 2               | Transfer type. NONSEQ and SEQ start an access; IDLE and BUSY receive a zero-wait OKAY and have no effect, whatever `hsize_i` / `hprot_i` carry. `HBURST` is not an input |
| in        | `hprot_i`            | 4               | AHB-Lite protection. `[1]`: 1 = privileged, 0 = unprivileged; the other bits are ignored. Used only with `PRIV_CHECK_EN=1` |
| in        | `hsmode_i`           | 1               | aRVern privilege sideband (`HAUSER`). With `hprot_i[1]=1`: 0 = M-mode, 1 = S-mode; don't-care otherwise. Used only with `PRIV_CHECK_EN=1` |
| in        | `hready_i`           | 1               | Bus ready in (the fabric's `HREADY`), see [Integration requirements](#integration-requirements) |
| in        | `hwdata_i`           | 32              | Write data |
| out       | `hrdata_o`           | 32              | Read data; 0 on a denied read |
| out       | `hreadyout_o`        | 1               | `1` except in the first cycle of an ERROR response; `1` during reset |
| out       | `hresp_o`            | 1               | `1` for both cycles of the ERROR response of a denied access |
| in        | `irq_src_i`          | `NUM_SOURCES+1` | Interrupt source levels; bit `[s]` is source `s`, bit `[0]` is reserved and ignored |
| out       | `irq_m_external_o`   | `NUM_HARTS`     | M-mode external interrupt per hart (core `irq_m_external_i`) |
| out       | `irq_s_external_o`   | `NUM_HARTS`     | S-mode external interrupt per hart (core `irq_s_external_i`); tied `0` when `SU_MODE_EN=0` |
| out       | `hclk_en_o`          | 1               | Combinational clock-gate request: high when the IP needs an `hclk_i` edge. Drives the SoC-side ICG |

`hresp_o`, `hreadyout_o` and `hrdata_o` are functions of flops only;
there is no combinational path from an AHB input to an AHB output.

### Clock gating

`hclk_en_o` is a **combinational** request meaning "the PLIC needs an
`hclk_i` edge". It is high whenever an `hclk_i`-domain flop may have to
update:

- an address phase is selecting this subordinate
  (`hsel_i & hready_i & htrans_i[1]`) — the data-phase state is about to
  be captured;
- a data phase is in flight — register writes, the claim and complete
  pulses and the ERROR response all advance in that cycle;
- the gateway is about to set a pending bit: some source `s` in
  `1..NUM_SOURCES` has `irq_src_i[s] & ~in_service[s] & ~pending[s]`.
  This is the only transition that is not bus-driven, and the reason the
  wake path must stay outside the gated domain (see
  [Integration requirements](#integration-requirements)).

It is low in every stable state, including `pending = 1` with the source
still asserted (the arbiters that drive `irq_*_external_o` are
combinational from flops and need no clock) and `in_service = 1` waiting
for the completion write (which raises `hclk_en_o` through the
address-phase term when the master presents it). A source rising into a
quiescent PLIC raises `hclk_en_o` combinationally; the next free-running
edge latches `pending` and `irq_*_external_o` asserts. The core wakes from
WFI on its own live sampling of that pin; **`hclk_en_o` opens only the
PLIC's gate**, not the core's.

Wire `hclk_en_o` into a latch-based ICG cell whose enable is captured by
a latch transparent while the clock is low. Do **not** AND `hclk_en_o`
with the free-running clock combinationally: `hclk_en_o` is decoded from
address and state and may glitch inside a cycle. The family clock-gate
cell [`arv_cgate`](../../arv_primitives/rtl/verilog/arv_cgate.v) is
this structure; drive its `en_i` with `hclk_en_o | ~hresetn_i`. The
bench (`bench/verilog/tb_ahb_plic.v`) models the same cell:

```verilog
// SoC-side ICG model (reference)
reg hclk_en_latch;
always @(free_clk or hclk_en_o or hresetn_i)
    if (~free_clk)
        hclk_en_latch <= hclk_en_o | ~hresetn_i;
assign hclk_i = free_clk & hclk_en_latch;
```

> **The `| ~hresetn_i` term is mandatory when `ASYNC_RST_EN=0`**, and
> harmless otherwise. In sync-reset mode the flops need clock edges to
> reach their reset values, but `hclk_en_o` is built from those very
> flops: a closed gate at power-up leaves the domain uninitialised and
> `hreadyout_o` / `hresp_o` undefined during reset. Keeping the clock
> running while reset is asserted is the integrator's job.

Source 0 does not take part in the `hclk_en_o` OR-reduce (its priority,
pending and enable are hard-tied 0); `irq_src_i[0]` may be tied to either
level.

### Integration requirements

| Port / item | Rule | Consequence of ignoring it |
|---|---|---|
| `hresetn_i` | Active-low. Assertion is asynchronous with `ASYNC_RST_EN=1`, synchronous with `ASYNC_RST_EN=0` (the clock must then run while reset is asserted — see the ICG note). Synchronise the de-assert edge to `hclk_i` at the integration boundary; the IP has no reset synchroniser. | Metastability on the first capture edge after release. |
| `hclk_i` / ICG | Gate from `hclk_en_o` with a latch-based ICG (`arv_cgate`) whose enable is `hclk_en_o \| ~hresetn_i`. A free-running `hclk_i` is equally correct. | A combinational AND exposes `hclk_en_o` glitches to clock pins; a gate closed during reset never initialises a sync-reset build. |
| `irq_src_i` | Each bit is a level synchronous to the free-running clock from which `hclk_i` is gated (same edge). Any flop or synchroniser feeding it — [`arv_synchronizer`](../../arv_primitives/rtl/verilog/arv_synchronizer.v) for a foreign-clock source — is clocked by that free-running clock (or an always-on clock), **never by the PLIC's gated `hclk_i`**: the wake path `pin → irq_src_i → hclk_en_o` must lie entirely outside the gated domain. The gateway samples the pin directly; there is no synchroniser in the IP. | A synchroniser on the gated `hclk_i` never clocks while `hclk_en_o = 0`, so an asynchronous source can never wake a gated PLIC; the interrupt is lost until unrelated traffic reopens the clock. |
| `hsmode_i` | Connect to the fabric's `HAUSER` sideband (`data_hsmode_o` of an aRVern core). Without such a sideband, tie `hsmode_i = 0`. | With `hsmode_i = 0` every privileged access decodes as M: the S-mode rows of the access policy degrade to the M-mode rows and only U-mode denial remains. A debugger through the core's SBA presents as M (`hprot[1]=1, hsmode=0`) and is never locked out. |
| `hready_i` | Connect to the fabric's `HREADY` (the AND of all subordinates' `HREADYOUT`, as the interconnect builds it), which during the PLIC's own data phase equals its `hreadyout_o`. Never tie it high. | Tied high, a transfer issued while another subordinate stalls the bus is taken as accepted. The claim is a level on the held data phase: a fabric that lowers `hready_i` during the PLIC's data phase — off-spec for AHB-Lite — would claim a new source on every extended cycle and return only the last ID. The IP does not guard against this. |
| `hsize_i`, `htrans_i`, `haddr_i[1:0]` | Word transfers only; NONSEQ and SEQ both start an access, so word bursts are accepted beat by beat; IDLE and BUSY are ignored; `haddr_i[1:0]` is not decoded. | A non-word beat gets the two-cycle ERROR; a misaligned word address aliases onto its containing word. |
| `irq_src_i[0]` | Reserved; tie to `0` or `1`. | None — the bit is ignored. |
| Parameters | Keep every parameter inside the table's range; only simulation and lint check it. | Synthesis silently builds a broken netlist (see [Design parameters](#design-parameters)). |

---

## Verification

```bash
cd sim/rtl_sim/run
./run <test>              # one test, bench defaults (SU_MODE_EN=1)
./run_all                 # the default-config test list, bench defaults
./run_all -sweep          # every test x every config + coverage gate
./run_lint                # Verilator lint, RTL defaults
./run_lint -sweep         # Verilator lint, all RTL configs

cd ../../../lint/vc_static
./run_vclint -rtl_sweep   # VC Static signoff lint, all RTL configs

cd ../../synthesis/synopsys
./run_syn -rtl_sweep      # DC synthesis + DFT DRC, all RTL configs
```

The standalone bench `bench/verilog/tb_ahb_plic.v` drives the IP through
an AHB-Lite BFM (`ahb_tasks.v`: word, halfword and byte transfers in
M, S or U mode, blocking or pipelined) and a per-source `irq_src`
driver, with the SoC-side ICG model of [Clock gating](#clock-gating).
**The bench's own default build is `SU_MODE_EN=1`** (all six `PLIC_*`
defines default to the "everything on" build so the S-contexts are
exercised) while the RTL default is `SU_MODE_EN=0`; the `su0` sim
configs cover the RTL default.

### Scoreboard and coverage gate

`bench/verilog/scoreboard.v` is an always-on reference model, compared
against the DUT every cycle whatever stimulus runs; every mismatch fails
the test:

| Checker | Reference |
|---|---|
| **SB-EIP** (per context) | `irq_o` equals `OR_s(pending & enable & prio != 0 & prio > threshold)`. |
| **SB-TOP** (per context) | The claim winner equals the highest-priority pending-and-enabled source, ties to the lowest ID, threshold-independent. |
| **SB-GW** | Pending and in-service per source equal a gateway model driven only by `irq_src_i` and the claims and completions observed on the bus: a claim takes the ID the read returned, a completion counts only under the specification's rule (whole word in `1..NUM_SOURCES`, enabled for the completing context). |
| **SB-X** | No DUT output is X after reset. |

`bench/verilog/cover_monitor.v` raises a sticky bin the first time each
condition is seen (interrupt outputs high, `hclk_en_o` in both states,
ERROR and size-denial, pending / in-service / claim / complete activity,
priority-0 and threshold masking, a source above 31) and prints
`COVERAGE HIT: <bin>` at the end of every run. `./run_all -sweep` unions
the hits across all configs and **fails the sweep** when a bin in
`sim_configs.py:MANDATORY_COVER_BINS` was never hit.

### Configurations

Two tables drive the sweeps. `sim/rtl_sim/bin/sim_configs.py` sets the
bench defines and the test list of each simulation config:

| Sim config     | Defines (bench)                          | Tests |
|----------------|------------------------------------------|-------|
| `default`      | bench defaults (`SU_MODE_EN=1`)          | the 27 default tests |
| `nh2`          | `NUM_HARTS=2`                            | `priority_rdwr`, `enable_rdwr`, `unmapped_access`, `multihart_routing`, `priv_contexts`, `context_walk`, `addr_walk` |
| `nh4`          | `NUM_HARTS=4`                            | `priority_rdwr`, `enable_rdwr`, `unmapped_access`, `multihart_routing`, `priv_contexts`, `context_walk`, `addr_walk` |
| `su0`          | `SU_MODE_EN=0`                           | `priority_rdwr`, `pending_gateway`, `threshold_claim`, `unmapped_access`, `su_disabled`, `priv_contexts`, `context_walk`, `addr_walk`, `enable_priority_dynamics` |
| `nh2_su0`      | `NUM_HARTS=2 SU_MODE_EN=0`               | `priority_rdwr`, `unmapped_access`, `su_disabled`, `priv_contexts`, `context_walk`, `addr_walk` |
| `ns63_pb4`     | `NUM_SOURCES=63 PRIO_BITS=4`             | `pending_gateway`, `threshold_claim`, `arbiter_tiebreak`, `m_s_routing`, `unmapped_access`, `source_walk`, `threshold_extremes`, `addr_walk`, `context_walk`, `pair_contests`, `priority_multiword`, `enable_multiword`, `pending_multiword` |
| `ns127_pb7`    | `NUM_SOURCES=127 PRIO_BITS=7`            | `unmapped_access`, `source_walk`, `threshold_extremes`, `addr_walk`, `threshold_claim`, `arbiter_tiebreak`, `m_s_routing`, `priority_zero`, `threshold_boundary`, `complete_invalid_id`, `priv_contexts`, `random_irq`, `context_walk`, `pair_contests`, `priority_multiword`, `enable_multiword`, `pending_multiword` |
| `ns40_pb1`     | `NUM_SOURCES=40 PRIO_BITS=1`             | `source_walk`, `threshold_extremes`, `addr_walk`, `unmapped_access`, `pending_gateway`, `arbiter_tiebreak`, `m_s_routing`, `priority_zero`, `complete_invalid_id`, `random_irq`, `reset_values`, `pair_contests`, `priority_multiword`, `enable_multiword`, `pending_multiword` |
| `nh4_ns63_pb4` | `NUM_HARTS=4 NUM_SOURCES=63 PRIO_BITS=4` | `context_walk`, `unmapped_access`, `addr_walk`, `priv_contexts` |
| `priv_off`     | `PRIV_CHECK_EN=0`                        | `priority_rdwr`, `enable_rdwr`, `unmapped_access`, `priv_check_off`, `size_check`, `addr_walk` |
| `sync_rst`     | `ASYNC_RST_EN=0`                         | the default tests except `source_walk`, `threshold_extremes`, `enable_priority_dynamics`, `pair_contests` (23) |

`sim/rtl_sim/bin/rtl_configs.py` is the RTL parameter set shared by
`./run_lint -sweep`, `run_vclint -rtl_sweep` and `run_syn -rtl_sweep`
(`-rtl_config N|name` builds one of them; `-list_configs` numbers them),
so a config cannot mean one thing to one flow and another to the next.
Its `default` is the RTL default (`SU_MODE_EN=0`), unlike the bench's:

| RTL config           | Parameter overrides                             |
|----------------------|-------------------------------------------------|
| `default`            | (RTL defaults)                                  |
| `nh1_su1`            | `SU_MODE_EN=1`                                  |
| `nh2_su1`            | `NUM_HARTS=2 SU_MODE_EN=1`                      |
| `nh2_su0`            | `NUM_HARTS=2 SU_MODE_EN=0`                      |
| `nh4_su1`            | `NUM_HARTS=4 SU_MODE_EN=1`                      |
| `ns63_pb4`           | `NUM_SOURCES=63 PRIO_BITS=4 SU_MODE_EN=1`       |
| `ns127_pb7`          | `NUM_SOURCES=127 PRIO_BITS=7 SU_MODE_EN=1`      |
| `nh4_su1_ns63_pb4`   | `NUM_HARTS=4 NUM_SOURCES=63 PRIO_BITS=4 SU_MODE_EN=1` |
| `ns40_pb1`           | `NUM_SOURCES=40 PRIO_BITS=1 SU_MODE_EN=1`       |
| `sync_rst`           | `ASYNC_RST_EN=0 SU_MODE_EN=1`                   |

### Tests

One file per test in `sim/rtl_sim/src/`; tests that do not apply to a
build report **SKIP**, a test with no verdict reports **INCONCLUSIVE**
and fails the sweep.

| Test | Pins | Sim configs |
|---|---|---|
| `priority_rdwr` | Priority register file: only `PRIO_BITS` LSBs stored, source 0 RAZ/WI, write-data truncation. | `default`, `nh2`, `nh4`, `su0`, `nh2_su0`, `priv_off`, `sync_rst` |
| `priority_multiword` | Priority slots for sources 32 and above (offset `0x80+`), truncation, `priority[0]` RAZ/WI, RAZ above `NUM_SOURCES`. | `ns63_pb4`, `ns127_pb7`, `ns40_pb1` |
| `priority_zero` | A pending-and-enabled source at priority 0 neither interrupts nor wins a claim, at threshold 0. | `default`, `ns127_pb7`, `ns40_pb1`, `sync_rst` |
| `pending_gateway` | Gateway latches a source until claimed, several sources accumulate in one word, writes to the pending window are ignored. | `default`, `su0`, `ns63_pb4`, `ns40_pb1`, `sync_rst` |
| `pending_multiword` | Sources 32 and above latch at the right positions of pending word 1; word 0 stays clear. | `ns63_pb4`, `ns127_pb7`, `ns40_pb1` |
| `pending_gated_wake` | With the bus idle and `hclk_i` gated off, a source rising re-opens the clock through `hclk_en_o`, the pending bit sets and the interrupt fires. | `default`, `sync_rst` |
| `enable_rdwr` | Enable bits per (context, word): source-0 bit hard-tied 0, contexts are independent storage, out-of-range words and contexts RAZ. | `default`, `nh2`, `nh4`, `priv_off`, `sync_rst` |
| `enable_multiword` | Enable words 0 and 1 hold distinct patterns, source-0 bit 0, a second context is independent; masked to `NUM_SOURCES`. | `ns63_pb4`, `ns127_pb7`, `ns40_pb1` |
| `threshold_claim` | Arbiter ordering, threshold masking at and below, claim clears pending on the same edge, complete with the level still high re-triggers, with the level released does not. | `default`, `su0`, `ns63_pb4`, `ns127_pb7`, `sync_rst` |
| `threshold_boundary` | Strict `>`: `prio == threshold` masks, `prio == threshold + 1` passes; the claim winner is returned while masked. | `default`, `ns127_pb7`, `sync_rst` |
| `claim_threshold_independent` | The claim read returns the highest pending-and-enabled source even when the threshold masks it (Chapter 8). | `default`, `sync_rst` |
| `complete_invalid_id` | Completions of a source not enabled for the context, of ID 0, above `NUM_SOURCES`, or with bits above `[10]` set are ignored and leave a genuine in-service bit untouched (Chapter 9). | `default`, `ns127_pb7`, `ns40_pb1`, `sync_rst` |
| `arbiter_tiebreak` | Three sources at one priority are served lowest ID first. | `default`, `ns63_pb4`, `ns127_pb7`, `ns40_pb1`, `sync_rst` |
| `m_s_routing` | ctx 0 drives `irq_m_external_o[0]`, ctx 1 drives `irq_s_external_o[0]`; a claim by one context removes the source from the other's view until completion. | `default`, `ns63_pb4`, `ns127_pb7`, `ns40_pb1`, `sync_rst` |
| `multihart_routing` | Per-hart routing of M (and S) contexts; a claim by one hart drops the other hart's view. | `nh2`, `nh4` |
| `su_disabled` | `SU_MODE_EN=0`: context indices `>= NUM_HARTS` RAZ/WI, `irq_s_external_o` tied 0, an M-context still routes end to end. | `su0`, `nh2_su0` |
| `unmapped_access` | Every hole RAZ/WI with OKAY: between the enable and target windows, priority above `NUM_SOURCES`, enable and pending words above `NUM_SOURCES` (word 32 does not alias onto word 0), target strides beyond `NUM_CONTEXTS`. | all 11 |
| `priv_check` | `PRIV_CHECK_EN=1` policy: denied S/U accesses return ERROR and leave state untouched, M reads back the intact pattern. | `default`, `sync_rst` |
| `priv_check_off` | `PRIV_CHECK_EN=0`: the same accesses succeed. | `priv_off` |
| `priv_contexts` | Policy on every context's enable block and threshold in every build: M allowed, S allowed only on an S-context, U denied; denied writes change nothing. | `default`, `nh2`, `nh4`, `su0`, `nh2_su0`, `ns127_pb7`, `nh4_ns63_pb4`, `sync_rst` |
| `size_check` | Byte and halfword transfers to a valid register are denied with ERROR; a word access to the same register is the control. | `default`, `priv_off`, `sync_rst` |
| `ahb_error_p2` | Cycle-accurate ERROR shape: `{hresp, hreadyout}` = `1,0` then `1,1`, then `hresp = 0`. | `default`, `sync_rst` |
| `error_hold` | An address phase held through an ERROR is taken in its second cycle and completes normally; two denied transfers back to back give two full ERROR responses; a denied read returns 0 in both cycles; a denied claim read neither claims nor clears the pending source. | `default`, `sync_rst` |
| `bus_pipelined` | Pipelined back-to-back writes and reads, a NONSEQ+SEQ word burst accepted beat by beat, IDLE and BUSY carrying a bad size or U-mode (zero-wait OKAY, no effect), `hsize` `3'b011` and `3'b000` on a word address (ERROR). | `default`, `sync_rst` |
| `reset_values` | Every register reads 0 before any write; no interrupt output is asserted at boot. | `default`, `ns40_pb1`, `sync_rst` |
| `random_irq` | Constrained-random priorities, enables, threshold and source vector with interleaved claim/complete on the claimed ID; correctness comes from the scoreboard, a fresh seed per run. | `default`, `ns127_pb7`, `ns40_pb1`, `sync_rst` |
| `source_walk` | Every source end to end through ctx 0 (priority read-back, output, its own pending bit only, claim, complete); ascending and descending priority ladders with every line high claimed to exhaustion in the arbiter's order; every priority and enable bit set then cleared; source 0 never pends. | `default`, `ns63_pb4`, `ns127_pb7`, `ns40_pb1` |
| `context_walk` | Every context in turn: its whole enable block written all-ones (implemented bits read back, reserved words RAZ) then all-zeros; sources 1, 2, 4, …, 64, `NUM_SOURCES` and `NUM_SOURCES` with one bit cleared each alone on the context: exactly its mapped output rises, its claim returns the ID, a complete through a context not enabling the source is ignored (no re-pend while the line is high), the complete through its own context is accepted. | `nh2`, `nh4`, `su0`, `nh2_su0`, `ns63_pb4`, `ns127_pb7`, `nh4_ns63_pb4` |
| `addr_walk` | Walking one and walking zero over `haddr[21:2]` plus reserved target, priority, pending and enable offsets, each classified from the address map and checked from M, S and U mode against the access table; `hprot` `4'hF` / `4'hD` decode as `4'h2` / `4'h0`; `hsize` `3'b100`..`3'b111` denied; a misaligned word address lands on its containing word. | all 11 |
| `reset_in_operation` | A line high across reset release pends on the first edge after it; reset with live priorities, enables, thresholds, pending and in-service state gives `hreadyout=1`, `hresp=0`, outputs 0, and every register at 0 after release with the high lines re-pending; source 0 toggling pends nothing and leaves `hclk_en_o` low. | `default`, `sync_rst` |
| `threshold_extremes` | Priority `2^PRIO_BITS-1` under threshold `2^PRIO_BITS-1` is masked but still claimed, under `2^PRIO_BITS-2` it interrupts (sources 1, 64 and `NUM_SOURCES`); all-ones writes to every threshold and a priority read back `2^PRIO_BITS-1`. | `default`, `ns63_pb4`, `ns127_pb7`, `ns40_pb1` |
| `enable_priority_dynamics` | Clearing the enable or zeroing the priority of a pending source drops the output and the claim while the pending bit stays; a complete after the enable is cleared is dropped, the source stays in service until re-enabled and completed. | `default`, `su0` |
| `claim_complete_pipelined` | Back-to-back transfers: claim via ctx 0 then ctx 1 (the second gets the next source or 0), complete with the line high then two back-to-back claims (0, then the re-pended source one cycle later), a word claim held behind a size-denied claim read taken exactly once, complete then enable-clear (complete accepted). | `default`, `sync_rst` |
| `pair_contests` | Every adjacent pair (2k, 2k+1), k ≥ 1, alone on ctx 0: even ID higher, odd ID higher, then equal (lowest ID wins); winner then loser claimed and completed. With `PRIO_BITS=1` the loser of an unequal contest is at priority 0 and is not claimed until raised to 1. | `default`, `ns63_pb4`, `ns127_pb7`, `ns40_pb1` |

### Signoff gates

| Gate | Criterion |
|---|---|
| Simulation sweep (`./run_all -sweep`) | 0 failed, 0 inconclusive, every mandatory coverage bin hit |
| Verilator lint (`./run_lint -sweep`) | 0 warnings, all RTL configs |
| VC Static lint (`run_vclint -rtl_sweep`) | 0 errors, 0 warnings, **0 stale waivers**, all RTL configs |
| Synthesis (`run_syn -rtl_sweep`) | 0 timing violations, **0 unconstrained endpoints**, 0 DFT violations, all RTL configs |

### Lint conventions

The RTL is clean under `verilator --lint-only -Wall -Wpedantic` with an
empty waiver file (`sim/rtl_sim/run/waivers.vlt`). Deliberately unused
signals (`htrans_i[0]`, the cacheable / bufferable / data bits of
`hprot_i`, byte-lane address bits, the source-0 inputs) are routed to sink
wires with an `_unused` suffix, so one tool-agnostic regex waives the
residual warning in any lint tool. Keep the suffix when adding RTL.
VC Static (`lint/vc_static/`, policy in `rules.tcl`, design waivers in
`waivers.tcl`) reports *stale* waivers — ones that matched nothing — and
a non-zero count fails the run. Declare every net before its first use:
Verilator and Icarus accept a forward reference, VC Static and Design
Compiler reject it.

### Core-level tests

The aRVern core testbench
([`tb_arvern.v`](https://github.com/Arvern-Silicon/arvern/blob/main/bench/verilog/tb_arvern.v))
instantiates the PLIC as a 4 MB subordinate at `0x0C00_0000` and runs
end-to-end firmware tests against the core ↔ PLIC interface
([`sim/rtl_sim/src/trap_irq_plic_*`](https://github.com/Arvern-Silicon/arvern/tree/main/sim/rtl_sim/src)):
`basic` (configure, claim, complete, higher priority first), `drain`
(a 4-deep pending set delivered in priority order), `threshold` (strict
`>`), `seip` (delegated S-mode external interrupt through ctx 1),
`priv_violation` and `size_violation` (the ERROR response reported as the
resumable NMI), and `wfi_wake` (a source rising wakes the core from WFI).

---

## Synthesis

A Synopsys Design Compiler flow lives under `synthesis/synopsys/`,
following the same pattern as the other `arvern-ips` blocks, with a
`LIB_FLAVOR` selector for the technology setup:

```bash
cd synthesis/synopsys
./run_syn                          # default flavor (lib_default), RTL defaults
./run_syn -lib <flavor>            # a specific library flavor
./run_syn -lib <flavor> -i         # interactive (keep dc_shell open after the run)
./run_syn -rtl_config <N|name>     # one config from sim/rtl_sim/bin/rtl_configs.py
./run_syn -rtl_sweep               # every config; one summary line each
./run_syn -list_configs            # number the configs
```

`libraries/setup_lib_default.tcl` is intentionally absent, because it
names your technology: create it from the tracked template before the
first run (`cp libraries/setup_lib_example.tcl
libraries/setup_lib_default.tcl`, then edit). Any other
`setup_<flavor>.tcl` in the same directory is selected with
`-lib <flavor>`; an unknown flavor prints the list found. Foundry `.db`
files are typically symlinked under `libraries/` so one setup serves
several IPs (see [`README.md`](../../README.md#synthesis)).

The boundary I/O delays follow the register-bank subordinate convention:
20 % of the clock period on the AHB inputs and `irq_src_i`, 70 % on the
AHB outputs, 75 % on the per-hart interrupt outputs and `hclk_en_o`
(they drive the core's trap-priority encoder and the SoC ICG). The
`hsel_i` / `hready_i` / `htrans_i` / `irq_src_i` → `hclk_en_o`
feed-throughs form their own path group.

Outputs land in `results/`; a `-rtl_config` build also snapshots its
reports to `results_sweep/<label>/`, and `-rtl_sweep` writes
`results_sweep/sweep_summary.log` (timing violations, unconstrained
endpoints and DFT violations per config):

| File                                     | Description |
|------------------------------------------|-------------|
| `ahb_plic.gate.v`, `ahb_plic.ddc`        | Gate-level netlist and DDC database |
| `ahb_plic.spf`                           | DFT scan test protocol |
| `report.area`, `report.full_area`        | Area summary (incl. NAND2-equivalent) and hierarchy |
| `report.timing`, `report.check_timing_pre` | Timing check; unconstrained endpoints |
| `report.paths.*`, `report.full_paths.*`  | Worst-path end-point and full-path reports (max / min) |
| `report.constraints`                     | Constraint compliance |
| `report.dft_*`                           | DFT DRC, coverage estimate, scan-chain configuration |
| `report.refs`                            | Cell references |
| `synthesis.log`                          | Full dc_shell transcript |

`run_check_reset_style` runs PrimeTime (`check_reset_style_pt.tcl`) on
the gate-level netlist to confirm every flop carries the reset style the
build selected.

---

## Repository layout

```
ahb_plic/
├── ahb_plic.core                     FuseSoC manifest (RTL fileset + lint target)
├── rtl/verilog/
│   ├── ahb_plic.v                    Top: AHB-Lite subordinate, decode, access policy, hclk_en_o
│   ├── plic_priority.v               Per-source priority register file
│   ├── plic_pending.v                Pending + in_service flops, level gateway
│   ├── plic_enable.v                 Per-(context, source) enable matrix
│   ├── plic_target.v                 Per-context threshold + arbiters + claim/complete
│   └── filelist.f                    RTL source list (sim, lint and synthesis)
├── bench/verilog/
│   ├── tb_ahb_plic.v                 Testbench: parameters, ICG model, DUT
│   ├── ahb_tasks.v                   AHB-Lite BFM (M/S/U, blocking or pipelined)
│   ├── scoreboard.v                  SB-EIP / SB-TOP / SB-GW / SB-X reference models
│   ├── cover_monitor.v               Functional-coverage bins
│   └── submit.f                      Simulation file list
├── sim/rtl_sim/
│   ├── src/                          One <test>.v per test
│   ├── bin/                          runsim, run_sweep.py, sim_configs.py, rtl_configs.py, lint sweep
│   └── run/                          run, run_all, run_lint, waivers.vlt
├── lint/vc_static/                   VC Static flow: run_vclint, rules.tcl, waivers.tcl
├── synthesis/synopsys/               DC flow: run_syn, constraints.tcl, libraries/
└── doc/
    └── ahb_plic.md                   This document
```

---

## License

BSD 3-Clause — see [`LICENSE`](../../LICENSE) at the repo root.
