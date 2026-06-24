<p align="center">
  <img src="img/aRVern_light.png" alt="aRVern" width="180">
</p>

# Platform-Level Interrupt Controller (AHB-Lite)

*RISC-V PLIC with per-hart M and S contexts for routing platform interrupts to aRVern cores.*

---

## Contents

- [Overview](#overview)
  - [Design parameters](#design-parameters)
  - [Module hierarchy](#module-hierarchy)
  - [Port summary](#port-summary)
  - [Access control](#access-control)
  - [Clock gating](#clock-gating)
  - [Integration requirements](#integration-requirements)
  - [Lint waivers](#lint-waivers)
- [Address map](#address-map)
  - [Context numbering](#context-numbering)
  - [Priority window](#priority-window)
  - [Pending window](#pending-window)
  - [Enable window](#enable-window)
  - [Target window](#target-window)
- [Gateway and arbitration](#gateway-and-arbitration)
  - [Level-triggered gateway](#level-triggered-gateway)
  - [Per-context arbiter](#per-context-arbiter)
  - [Claim / Complete handshake](#claim--complete-handshake)
- [Repository layout](#repository-layout)
- [Verification](#verification)
- [Synthesis](#synthesis)
- [License](#license)

---

## Overview

The **`ahb_plic`** module is a parametrisable IP that implements the
RISC-V **PLIC** (Platform-Level Interrupt Controller) specification as a
single AHB-Lite slave. It routes up to `NUM_SOURCES` external
level-triggered interrupt lines into per-hart **M-mode** and (when
`SU_MODE_EN=1`) **S-mode** interrupt outputs that connect to the aRVern
core's `MIP.MEIP` / `MIP.SEIP` inputs.

The address layout matches the **SiFive PLIC** convention used by every
mainstream RISC-V software stack (Linux's `drivers/irqchip/irq-sifive-plic.c`,
OpenSBI, FreeRTOS, Zephyr, …), so existing PLIC drivers work unchanged on
top of this IP. The IP lives entirely in the `hclk_i` clock domain — no
CDC paths internally; the SoC integrator is responsible for synchronising
foreign-clock IRQ sources at the boundary.

### Design parameters

| Parameter         | Default       | Range        | Purpose |
|-------------------|---------------|--------------|---------|
| `NUM_SOURCES`     | `31`          | `1..1023`    | Number of usable IRQ sources. Source ID 0 is reserved by spec (no IRQ); usable IDs are `1..NUM_SOURCES`. Default `31` fits all pending and enable bits in a single 32-bit register word. |
| `NUM_HARTS`       | `1`           | `1..16`      | Number of harts. Match `ahb_aclint`'s `NUM_HARTS`. |
| `SU_MODE_EN`      | `1`           | `0` or `1`   | Enable per-hart S-mode context. Match the core's `SU_MODE_EN`. When `0`, only M-contexts exist; the S-context address windows are RAZ/WI and `irq_s_external_o` is tied 0. |
| `PRIO_BITS`       | `3`           | `1..7`       | Priority width per source. Default `3` (8 priority levels) matches the SiFive default. `PRIO_BITS=1` is a cheap "enabled / disabled" mode for area-sensitive integrations. |
| `PRIV_CHECK_EN` | `1`        | `0` or `1`   | IP-level privilege filter using `hprot_i[1]` + `hsmode_i`. When `1` (default), accesses are denied per the policy in [Access control](#access-control). When `0`, the privilege check is skipped (the integrator must rely on a fabric-level access check) but the size check stays active. |
| `ASYNC_RST_EN`    | `1`           | `0` or `1`   | Reset architecture: `1` = asynchronous active-low reset (default); `0` = synchronous reset. Threaded to every flop via the shared `arv_ipdff` primitive. Synchronous mode requires the clock to be running during reset assertion. See the repo README's *Reset architecture* section. |

> **Parameter check.** Out-of-range parameters trigger a simulation-time
> `$fatal` (e.g. `NUM_HARTS` outside `1..16`). The checks live in a
> `pragma translate_off` block — synthesis is unaffected.

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
`SU_MODE_EN ? 2*NUM_HARTS : NUM_HARTS`. The four storage sub-blocks
(`plic_priority`, `plic_pending`, `plic_enable`) are always instantiated
once each. The `plic_target` instances are spun up in a `generate-for`
loop, one per context. When `SU_MODE_EN=0`, the loop instantiates
`NUM_HARTS` targets (one M-context per hart). When `SU_MODE_EN=1`, the
loop instantiates `2*NUM_HARTS` targets, alternating M/S per hart.

### Port summary

| Direction | Port           | Width                  | Description |
|-----------|----------------|------------------------|-------------|
| in        | `hclk_i`       | 1                      | AHB clock |
| in        | `hresetn_i`    | 1                      | Active-low reset — **asynchronous** assertion when `ASYNC_RST_EN=1` (default), **synchronous** when `ASYNC_RST_EN=0`; sync-deassert |
| in        | `hsel_i`       | 1                      | AHB-Lite slave select |
| in        | `haddr_i`      | 22                     | Byte address (4 MB PLIC window — covers the full SiFive register layout up to the max 32 contexts; the SoC fabric crops the system address to these 22 bits before presenting it) |
| in        | `hwrite_i`     | 1                      | AHB write enable |
| in        | `hsize_i`      | 3                      | Transfer size. Must be word (`3'b010`); sub-word and double-word accesses are rejected with an AHB ERROR (see [Access control](#access-control)). |
| in        | `htrans_i`     | 2                      | Transfer type (NONSEQ/SEQ start an access) |
| in        | `hprot_i`      | 4                      | AHB-Lite protection. Bit `[1]`: 1 = privileged, 0 = unprivileged. Other bits are ignored. Consumed only when `PRIV_CHECK_EN=1`. |
| in        | `hsmode_i`     | 1                      | aRVern AHB extension. When `hprot_i[1]=1`: 0 = M-mode, 1 = S-mode. Don't-care when `hprot_i[1]=0`. Consumed only when `PRIV_CHECK_EN=1`. |
| in        | `hready_i`     | 1                      | Bus ready in |
| in        | `hwdata_i`     | 32                     | Write data |
| out       | `hrdata_o`     | 32                     | Read data |
| out       | `hreadyout_o`  | 1                      | Normally `1` (every sub-block is single-cycle); driven `0` for one cycle on the first cycle of a two-cycle ERROR response. |
| out       | `hresp_o`      | 1                      | Normally `0`; driven `1` for both cycles of the two-cycle ERROR response when an access is denied (bad size or privilege violation). |
| in        | `irq_src_i`    | `NUM_SOURCES+1`        | External IRQ lines, level-sensitive. Bit `[s]` carries source `s`; bit `[0]` is the reserved source-0 input and is ignored. |
| out       | `irq_m_external_o`   | `NUM_HARTS`            | M-mode external IRQ per hart (drives the core's `MIP.MEIP`) |
| out       | `irq_s_external_o`   | `NUM_HARTS`            | S-mode external IRQ per hart (drives the core's `MIP.SEIP`). Tied `0` when `SU_MODE_EN=0`. |
| out       | `hclk_en_o`          | 1                      | Combinational clock-gate advisory: HIGH when the PLIC needs an `hclk_i` edge this cycle. Drive a SoC-side latch-based ICG. See [Clock gating](#clock-gating). |

### Access control

The IP enforces two orthogonal access checks on every AHB transaction;
either failing denies the access and triggers a two-cycle AHB ERROR
response.

#### 1. Access size (always enforced)

The PLIC 1.0 specification (Chapter 3) mandates 32-bit word (LW/SW)
accesses to every memory-mapped register: *"The memory-mapped registers
specified in this chapter have a width of 32-bits. The bits are accessed
atomically with LW and SW instructions."* The IP enforces this strictly
— any access with `hsize_i ≠ 3'b010` (i.e. byte, halfword, double-word,
or burst) is denied. This catches firmware bugs early (e.g. a `sb` of
the wrong type into the priority register) rather than silently
truncating or extending the access.

The size check runs independently of `PRIV_CHECK_EN` — it is always on,
because there is no spec-defined behaviour for sub-word accesses and the
risk of silently committing garbage to a register is the same regardless
of who issued the bus access.

#### 2. Privilege filter (`PRIV_CHECK_EN=1`)

When `PRIV_CHECK_EN=1` (the default), the IP enforces a per-access
privilege check using `hprot_i[1]` and `hsmode_i`. This is **defense in
depth** on top of any fabric-level access policy — the goal is to prevent
a misbehaving bus master from corrupting PLIC state even if the fabric's
address decoder has a bug.

**Privilege encoding** (per the aRVern AHB dialect):

| `hprot_i[1]` | `hsmode_i` | Privilege |
|--------------|------------|-----------|
| 1            | 0          | M-mode    |
| 1            | 1          | S-mode    |
| 0            | x          | U-mode    |

**Access policy** (window-level):

| Window                              | M-mode | S-mode | U-mode |
|-------------------------------------|:------:|:------:|:------:|
| Priority (`0x000000 – 0x000FFF`)    | RW     | RW     | DENY   |
| Pending (`0x001000 – 0x001FFF`)     | RO     | RO     | DENY   |
| Enable for an M-context (`ctx[0]=0`)| RW     | DENY   | DENY   |
| Enable for an S-context (`ctx[0]=1`)| RW     | RW     | DENY   |
| Target for an M-context             | RW     | DENY   | DENY   |
| Target for an S-context             | RW     | RW     | DENY   |

When `SU_MODE_EN=0`, every context is an M-context, so an S-mode master
that reaches the PLIC will be denied access to all enable / target
windows (it can still read priority and pending). U-mode is always denied
everything.

The privilege check fires only on accesses that actually land on a
real context register; out-of-range addresses inside the enable /
target windows (e.g. ctx >= NUM_CONTEXTS) are RAZ/WI'd via the
sub-block decode rather than denied, avoiding an address-layout
info leak via ERROR-vs-OK probing.

**Disabling the filter.** Set `PRIV_CHECK_EN=0` if the SoC fabric
already enforces a privilege check at the address-decoder level, or if
the integration genuinely has no privilege control. In that case
`hprot_i` and `hsmode_i` are still inputs (so the integrator wires them
up regardless) but the IP ignores them for the privilege decision.
**The size check (1, above) remains active.**

#### Denial behaviour (shared by both checks)

A denied access — sub-word size **or** privilege violation — produces
the spec-compliant AHB-Lite **two-cycle ERROR response**:

| Cycle             | `hreadyout_o` | `hresp_o` |
|-------------------|:-------------:|:---------:|
| Data phase, cycle 1 | 0 (stall)   | 1 (ERROR) |
| Data phase, cycle 2 | 1 (release) | 1 (ERROR) |

After cycle 2 the slave returns to idle. The addressed sub-block's
`reg_sel_i` is gated to 0 throughout the denied data phase, so the
write does not reach the storage and any read returns `0` (RAZ — the
data bus is not connected). The two-cycle pattern lets the AHB master
take an access-fault trap on the same cycle `hreadyout` releases,
rather than continuing past a silently-dropped access. In the aRVern
core this surfaces as a `load_access_fault` (cause 5) on a denied read
or a `store_access_fault` (cause 7) on a denied write — putting
misbehaving firmware on notice rather than allowing it to corrupt PLIC
state silently.

### Clock gating

`hclk_en_o` is a **combinational** advisory output that says "the PLIC needs
an `hclk_i` edge this cycle." It goes HIGH only when one of the IP's flops
will actually transition this cycle:

- An AHB-Lite address phase is selecting this slave (`hsel & hready & htrans[1]`)
  — about to latch `dph_valid` / `dph_addr` / `dph_size` / `dph_hsmode` /
  `dph_hprot1` / `dph_write`.
- An AHB-Lite data phase is in flight — register writes (priority, enable,
  threshold), `claim` and `complete` pulses, and the two-cycle error FSM all
  advance in `dph_valid` cycles.
- The gateway is about to set a pending bit 0→1 — i.e. a source `s` in
  `1..NUM_SOURCES` satisfies `~in_service[s] & irq_src_i[s] & ~pending[s]`.
  This is the only state transition that is not AHB-driven.

It goes LOW in all stable states — including `pending=1` with the source
still asserted (the target arbiter that drives `irq_*_external_o` is
purely combinational on `pending / enable / priority / threshold` and
does not consume the PLIC clock), and `in_service=1` waiting for the
`complete` write to arrive (the matching `complete` is an AHB write,
which raises `hclk_en_o` via the address-phase term as soon as the
master asserts `hsel`).

> **WFI wake.** The `pending_set_needed` term rises combinationally as soon
> as `irq_src_i[s]` goes high into a quiescent PLIC (pending=0, in_service=0).
> So a peripheral asserting its IRQ line will re-open the SoC clock on the
> very next free-clock cycle even if the core was deep in WFI sleep with
> every domain gated off.

**Integration pattern (SoC side).** Wire `hclk_en_o` into a latch-based ICG
cell (CKLNQD / LSCKDP-style, with a negative-level enable latch) gating
`hclk_i`. Do **not** AND `hclk_en_o` with the free-running clock combinationally
and feed the result to a flop clock pin — that exposes any glitches on
`hclk_en_o` (from address-decode transitions etc.) to flop clock inputs. The
testbench at `bench/verilog/tb_ahb_plic.v` models a proper ICG via a
level-sensitive latch on `~free_clk`, the same convention as the
`arv_custom_csr` IP.

```verilog
// SoC-side ICG model (reference)
reg hclk_en_latch;
always @(free_clk or hclk_en_o)
    if (~free_clk)
        hclk_en_latch <= hclk_en_o;
assign hclk_i = free_clk & hclk_en_latch;
```

> **Note.** `hclk_en_o` does NOT include source 0 in its OR-reduce since
> source 0 is reserved (priority/pending/enable all hard-tied to 0) and can
> never contribute. The integrator may safely treat the bit as unused.

### Integration requirements

- **Reset (`hresetn_i`)** — active-low, asynchronously asserted. The
  assertion style follows `ASYNC_RST_EN` (async when `1`, synchronous
  when `0`; synchronous mode needs a running clock during reset
  assertion). The
  **de-assert edge must be synchronised to `hclk_i`** at the integration
  boundary. The IP contains no internal reset synchroniser; an
  unsynchronised de-assert produces metastability on the first capture
  edge.

- **IRQ source synchronisation** — `irq_src_i[s]` MUST be presented as an
  `hclk_i`-synchronous level. The level-triggered gateway in
  `plic_pending` samples it directly without any per-source synchroniser
  (see `ahb_plic.v` port comment and `plic_pending.v:46, 112`). If a
  source originates from a different clock domain (e.g. an always-on
  GPIO, an LF-domain watchdog), the integrator MUST place a 2-FF
  synchroniser at the IP boundary — the shared `arv_synchronizer` cell
  (`arv_common/rtl/verilog/arv_synchronizer.v`) is the recommended
  building block. The PLIC intentionally does **not** instantiate
  per-source synchronisers internally because most platform IRQ sources
  already live in `hclk_i`, and gating the unneeded synchronisers is the
  integrator's choice.

- **AHB-Lite signalling** — `htrans_i[0]` (BUSY) is ignored: a
  NONSEQ/SEQ start (`htrans_i[1]=1`) launches an access. `hsize_i` is
  enforced — only word (`3'b010`) is accepted; sub-word, double-word
  and burst accesses receive an AHB ERROR response. Firmware MUST use
  LW/SW for every PLIC register access per the PLIC 1.0 spec.

- **`irq_src_i[0]` is reserved** — the IP ties source 0 internally to
  "no IRQ" (priority 0, pending 0, enable 0 for every context); reads
  of source-0 priority return 0; writes are ignored. The integrator may
  tie `irq_src_i[0]` to either `0` or `1` — it makes no difference.

- **AHB serialises claim races** — when two contexts could in principle
  claim the same source on the same cycle (a multi-hart deployment with
  `MEIP` and `SEIP` both wanting to claim the same external line), the
  AHB master serialises the accesses naturally: only one context's
  claim-read address can be on the bus per cycle. Whichever read happens
  first wins; the second read returns `0` (no IRQ to claim) because the
  first read's `in_service` set has cleared the pending bit. **The IP
  contains no inter-context arbiter** — it relies entirely on AHB-Lite's
  built-in single-transaction-per-cycle property.

### Lint waivers

The RTL ships clean under `verilator --lint-only -Wall -Wpedantic` with
an empty waiver file (see `sim/rtl_sim/run/waivers.vlt`). Intentionally
unused signals (`htrans_i[0]`, the cacheable / bufferable / data bits
of `hprot_i`, byte-lane bits of register addresses, source-0 input
lines) are routed to explicit sink wires named with an `_unused`
suffix so a single tool-agnostic regex (`*_unused*`) can waive the
residual warning in any lint tool. Keep the suffix when adding RTL.

---

## Address map

The AHB slave occupies a fixed **4 MB window** (22-bit byte address).
This covers the full SiFive PLIC layout up to 32 contexts. The actual
implemented register footprint is much smaller; everything else in the
window is RAZ/WI.

| Offset                         | Window                                   | Notes |
|--------------------------------|------------------------------------------|-------|
| `0x000000 – 0x000FFF`          | **Priority** (4 KB)                      | one word per source |
| `0x001000 – 0x001FFF`          | **Pending** (4 KB)                       | one bit per source, 32 sources / word |
| `0x002000 – 0x002000 + 0x80×NUM_CONTEXTS` | **Enable** (per context × per word)  | RW; same packing as pending |
| `0x200000 + 0x1000×ctx`        | **Target[ctx]** (8 bytes used)           | `+0` threshold, `+4` claim/complete |
| outside the above ranges       | reserved                                 | RAZ/WI |

### Context numbering

| `SU_MODE_EN` | Context index `ctx` | Number of contexts |
|--------------|---------------------|--------------------|
| `1`          | `ctx = 2*hart + s_mode` (M=0, S=1)  | `2 * NUM_HARTS` |
| `0`          | `ctx = hart`                        | `NUM_HARTS`     |

So with `SU_MODE_EN=1, NUM_HARTS=1`, ctx 0 = hart 0 M-mode, ctx 1 = hart 0
S-mode. With `SU_MODE_EN=1, NUM_HARTS=2`, the four contexts in order are
hart0/M, hart0/S, hart1/M, hart1/S. With `SU_MODE_EN=0, NUM_HARTS=2`, the
two contexts are hart0/M, hart1/M (the would-be S-context address windows
RAZ/WI).

This is the SiFive convention. Linux's PLIC driver expects exactly this
interleaving.

### Priority window

`PRIO_BITS`-wide priority register per source, in the low bits of a
32-bit word at byte offset `4*src`.

| Offset            | Register                          | Bits |
|-------------------|-----------------------------------|------|
| `0x0000`          | `priority[0]` — RAZ/WI (reserved) | always 0 |
| `0x0004`          | `priority[1]`                     | `[PRIO_BITS-1:0]` |
| `4*src`           | `priority[src]` (src = 1..NS)     | (same) |
| `4*(NS+1)` and above | RAZ/WI                          | — |

Priority 0 = "never interrupt"; priority 1 = lowest enabled; priority
`(2^PRIO_BITS)-1` = highest. The arbiter inside each `plic_target`
treats priority 0 specially — see [Per-context arbiter](#per-context-arbiter).

### Pending window

Pending bits packed 32 sources per word, **read-only from the AHB
side**. Bit `b` of word `w` corresponds to source ID `32*w + b`. Bit 0
of word 0 (source 0) always reads as 0. Source IDs > `NUM_SOURCES`
read as 0.

| Offset            | Word                  | Bits |
|-------------------|-----------------------|------|
| `0x1000`          | pending[31:0]         | `[0]=src0 (always 0)`, `[1]=src1`, … |
| `0x1004`          | pending[63:32]        | `[0]=src32`, … |
| `0x1000 + 4*w`    | pending word `w`      | (same packing) |
| above `0x1000 + 4*ceil(NS/32)` | RAZ            | — |

Writes are silently ignored — pending bits change only via the gateway
(set by the source line) or by claim (cleared when a context claims).
There is no software-clear path for a stuck pending bit; the only way
to clear `pending[s]` is for an enabled context to claim it (or for the
source line to drop and let the gateway re-evaluate after the next claim).

### Enable window

Per-context enable bits, packed 32 sources per word. Each context owns
a 128-byte block. Bit 0 of word 0 (source 0) is RAZ/WI for every
context.

| Offset                            | Register                | Notes |
|-----------------------------------|-------------------------|-------|
| `0x2000 + 0x80*ctx + 4*w`         | enable[ctx][word w]     | `[0]=src(32w)`, etc. |
| same offset, ctx > NUM_CONTEXTS-1 | RAZ/WI                  | — |
| `0x2000 + 0x80*ctx + 4*(w >= ceil(NS/32))` | RAZ/WI         | — |

Note: the spec defines a per-context enable bit even for source 0; we
hard-tie it to 0 since no IRQ can ever arrive on source 0.

### Target window

Each context owns a 4 KB-strided block holding its threshold and its
claim/complete register. Only the first 8 bytes are used; the rest of
the 4 KB stride is RAZ/WI.

| Offset                          | Register                       | Behaviour |
|---------------------------------|--------------------------------|-----------|
| `0x200000 + 0x1000*ctx + 0x0`   | `threshold[ctx]`               | RW, `PRIO_BITS`-wide. The arbiter ignores any source whose priority is `<= threshold`. Setting `threshold = max_priority` effectively masks all IRQs for that context. |
| `0x200000 + 0x1000*ctx + 0x4`   | `claim_complete[ctx]`          | **Read = claim**: returns the ID of the highest-priority pending+enabled source (or 0 if none — the claim arbiter is threshold-independent per PLIC 1.0 Chapter 8), and on the same hclk edge sets `in_service[id]` and clears `pending[id]`. **Write = complete**: writing source ID `N` clears `in_service[N]`, allowing future gateway re-trigger. Writes with `N=0` or `N > NUM_SOURCES` are silently dropped. |
| other offsets in stride         | RAZ/WI                         | — |

> **Claim atomicity.** The claim read and the `in_service[id] ← 1` /
> `pending[id] ← 0` updates happen on the **same hclk edge** as the
> AHB data-phase read. There is no intermediate exposed state: the
> next bus cycle observes both that the read returned the source ID
> and that the source is no longer pending. Because AHB serialises
> bus accesses, two contexts cannot claim simultaneously.

---

## Gateway and arbitration

### Level-triggered gateway

Each source has two state bits in `plic_pending`:

- `pending[s]` — set when the source line `irq_src_i[s]` rises and
  `in_service[s] = 0`. Stays set until cleared.
- `in_service[s]` — set on claim, cleared on complete.

Concretely, for each source `s`:

```
pending[s]    <= pending[s]    ? (claim_pulse & claim_id==s ? 0 : 1)
                              : (irq_src_i[s] & ~in_service[s]);
in_service[s] <=    set on (claim_pulse    & claim_id   ==s)
                  clear on (complete_pulse & complete_id==s);
```

This means:

- If a peripheral asserts and clears `irq_src_i[s]` in a single hclk
  (a pulse), `pending[s]` latches and survives — firmware will still
  see the IRQ.
- If `irq_src_i[s]` stays high across the whole IRQ lifetime, after
  complete clears `in_service[s]`, the next cycle re-sets
  `pending[s]` and the gateway re-fires. This is the canonical
  "level-triggered, re-trigger if still asserted" behaviour expected
  by Linux PLIC drivers and most embedded peripherals.

There is no edge-triggered mode in this revision of the IP — every
source is level-triggered. If edge support is ever needed, a per-source
mode register can be added without disturbing the layout (a 1-bit-per-source
field hung off an unused offset).

### Per-context arbiter

`plic_target` runs **two parallel max-priority arbiters** in one
combinational loop, each iterating sources high-to-low with `>=` so the
lowest source ID overwrites a tie:

- **Claim arbiter** — `pending & enable`. Threshold is **NOT** applied.
  This drives the claim/complete read data (`0x4`) and the
  `claim_source_id_o` pulse. Per PLIC 1.0.0 Chapter 8: *"The claim
  operation is not affected by the setting of the priority threshold
  register."*
- **IRQ arbiter** — `pending & enable & (priority > threshold)`. Drives
  `irq_o` to the hart. Per PLIC 1.0.0 Chapter 7: the PLIC masks
  interrupts of priority less than or equal to threshold (strict `>`).

A source with `priority = 0` never qualifies either arbiter — priorities
are unsigned, threshold is bounded `[0, 2^PRIO_BITS-1]`, and the strict
`>` comparison excludes priority 0 even at `threshold=0`. Source 0
additionally has its priority hard-tied 0 by `plic_priority`. If no
source qualifies the claim arbiter, the read returns `0` (per Chapter 8).

For the default case (1 hart × 2 contexts × 31 sources × 3-bit priority),
each per-context block synthesises into a couple of dozen LUTs. Area
scales linearly with `NUM_CONTEXTS × NUM_SOURCES`; at ~1000 sources we
would want a pipelined or time-multiplexed arbiter, but that's well
beyond the IP's target deployment envelope.

### Claim / Complete handshake

A read of `claim_complete[ctx]`:

1. The AHB data-phase delivers `top_source_id_o[ctx]` (the **claim**
   arbiter's choice — threshold-independent) zero-extended to 32 bits as
   the read data.
2. On the same hclk edge, `claim_pulse_o[ctx]` asserts with
   `claim_source_id_o[ctx] = top_source_id_o[ctx]`.
3. `plic_pending` consumes that pulse on the same edge:
   `in_service[id] ← 1`, `pending[id] ← 0`.

A write of `claim_complete[ctx]` with hwdata `N`:

1. `plic_target` checks that `N` is in range (`1 ≤ N ≤ NUM_SOURCES`)
   **and** that `enable_i[ctx][N] = 1` — i.e. the source is currently
   enabled for this context. Per PLIC 1.0.0 Chapter 9: *"If the
   completion ID does not match an interrupt source that is currently
   enabled for the target, the completion is silently ignored."*
2. If both checks pass, `complete_pulse_o[ctx]` asserts with
   `complete_source_id_o[ctx] = N[10:0]`. Otherwise the pulse is
   suppressed at the target — no state change reaches `plic_pending`.
3. `plic_pending` consumes accepted pulses: `in_service[N] ← 0`.

Per-context claim/complete pulses are OR-reduced at the top before
feeding `plic_pending`. This is safe because AHB serialises bus
accesses — at most one context's claim or complete pulse can be live
on any given cycle.

> **Belt and braces.** The top-level address decode at
> `ahb_plic.v` makes `in_target[ctx]` a strict equality on the per-context
> address bits (`dph_addr[20:12] == ctx[8:0]`), so at most one
> `plic_target` instance can have `reg_sel_i = 1` in any cycle by
> construction — independent of AHB serialisation. The OR-reduce at the
> top is therefore always a lossless combine, even under hypothetical
> bus misbehaviour (e.g. a multi-master fabric that incorrectly issued
> two transactions in the same cycle).

> **Don't disable a source mid-handler.** Per the spec, a completion
> targeting a source not currently enabled for the context is silently
> ignored (Chapter 9). The PLIC implements this faithfully — but the
> side-effect is that if firmware clears `enable[ctx][N]` between the
> claim and the complete of source `N`, the complete pulse is dropped
> and **`in_service[N]` stays high**. Source `N` then cannot trigger
> another interrupt until `in_service[N]` is cleared, and the only way
> to clear it is via an accepted complete — which requires re-enabling
> the source first. Recommended pattern: **always complete before
> disabling**. If a handler must disable a source it has just claimed,
> it must either (a) complete first, then disable, or (b) re-enable
> long enough to issue a complete before disabling permanently.

> **Single-source ownership across contexts.** The PLIC maintains a
> **single `in_service[s]` bit per source**, shared across all
> contexts (not a per-`(context, source)` array). This is
> spec-conformant — PLIC 1.0 Chapter 1.2 states that "at most one
> interrupt request per interrupt source can be pending in the PLIC
> core at any time" — but it relies on firmware to preserve the
> invariant. **Do not enable the same source for multiple contexts of
> the same hart** (e.g. both M-context and S-context). For
> M-supervises-S delegation, enable the source only on the S-context
> and use the core's `mideleg.SEI=1` to route the S-mode external
> interrupt; the M-context never sees the source in that pattern. A
> misconfiguration that enables a source for two contexts can produce
> a sequence where ctx1's complete clears `in_service[s]` while
> ctx0's handler is still mid-flight, after which the gateway can
> re-assert `pending[s]` from the still-asserted source line and
> deliver a duplicate notification while ctx0 still owns the source.
> Same rule applies across harts: each external source should have
> exactly one notification owner.

---

## Repository layout

```
ahb_plic/
├── rtl/verilog/
│   ├── ahb_plic.v                    Top-level AHB-Lite slave + sub-instances
│   ├── plic_priority.v               Per-source priority register file
│   ├── plic_pending.v                Pending + in_service flops, level gateway
│   ├── plic_enable.v                 Per-(context, source) enable matrix
│   ├── plic_target.v                 Per-context threshold + arbiter + claim
│   └── filelist.f                    RTL source list (consumed by both sim & synth)
├── sim/rtl_sim/
│   ├── bin/                          Sim runner + log parsers
│   └── run/                          Run wrappers (run_lint, waivers.vlt)
└── doc/
    ├── ahb_plic.md                   This document
    └── img/                          (reserved for future block diagrams)
```

---

## Verification

The IP ships with a standalone Verilog testbench at
`bench/verilog/tb_ahb_plic.v` driven by an AHB-Lite BFM. The sim runner
exposes per-test and sweep modes; both lint and sim sweeps cover the
parameter space (single / multi-hart, SU_MODE_EN on/off, varying
`NUM_SOURCES` and `PRIO_BITS`, and `PRIV_CHECK_EN` on/off).

```bash
cd sim/rtl_sim/run
./run_lint                # single-config lint (Verilator)
./run_lint -sweep         # lint sweep across the supported parameter grid
./run <test_name>         # run one sim test under the default config
./run_all -sweep          # full sim sweep -- all tests x all configs
```

Coverage at a glance (full list in `sim/rtl_sim/src/`):

| Area exercised                                    | Tests |
|---------------------------------------------------|-------|
| AHB register read / write, RAZ/WI of unmapped offsets | `priority_rdwr`, `priority_multiword`, `pending_multiword`, `enable_rdwr`, `enable_multiword`, `unmapped_access` |
| Gateway latching, claim/complete handshake        | `pending_gateway`, `threshold_claim`, `complete_invalid_id` |
| Threshold gating (strict `>`) and claim independence | `threshold_claim`, `claim_threshold_independent` |
| Multi-source priority arbitration + tie-break     | `arbiter_tiebreak` |
| Multi-context routing under `SU_MODE_EN` and multi-hart | `m_s_routing`, `multihart_routing`, `su_disabled` |
| Privilege filter — denial for S→M-ctx accesses    | `priv_check` |
| `PRIV_CHECK_EN=0` regression                      | `priv_check_off` |

In addition, the aRVern integration testbench at
`arvern/bench/verilog/tb_arvern.v` instantiates the PLIC as a 4 MB
slave at `0x0C00_0000` (SiFive / QEMU-virt convention) and runs
end-to-end firmware tests against the core ↔ PLIC interface — these
live in `arvern/sim/rtl_sim/src/trap_irq_plic_*.{s,v}` and cover
config + claim/complete, threshold gating, delegated SEI via ctx 1,
privilege-filter AHB ERROR, sub-word-size AHB ERROR, WFI wake via a
source rise, and a 4-deep pending-set drain in priority order.

---

## Synthesis

A Synopsys Design Compiler flow lives under `synthesis/synopsys/` and
follows the same pattern as the other `arvern-ips` blocks, with a
`LIB_FLAVOR` selector for technology setup.

```bash
cd synthesis/synopsys
./run_syn                          # default flavor (lib_default)
./run_syn -lib <flavor>            # synthesise with a specific library flavor
./run_syn -lib <flavor> -i         # interactive (keep dc_shell open after run)
./run_syn_d -lib <flavor>          # same, inside the dockerised DC image
```

Available `<flavor>` values are derived from the files present in
`synthesis/synopsys/libraries/setup_*.tcl` — running `./run_syn` with an
unknown flavor prints the full list. Out of the box the flow ships with
a `lib_default` flavor and a `lib_example` template; users add their own
technology by dropping a new `setup_<flavor>.tcl` next to the others.
Foundry `.db` files are referenced through symlinks under
`synthesis/synopsys/libraries/` so the same setup files can be shared
across multiple IPs (see `arvern-ips/README.md`).

The clock-period default in `constraints.tcl` is `15 ns (66 MHz)`. The
boundary I/O delays follow the standard register-bank slave convention
(`20%` of clock period on AHB inputs, `70%` on AHB outputs, `75%` on the
per-hart IRQ outputs and `hclk_en_o` since they drive the core's trap
priority encoder / the SoC ICG).

Outputs land in `synthesis/synopsys/results/`:

| File                              | Description                                     |
|-----------------------------------|-------------------------------------------------|
| `ahb_plic.gate.v`                 | Gate-level netlist                              |
| `ahb_plic.ddc`                    | Synopsys DDC database                           |
| `ahb_plic.spf`                    | DFT scan test protocol (when DFT enabled)       |
| `report.area`, `report.full_area` | Area summary (incl. NAND2-equivalent)           |
| `report.timing`, `report.paths.*` | Timing and worst-path reports                   |
| `report.constraints`              | Constraint compliance                           |
| `report.dft_*`                    | DFT DRC, coverage, scan-chain configuration     |
| `synthesis.log`                   | Full dc_shell transcript                        |

---

## License

BSD 3-Clause — see [`LICENSE`](../../LICENSE) at the repo root.
