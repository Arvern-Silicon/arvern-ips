<p align="center">
  <img src="../../arv_custom_csr/doc/img/aRVern_light.png" alt="aRVern" width="180">
</p>

# apb_i2s

*A lightweight serial-audio master (I2S, left- and right-justified, DSP/PCM) with transmit
and receive FIFOs, on an APB4 completer port.*

`apb_i2s` plays and records 16-bit audio through a serial audio link of which it is the
clock master: it generates the master clock (`MCLK`), the bit clock (`BCLK`) and the
word clock (`LRCK`) from its own APB clock with integer dividers, in any of the common
serial-audio formats selected by software (*Frame format*), shifts a transmit
stream out on `i2s_sd_o` and shifts a receive stream in on `i2s_sd_i`. Samples are
exchanged with software through two flip-flop FIFOs, as 16-bit stereo pairs or as
packed 16-bit mono samples, with software-set FIFO thresholds and an interrupt.

It is built for amplifiers, DACs and ADCs that are clock slaves, such as a class-D
amplifier with an I2S input (no master clock needed) or a codec pair that needs a master
clock at a fixed multiple of the sample rate. The sample rate is whatever the dividers
make of the APB clock: exact standard rates come from an APB clock that is a multiple of
them (24.576 MHz for 48 kHz, 22.5792 MHz for 44.1 kHz), other clocks give near-standard
rates.

The shift engine (`apb_i2s_core`: clock generator, serialiser, deserialiser) has a
frame-level stream interface of its own, independent of APB and of the FIFOs (*Shift
engine*). Access is gated by privilege level with an `MDELEG` register, as in
[`apb_periph_example`](../../apb_periph_example/doc/apb_periph_example.md). The bus port
is APB4, for a place behind [`ahb_apb_bridge`](../../ahb_apb_bridge/doc/ahb_apb_bridge.md).

Out of scope: clock-slave operation (`BCLK` and `LRCK` as inputs), sample widths other
than 16 bits in memory, TDM, DMA and any signal processing.

---

## Parameters

| Parameter | Default | Range | Meaning |
|---|---|---|---|
| `TX_EN` | `1` | 0, 1 | Transmit path present. `0`: no transmit FIFO, `i2s_sd_o` held low, `TXDATA` and the transmit fields read 0. |
| `RX_EN` | `1` | 0, 1 | Receive path present. `0`: no receive FIFO, `i2s_sd_i` unused, `RXDATA` and the receive fields read 0. |
| `TX_FIFO_AW` | `5` | 1–8 | Transmit FIFO depth, `1 << TX_FIFO_AW` 32-bit words (32 by default). |
| `RX_FIFO_AW` | `5` | 1–8 | Receive FIFO depth, `1 << RX_FIFO_AW` 32-bit words. |
| `ADDRW` | `7` | 7–16 | APB address width; the register window is `1 << ADDRW` bytes. 7 is the smallest window that holds `MDELEG` at `0x40`. |
| `MDELEG_RST` | `9'h10F` | see *Access protection* | Reset value of `MDELEG[8:0]`, as in `apb_periph_example`. |
| `DBG_PMASTER_MASK` | `4'b1000` | any | `PMASTER` bits that identify a debugger access (see *Debugger accesses*); `4'b0000` treats every access as the core's. |
| `ASYNC_RST_EN` | `1` | 0, 1 | Reset style: `1` asynchronous active-low, `0` synchronous. Behaviour is identical. |

`TX_EN = RX_EN = 0` is illegal. An illegal value stops simulation and lint elaboration
(checks inside `translate_off`).

---

## Ports

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `pclk_i` | in | 1 | APB clock, also the audio timebase; gated by an external ICG driven by `pclk_en_o` (see *Clock request*) |
| `presetn_i` | in | 1 | Active-low reset, style per `ASYNC_RST_EN`; de-assertion synchronous to `pclk_i`. With `ASYNC_RST_EN = 0` the clock must run during reset (the SoC reset generator requests it) |
| `pclk_en_o` | out | 1 | Clock request for the external ICG (see *Clock request*) |
| `psel_i`, `penable_i`, `paddr_i[ADDRW-1:0]`, `pwrite_i`, `pwdata_i[31:0]`, `pstrb_i[3:0]`, `pprot_i[2:0]`, `psmode_i` | in | | APB4 requester signals and the aRVern S-mode sideband, as in `apb_gpio` |
| `pmaster_i` | in | 4 | Manager ID of the transfer, with the timing of `PPROT` (`ahb_apb_bridge`'s `pmaster_o`, the fabric's `HMASTER`); tie 0 without one |
| `prdata_o[31:0]`, `pready_o`, `pslverr_o` | out | | APB4 completer response; `pready_o` is always 1 |
| `i2s_mclk_o` | out | 1 | Master clock, `pclk / (2·MDIV)` while running with `CTRL.MCLK_EN`, else low |
| `i2s_bclk_o` | out | 1 | Bit clock, 64 or 32 × the sample rate (`FORMAT.SLOT16`) while running, else at its idle level |
| `i2s_lrck_o` | out | 1 | Word clock / frame sync (sample rate), shape and polarity per `FORMAT` while running, else at its idle level |
| `i2s_sd_o` | out | 1 | Transmit data, launched on the `BCLK` launch edge (`FORMAT.BCLK_INV`); low while stopped |
| `i2s_sd_i` | in | 1 | Receive data (see *Receive timing*) |
| `irq_o` | out | 1 | Interrupt: OR of `IRQ_PEND & IRQ_EN` |

All five audio outputs are flop outputs in the `pclk_i` domain. They are data signals for
the IP and clocks only for the devices they drive; no logic of the IP is clocked by them.

---

## Clocks and sample rate

One counter in the `pclk_i` domain produces every audio clock:

```
MCLK half-period = MDIV pclk cycles                   (CLKDIV.MDIV, 1–256)
LRCK period      = 2 · S BCLK periods                 (two slots of S = 32 or 16 bits)
BCLK half-period = MDIV · RATIO / (2 · S) pclk cycles (RATIO = MCLK / LRCK)
Fs               = pclk / (2 · MDIV · RATIO)
```

`RATIO` is 256, 384, 512, 768 or 1024 (`CLKDIV.RATIO`), so with 32-bit slots the bit clock
is the master clock divided by 4, 6, 8, 12 or 16, and with 16-bit slots by 8, 12, 16, 24
or 32: always an integer, always with a 50 % duty cycle, and every `BCLK` and `LRCK` edge
coincides with an `MCLK` edge. The master clock is an even division of `pclk_i`, so its
duty cycle is 50 % too. The receive path needs a `BCLK` half-period of at least 4
`pclk_i` cycles (`MDIV = 1`, `RATIO = 256`, 32-bit slots); the devices' setup and hold
against the half-period usually bind first at a fast `pclk_i` (*Timing and
integration*).

The table shows the arithmetic, not device support: which `RATIO`, sample rate and `MCLK`
a device accepts is in its data sheet (the two integration examples below give their
ranges).

| `pclk_i` | `MDIV` | `RATIO` | `MCLK` | Fs |
|---|---|---|---|---|
| 24.576 MHz | 1 | 256 | 12.288 MHz | **48.000 kHz** |
| 24.576 MHz | 1 | 512 | 12.288 MHz | 24.000 kHz |
| 22.5792 MHz | 1 | 256 | 11.2896 MHz | **44.100 kHz** |
| 33.333 MHz | 1 | 384 | 16.667 MHz | 43.40 kHz |
| 33.333 MHz | 1 | 512 | 16.667 MHz | 32.55 kHz |
| 33.333 MHz | 2 | 384 | 8.333 MHz | 21.70 kHz |
| 50 MHz | 2 | 256 | 12.5 MHz | 48.83 kHz |
| 98.304 MHz | 4 | 256 | 12.288 MHz | **48.000 kHz** |
| 200 MHz | 8 | 256 | 12.5 MHz | 48.83 kHz (+1.7 %) |
| 200 MHz | 49 | 256 | 2.041 MHz | 7.97 kHz |

The master clock is at most `pclk_i / 2`, so an exact 48 kHz needs `pclk_i` at
24.576 MHz or a multiple. A device without a master-clock input ignores `i2s_mclk_o`
(`CTRL.MCLK_EN = 0` holds it low).

### Start, stop and idle levels

- **Start.** Setting `CTRL.EN` with the engine stopped launches the first frame on the
  next `pclk_i` edge: `LRCK` moves from its idle (right-slot) level to the left-slot
  level, or pulses, and `BCLK` leaves its idle level half a `BCLK` period later with a
  sampling edge. `STATUS.RUNNING` reads 1 from then on.
- **Stop.** Clearing `CTRL.EN` lets the engine finish the frame in progress: the next
  frame boundary passed with `EN` clear ends the stream, and the engine stops on the
  launch edge of position *D* (*D* = 1 with `DELAY = 1`, so the delayed last bit of the
  frame is sent and received; *D* = 0 otherwise), where every output takes its idle
  level. No `BCLK` or `MCLK` pulse is ever shortened. `STATUS.RUNNING` stays 1 for one
  more `BCLK` half-period (the tail), in which the last bit is captured (see *Receive
  timing*), and falls at its end; a start requested in the tail is launched on the edge
  after it. Setting `EN` again before the stop edge keeps the stream running without a
  break; with `DELAY = 1`, once the boundary has passed with `EN` clear, the frame it
  started is sent as zeros (without `TX_UNDER`).
- **Idle levels.** `BCLK` at the level after a launch edge (`BCLK_INV = 0`: low; `1`:
  high); `LRCK` at the right-slot level (`LRCK_INV = 0`: high, `1`: low) or, with `FSYNC`,
  the non-pulse level; `MCLK` and `SD` low. A `FORMAT` write while stopped moves the idle
  levels on the edge after the write, a clean flop transition. After reset the outputs
  are at the idle levels of the reset `FORMAT` (I2S: `BCLK` low, `LRCK` high).
- **`MCLK_EN`** may change at any time; it takes effect at the next `MCLK` toggle
  instant, so no partial `MCLK` pulse is produced.
- `CLKDIV`, `FORMAT` and `CTRL.LOOPBACK` writes are ignored while `CTRL.EN` or
  `STATUS.RUNNING` is 1 (the values before the write: a single write that sets `EN` and
  `LOOPBACK` together is honoured); they read back their stored value, so a read after
  the write shows whether it took.

A stopped `BCLK` puts the amplifier of the first integration example in standby, and a
static `MCLK` puts the converters of the second in power-down: `EN = 0` is the low-power
state, `TX_ON = 0` with `EN = 1` is silence with the devices awake. Devices recommend some
frames of zeros before a stop or a rate change (clear `TX_ON` first), and consume the
first frames after a start while they lock.

### Clock request

```
pclk_en_o = psel_i | CTRL.EN | STATUS.RUNNING | (a transfer ended on the last edge)
```

The audio clocks run from `pclk_i`, so the IP keeps its clock while it streams and until
the engine has stopped. Every effect of a bus transfer — a register write, a FIFO push or
pop and the update of the FIFO's registered head word, a flush, a W1C — completes on the
edge that ends the transfer's ACCESS cycle; the extra edge after a transfer lets the idle
output levels follow a `FORMAT` write. With the engine stopped and no transfer, nothing in
the IP changes: the FIFOs, the interrupt and every register hold. The request carries no
reset term; the SoC reset generator requests every clock during reset.

`pclk_en_o` must reach the ICG that gates `pclk_i`: in the one-gate topology of
`ahb_apb_bridge` (the bridge's request gates the completers), OR it into the gate enable,
or give the IP a gate of its own. Without it the audio stops whenever the bus is idle.

---

## Frame format

A frame is two slots, left then right, of 32 bits (`BCLK` = 64 Fs) or 16 bits
(`BCLK` = 32 Fs). Samples are 16 bits, MSB first. Six fields of the `FORMAT` register
describe the frame, and together they cover the common formats:

| Field | Values |
|---|---|
| `DELAY` | First data bit on the frame / slot edge (0) or one `BCLK` period after it (1) |
| `RJUST` | Sample in the first 16 bits of a 32-bit slot (0, left-justified) or the last 16 (1, right-justified); no effect with 16-bit slots. Right-justified 32-bit slots ignore `DELAY` (the sample always ends on the slot edge) |
| `LRCK_INV` | Left slot while `LRCK` is low (0) or high (1); with `FSYNC`, the frame-sync pulse is high (0) or low (1) |
| `FSYNC` | `LRCK` is a 50 % word clock (0) or a one-`BCLK` frame-sync pulse at the start of the left slot (1, DSP / PCM modes) |
| `BCLK_INV` | Data launched on the falling `BCLK` edge and sampled on the rising one (0), or the reverse (1); also sets the idle level of `BCLK` |
| `SLOT16` | 32-bit slots (0) or 16-bit slots (1) |

| Common format | `DELAY` | `RJUST` | `LRCK_INV` | `FSYNC` | `BCLK_INV` | `SLOT16` |
|---|---|---|---|---|---|---|
| I2S (Philips) | 1 | 0 | 0 | 0 | 0 | 0 |
| I2S, 16-bit slots (32 Fs) | 1 | 0 | 0 | 0 | 0 | 1 |
| Left-justified (MSB-justified) | 0 | 0 | 1 | 0 | 0 | 0 |
| Right-justified 16-bit (LSB-justified) | 0 | 1 | 1 | 0 | 0 | 0 |
| DSP / PCM mode A | 1 | 0 | 0 | 1 | 0 | 0 or 1 |
| DSP / PCM mode B | 0 | 0 | 0 | 1 | 0 | 0 or 1 |

With `DELAY = 1` the sample is positioned one `BCLK` after the slot edge whatever the
slot size. In 32-bit slots it occupies bits 1–16 of the slot. In 16-bit slots it
occupies bits 1–15 of its slot and bit 0 of the next slot: the LSB of the right sample is
sent in the first `BCLK` of the next frame, which is also where a DSP-A frame-sync pulse
falls. The frame boundary for `TX_ON`, `RX_ON` and the FIFO handshake stays the frame
edge (`LRCK` edge or pulse); the serialiser sends the straddling LSB after the boundary
(of the last frame too, see *Stop*), and the deserialiser delivers the word one `BCLK`
after the boundary. In the DSP modes the slots keep their layout; with 16-bit slots the
right sample follows the left one directly, the usual DSP-mode frame.

In a 32-bit slot the 16 bits not carrying the sample are sent as zeros; on receive they
are ignored, so a 24-bit left-justified source is truncated to its 16 MSBs (a
right-justified 24-bit source is not supported).

## Sample packing

| Mode | One 32-bit FIFO word | Words per frame |
|---|---|---|
| Stereo (`TX_MONO`/`RX_MONO` = 0) | `[15:0]` left, `[31:16]` right | 1 |
| Mono (`TX_MONO`/`RX_MONO` = 1) | `[15:0]` sample *n*, `[31:16]` sample *n+1* | ½ |

Mono transmit sends each sample in both slots, so a mono amplifier set to play the left,
the right or the average channel plays it. Mono receive keeps the left slot, the right
slot or their average (`CTRL.RX_MONO_SEL`, arithmetic right shift of the 17-bit sum,
rounding toward −∞) and packs two consecutive samples per word. Mono doubles the time a
FIFO of a given depth lasts; an `int16_t` buffer streams with word stores.

## Transmit and receive

- **Transmit.** At the start of each frame the serialiser takes the next word from the
  transmit FIFO. When `CTRL.TX_ON` is set the stream starts at the next frame boundary,
  so software fills the FIFO first. If the FIFO is empty at a frame boundary, the frame
  is sent as zeros (silence) and `TX_UNDER` is set. Clearing `TX_ON` finishes the current
  frame, then sends zeros.
- **Receive.** A frame is received when `CTRL.RX_ON` is set as its first stream bit is
  captured (half a `BCLK` period plus `RX_DLY + 2` cycles after the frame boundary, one
  `BCLK` period later with `DELAY = 1`); at its end the deserialiser delivers it and a
  word is pushed into the receive FIFO (in mono, every second frame). If the FIFO is full
  the word is dropped and `RX_OVER` is set. Clearing `RX_ON` completes the frame in
  progress, and so does a stop.
- **Stream state.**
  - *Mono transmit:* the word at the head of the FIFO sends its lower half in one frame
    and its upper half in the next, then leaves the FIFO. On an underrun both slots are
    zero and the next boundary tries again, so a word written later starts with its lower
    half (the pair re-aligns). Clearing `TX_ON` with an upper half still to send discards
    it (the word leaves the FIFO).
  - *Mono receive:* the first sample of a pair is held until the second arrives. A flush,
    or the stream becoming inactive (`RX_ON` 0 and no frame in progress), drops a held
    first sample.
  - *Flush* (`CMD`): empties the FIFO and the mono half state; the frame in progress in
    the shift engine is still sent or delivered (a received word reaching the FIFO in
    the flush cycle itself is discarded); the sticky flags are kept.
  - *Same-cycle push and pop:* both take effect. A `TXDATA` write is refused when the
    FIFO is full at the start of the cycle, even if the serialiser takes a word in that
    cycle.
  - `TX_MONO` changes only while `TX_ON` is 0, `RX_MONO` and `RX_MONO_SEL` only while
    `RX_ON` is 0 (the values before the write; a single write that sets `TX_ON` and
    `TX_MONO` together is honoured).
  - `STATUS.TX_ACTIVE` and `RX_ACTIVE` read 1 while the frame being sent (received) was
    started with `TX_ON` (`RX_ON`) set; after a stop both read 0 once `RUNNING` has
    fallen.
- **Loopback.** `CTRL.LOOPBACK` (with both paths) feeds the serialiser output to the
  receive synchroniser in place of `i2s_sd_i`, so the receive timing below applies with
  a zero round trip; `i2s_sd_o` is still driven.

### Receive timing

`i2s_sd_i` comes from a device clocked by `i2s_bclk_o`. It crosses a two-flop synchroniser
(`arv_synchronizer`, reset value 0, the idle level of a serial-audio data line), and the
deserialiser keeps the **pad value at the `pclk_i` edge `RX_DLY` cycles after the `BCLK`
sampling edge** (`CLKDIV.RX_DLY`, 0–15, reset 0); the synchroniser output carries that
value two cycles later, when it is captured. With `T` the `pclk_i` period, `H` the `BCLK`
half-period in cycles, `t_rt` the round trip from the `BCLK` flop through the output pad
and the trace to the device and back from its data output to the input pad, and the
device launching its data on the launch edge, the bit is captured correctly when

```
t_rt + t_co,max + t_setup  <  (H + RX_DLY) · T        (setup side)
RX_DLY · T                 <  H · T + t_rt + t_co,min  (hold side: before the next bit)
```

and `RX_DLY + 2` must not exceed the `BCLK` period (`2·H`) in cycles. A device specified
with a valid window around its view of the sampling edge (such as the CS5343: data valid
10 ns before to 40 ns after `SCLK` rising) fits the same formulas with `t_co,max = H·T −
10 ns` and `t_co,min = 40 ns − H·T`, so its hold side reads `RX_DLY · T < t_rt + 40 ns`. `RX_DLY = 0` samples the pad at the `BCLK` sampling
edge itself; a Pmod-length link through FPGA pads at 33 MHz wants `RX_DLY = 1`, at 200 MHz
about 3.

---

## Register map

All registers are 32 bits. Offsets not listed read 0 and ignore writes. A write to a
register updates the byte lanes `PSTRB` selects (`IRQ_PEND` W1C and `CMD` act on lane 0);
`TXDATA` accepts whole words only (`PSTRB = 4'hF`): any other write to it pushes nothing
and sets no flag. Reads return the whole word.

| Offset | Name | Access | Reset | Meaning |
|---|---|---|---|---|
| `0x00` | `INFO` | RO | — | Build parameters (see below) |
| `0x04` | `CTRL` | RW | `0` | Control (see below) |
| `0x08` | `CLKDIV` | RW | `0` | `[7:0]` `MDIV`−1, `[10:8]` `RATIO`: 0 = 256, 1 = 384, 2 = 512, 3 = 768, 4 = 1024 (5–7 store 0), `[15:12]` `RX_DLY` |
| `0x0C` | `STATUS` | RO | `0` | `[8:0]` transmit FIFO level, `[24:16]` receive FIFO level, in words; `[29]` `RX_ACTIVE`, `[30]` `TX_ACTIVE`, `[31]` `RUNNING` |
| `0x10` | `THRESH` | RW | `0` | `[8:0]` `TX_THR`, `[24:16]` `RX_THR`, in words (stored on 9 bits whatever the depth) |
| `0x14` | `IRQ_EN` | RW | `0` | Interrupt enables, one bit per `IRQ_PEND` bit |
| `0x18` | `IRQ_PEND` | RO / RW1C | see below | Interrupt causes (see below) |
| `0x1C` | `TXDATA` | WO | — | A whole-word write pushes `PWDATA` into the transmit FIFO; reads 0 |
| `0x20` | `RXDATA` | RO | `0` | A read pops the receive FIFO; reads 0 when empty |
| `0x24` | `CMD` | WO | — | Writing 1: `[0]` flush the transmit FIFO, `[1]` flush the receive FIFO; reads 0 |
| `0x28` | `FORMAT` | RW | `0x2` (I2S) | `[0]` `BCLK_INV`, `[1]` `DELAY`, `[2]` `RJUST`, `[3]` `LRCK_INV`, `[4]` `FSYNC`, `[5]` `SLOT16` (see *Frame format*) |
| `0x40` | `MDELEG` | RW (M-mode only) | `MDELEG_RST` | Privilege gates (see *Access protection*) |

The fields of an absent path read 0 and ignore writes: with `TX_EN = 0`, `TX_ON`,
`TX_MONO`, `LOOPBACK`, `TX_THR`, `STATUS[8:0]`, `TX_ACTIVE` and the transmit bits of
`IRQ_EN` / `IRQ_PEND` (`[0]`, `[2]`, `[4]`); with `RX_EN = 0` the receive mirror, plus
`RX_DLY` and `DBG_POP`.

**`CTRL`**

| Bits | Field | Meaning |
|---|---|---|
| `[0]` | `EN` | Run the clock generator (see *Start, stop and idle levels*) |
| `[1]` | `TX_ON` | Transmit stream on (from the next frame boundary) |
| `[2]` | `RX_ON` | Receive stream on (from the next frame) |
| `[3]` | `MCLK_EN` | Drive `i2s_mclk_o` |
| `[5]` | `TX_MONO` | Transmit FIFO words hold two mono samples |
| `[6]` | `RX_MONO` | Receive FIFO words hold two mono samples |
| `[9:8]` | `RX_MONO_SEL` | Mono receive source: 0 = left, 1 = right, 2 = average (3 stores 0) |
| `[12]` | `LOOPBACK` | Serialiser output looped to the receive synchroniser (both paths only) |
| `[13]` | `DBG_POP` | A debugger read of `RXDATA` pops the FIFO like a core read (see *Debugger accesses*) |

**`IRQ_PEND`**

| Bit | Name | Kind | Set when |
|---|---|---|---|
| `[0]` | `TX_LOW` | level, RO | transmit FIFO level ≤ `TX_THR` |
| `[1]` | `RX_HIGH` | level, RO | receive FIFO level ≥ `RX_THR` and `RX_THR` ≥ 1 |
| `[2]` | `TX_UNDER` | sticky, RW1C | a frame was sent as zeros for lack of data while `TX_ON` |
| `[3]` | `RX_OVER` | sticky, RW1C | a received word was dropped, FIFO full |
| `[4]` | `TX_OVF` | sticky, RW1C | a whole-word write to `TXDATA` found the FIFO full (word dropped) |
| `[5]` | `RX_UDF` | sticky, RW1C | a read of `RXDATA` found the FIFO empty |

The two level causes clear themselves as software fills or drains the FIFO; writes of 1
to them are ignored. A sticky cause set in the same cycle as its W1C stays set. From
reset `TX_LOW` reads 1 with a transmit path (empty FIFO, threshold 0), harmless while
`IRQ_EN` is 0. `TX_THR` ≥ the depth makes `TX_LOW` permanent and `RX_THR` = 0 or above
the depth disables `RX_HIGH`: use `TX_THR` < depth and 1 ≤ `RX_THR` ≤ depth. The end of a
recording can leave up to `RX_THR − 1` words that never raise `RX_HIGH`: software drains
them by level after clearing `RX_ON`.

Against a level-triggered PLIC gateway, a handler services the FIFO until the level cause
drops, clears the sticky causes, then completes; at the end of a playback `TX_LOW` is
masked in `IRQ_EN`, or the gateway re-pends on every completion. `irq_o` is an AND-OR of
registers in the gated `pclk_i` domain; every cause is raised on an edge the IP itself
requested, so the line is stable whenever the clock is gated.

**`INFO`**

| Bits | Field | Value |
|---|---|---|
| `[3:0]` | `TX_FIFO_AW` | The parameter (0 with `TX_EN = 0`) |
| `[7:4]` | `RX_FIFO_AW` | The parameter (0 with `RX_EN = 0`) |
| `[8]` | `TX_EN` | The parameter |
| `[9]` | `RX_EN` | The parameter |
| `[10]` | `DBG` | `DBG_PMASTER_MASK` is not 0: debugger reads of `RXDATA` follow `DBG_POP` |
| `[31:28]` | `VERSION` | `1` |

### Debugger accesses

A transfer whose `pmaster_i` has any bit of `DBG_PMASTER_MASK` set is a debugger access
(the aRVern Debug Module tags its system-bus accesses with `HMASTER` bit 3, which
`ahb_apb_bridge` forwards on `pmaster_o`). With `CTRL.DBG_POP = 0`, a debugger read of
`RXDATA` returns the word at the head of the receive FIFO without popping it and without
setting `RX_UDF` (0 when the FIFO is empty at the ACCESS edge), so a memory view in a
debugger does not disturb the stream. With `CTRL.DBG_POP = 1` a debugger read pops like a
core read, so a debug setup can pull the received stream through the debug link. Every
other register, and every debugger write, behaves as for the core. A debugger access
passes `MDELEG` like any other: the aRVern Debug Module presents Machine mode.

---

## Access protection

`MDELEG` at `0x40`, with the layout, encoding and behaviour of
[`apb_periph_example`](../../apb_periph_example/doc/apb_periph_example.md#mdeleg-register-layout):
`WR_PRIV[1:0]`, `RD_PRIV[3:2]`, `RESP[8]`; a refused access changes nothing (a refused
`RXDATA` read pops nothing, a refused `TXDATA` write pushes nothing), reads 0 and gets
`PSLVERR` with `RESP = 1`.

---

## Shift engine

`apb_i2s_core` is the clock generator, serialiser and deserialiser, with no bus, no FIFO
and no interrupt; `apb_i2s` adds those. Its interface, all in `clk_i`:

| Group | Signals |
|---|---|
| Configuration (stable while running) | `mdiv_i[7:0]`, `ratio_i[2:0]`, `rx_dly_i[3:0]`, `bclk_inv_i`, `delay_i`, `rjust_i`, `lrck_inv_i`, `fsync_i`, `slot16_i`, `loopback_i` |
| Control | `run_i`, `running_o` (high until the end of the tail), `mclk_en_i` |
| Transmit | `tx_on_i`, `tx_valid_i`, `tx_data_i[31:0]` (`{right, left}`), `tx_take_o` (pulse at the frame boundary: the frame is taken), `tx_under_o` (pulse: a frame of zeros sent while `tx_on_i`), `tx_active_o` |
| Receive | `rx_on_i`, `rx_valid_o` (pulse), `rx_data_o[31:0]` (`{right, left}`), `rx_active_o` |
| Pins | `i2s_mclk_o`, `i2s_bclk_o`, `i2s_lrck_o`, `i2s_sd_o`, `i2s_sd_i` |

The stream interface is one 16-bit stereo frame per handshake; the mono packing, the
averaging and the FIFO policy are the wrapper's. Parameters: `TX_EN` and `RX_EN` (an
absent path drives its outputs low and ignores its inputs) and `ASYNC_RST_EN`.

---

## Timing and integration

Every audio output is a flop output and every multiplexer is a flat AND-OR structure,
so the IP has no long path of its own. Each FIFO has a registered head word, so the read
path does not grow with the depth (a 256-word FIFO is a 256-to-1 selection feeding only
the head register). The IP is meant to close timing at the APB clock of the SoC, up to
about 200 MHz in a current ASIC technology.

`i2s_mclk_o`, `i2s_bclk_o` and `i2s_lrck_o` are clocks for the devices they drive: the SoC
constraints declare them as generated clocks of `pclk_i` for the fastest setting the
board uses (`MDIV` and `RATIO` are registers, the constraint is per SoC), and `i2s_sd_o`
as an output relative to `i2s_bclk_o`. `i2s_sd_i` lands only on a synchroniser and is a
false path for STA; its budget is the board-level one of *Receive timing*. Transmit
setup and hold at the device are a `BCLK` half-period minus pad skew; at a fast `pclk_i`
the devices' own minimums bind before the 4-cycle receive limit (for example a 20 ns
setup and hold at 200 MHz needs a half-period of more than 4 cycles). The master clock can
reach `pclk_i / 2`, but audio devices rarely accept more than about 25–50 MHz. The audio
pins are ordinary LVCMOS pads.

## Integration examples

**Class-D amplifier with an I2S input** (a mono amplifier that needs no master clock,
such as the MAX98357A on the Sipeed Tang Console board): `i2s_bclk_o` → `BCLK`,
`i2s_lrck_o` → `LRCLK`, `i2s_sd_o` → `DIN`; `FORMAT` = I2S (32-bit or 16-bit slots),
`MCLK_EN = 0`, `TX_MONO = 1` for mono content. The amplifier's shutdown / channel-select
pin (`SD_MODE`) is a GPIO of the SoC. The MAX98357A accepts a bit clock of 32, 48 or 64 ×
the sample rate, sample rates around 8, 16, 32–50 and 88–100 kHz only (not 11–24 kHz),
and enters standby by itself when `BCLK` stops.

**DAC and ADC pair with a shared clock set** (a stereo DAC and a stereo ADC that are both
clock slaves and need a master clock, such as the Digilent Pmod I2S2): `i2s_mclk_o`,
`i2s_lrck_o` and `i2s_bclk_o` drive both converters' clock inputs (the Pmod has separate
pins per converter: drive both, or join them on the board), `i2s_sd_o` the DAC's data
input and `i2s_sd_i` comes from the ADC's data output; `FORMAT` = I2S with 32-bit slots
(the ADC needs 48 or 64 `BCLK` per frame), `MCLK_EN = 1`, the ADC set as clock slave
(jumper `JP1` on `SLV`). The ratios both converters accept: 256 and 384 at 4–50 kHz, 512
and 768 at 42–54 kHz, never 1024. At 33.333 MHz, `MDIV = 1`, `RATIO = 384` gives 43.40 kHz
inside every range of both converters and of the amplifier above.

A board that carries several devices on one `apb_i2s` (both examples above are standard
I2S) can drive them together; devices of different formats are served one at a time,
with the format of the active one.

---

## Software

`sw/` holds the register map (`apb_i2s_regs.h`) and a driver (`apb_i2s.h`,
`src/apb_i2s.c`, functions prefixed `apb_i2s_`): rate selection from a `pclk` frequency,
format, stream start and stop, FIFO fill and drain, thresholds and interrupts, and the
`MDELEG` gates.

---

## Verification

`bench/verilog/tb_apb_i2s.v` drives the IP from an APB4 requester (`apb_tasks.v`:
transfers back to back or separated by idle cycles, random bus values while `PSEL` is
low, a `PMASTER` per transfer) with the bus clock gated by `pclk_en_o` alone. The device
model (`i2s_dev.v`), written from this document:

- checks the clocks cycle by cycle: every `MCLK` and `BCLK` half-period, the start edge,
  the stop on the launch edge of position *D* after the boundary passed with `EN` clear,
  with every output idle, the tail, the idle levels while stopped, and that `LRCK` and
  `SD` change only on launch edges;
- decodes `i2s_sd_o` from the `FORMAT` definition (slot edges, delay, justification,
  pulse polarity, straddling LSB), checks `LRCK` at every sampling edge and that the bits
  outside the sample field are 0;
- drives `i2s_sd_i` with its own frames after a programmable round trip.

Tests compare the decoded frames with the words written and the words read with the
source frames, in stereo and in the three mono modes. Always-on checks cover `PSLVERR`,
`PRDATA` outside an ACCESS cycle, `PREADY` and `pclk_en_o` against its formula.

The sweep runs 25 tests over 13 configurations (both paths and each alone, FIFO depths
2 to 256, window width, `MDELEG` reset value, debugger mask, reset style), with 48
functional cover bins that must all be hit: every named format, both slot sizes and
clock polarities, every `RATIO`, the mono modes, underrun, overrun and the two FIFO
programming errors, the level interrupts, debugger peek and pop, loopback, flushes,
full FIFOs, a `CLKDIV` / `FORMAT` write while running, a W1C racing a new event, a stop
after a delayed last bit, a capture in the tail and a mono half discarded on a take
edge, on top of the bus-level set. `stop_timing` clears `EN` at every position of a frame
for delayed and undelayed formats with the receive sampling point at its limit. The register-space walk (every `RATIO` × slot size at several
`MDIV`, every format × polarity, the receive sampling point on both sides of its budget,
every FIFO entry with both patterns) is in the tests rather than in the configurations.
Coverage is 100 % of lines, branches and toggles; the waived points (constants by
construction, and the receive-side signals of a build without a receive path) are argued
in `sim/rtl_sim/run/waivers_cov.md`.

```bash
cd sim/rtl_sim/run
./run <test> [-config <label>]   # one test
./run_all                        # the regression configurations
./run_all -sweep                 # every test on every configuration (bin/sim_configs.py)
./run_all -cov                   # Verilator line / branch / toggle coverage
./run_lint -sweep                # Verilator lint on every parameter set (bin/rtl_configs.py)
```

## Synthesis

The Design Compiler flow lives under `synthesis/synopsys/` (`./run_syn`, `-rtl_config`,
`-rtl_sweep`, `./run_check_reset_style`), with the family's `LIB_FLAVOR` mechanism:
create `libraries/setup_lib_default.tcl` from `setup_lib_example.tcl` first.
