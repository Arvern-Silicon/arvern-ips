<p align="center">
  <img src="../../arv_custom_csr/doc/img/aRVern_light.png" alt="aRVern" width="180">
</p>

# apb_spi

*A lightweight SPI controller (single, dual and quad lanes) with transmit and receive
FIFOs, on an APB4 completer port.*

`apb_spi` is the controller (master) of a serial peripheral bus: it generates the serial
clock `SCK` from its own APB clock with an integer divider, drives up to eight chip
selects, shifts frames out and in on one, two or four data lanes, and exchanges the data
with software through two flip-flop FIFOs, with software-set thresholds and an interrupt.
Every frame is described by a small attribute word that travels with it through the
transmit FIFO (*Transfers*): which chip select, whether that chip select stays asserted
afterwards, the lane width, the frame length, and whether the frame is sent, received,
clocked without data or polled for a condition. A transaction of any structure — an SD
command followed by a response poll, a data token, 512 bytes and a busy poll, or a
quad-flash read with its command, address, mode bits, dummy cycles and data on different
lane widths — is therefore a sequence of FIFO entries under one chip select, pushed by
software at its own pace: the serial clock stops between entries when the FIFO runs
empty and resumes when the next entry arrives.

It is built for an SD card in SPI mode, a quad or dual SPI NOR flash, and the ordinary
SPI devices of a small system (sensors, ADCs, DACs, displays, radios, including 3-wire
half-duplex devices that share one data line), on the same bus or on separate chip
selects. The bus port is APB4, for a place behind
[`ahb_apb_bridge`](../../ahb_apb_bridge/doc/ahb_apb_bridge.md); access is gated by
privilege level with an `MDELEG` register, as in
[`apb_periph_example`](../../apb_periph_example/doc/apb_periph_example.md).

Out of scope: target (slave) operation, DMA requests, a memory-mapped (XIP) read port,
double-data-rate modes, hardware CRC, and any protocol above the frame level (the SD
command set and the flash command set are the driver's). Without hardware CRC the driver
runs the SD card in its default CRC-off mode and the data link is unprotected; the two
CRCs the card always checks (CMD0, CMD8) are constants.

---

## Parameters

| Parameter | Default | Range | Meaning |
|---|---|---|---|
| `LANES_MAX` | `4` | 1, 2, 4 | Widest lane mode built: `1` single lane only, `2` adds dual, `4` adds quad. An entry asking for a wider mode is refused (`XFER_ERR`). The four `spi_io_o` / `spi_io_oe_o` bits exist in every build (see *Lanes and pads*); `spi_io_i[3:2]` are unused with `LANES_MAX < 4`, and `spi_io_i[1:0]` are read in every build (IO1, or IO0 with `RX_IO0`, is the single-lane receive lane). |
| `CS_NR` | `1` | 1–8 | Number of chip-select outputs. An entry naming `CS_SEL` ≥ `CS_NR` is refused. |
| `RX_EN` | `1` | 0, 1 | Receive path present. `0`: no receive FIFO and no input synchronisers; `RX` and `POLL` entries and `CAPT` are refused, `RXDATA` and the receive fields read 0. |
| `POLL_EN` | `1` | 0, 1 | `POLL` entries supported (needs `RX_EN = 1`). `0`: a `POLL` entry is refused. |
| `TX_FIFO_AW` | `4` | 1–8 | Transmit FIFO depth, `1 << TX_FIFO_AW` entries (16 by default); each entry is a 32-bit payload and its 16-bit attribute word. |
| `RX_FIFO_AW` | `4` | 1–8 | Receive FIFO depth, `1 << RX_FIFO_AW` 32-bit words. |
| `ADDRW` | `7` | 7–16 | APB address width; the register window is `1 << ADDRW` bytes. 7 is the smallest window that holds `MDELEG` at `0x60`. |
| `MDELEG_RST` | `9'h10F` | see *Access protection* | Reset value of `MDELEG[8:0]`, as in `apb_periph_example`: bits `[7:4]` must be 0 and neither privilege field may hold the reserved `2'b10`. |
| `DBG_PMASTER_MASK` | `4'b1000` | any | `PMASTER` bits that identify a debugger access (see *Debugger accesses*); `4'b0000` treats every access as the core's. |
| `ASYNC_RST_EN` | `1` | 0, 1 | Reset style: `1` asynchronous active-low, `0` synchronous. Behaviour is identical. |

`POLL_EN = 1` with `RX_EN = 0` is illegal, as is any value outside the ranges above
(`LANES_MAX`, `CS_NR`, `RX_EN`, `POLL_EN`, `TX_FIFO_AW`, `RX_FIFO_AW`, `ADDRW`, `MDELEG_RST`,
`ASYNC_RST_EN`). An illegal value stops simulation and lint elaboration (checks inside
`translate_off`). `LANES_MAX`, `CS_NR`, `RX_EN` and `POLL_EN` select generate branches
and size the attribute decode, the lane multiplexers and the chip-select outputs; the
others are widths or constants.

---

## Ports

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `pclk_i` | in | 1 | APB clock, also the serial-clock timebase; gated by an external ICG driven by `pclk_en_o` (see *Clock request*) |
| `presetn_i` | in | 1 | Active-low reset, style per `ASYNC_RST_EN`; de-assertion synchronous to `pclk_i`. With `ASYNC_RST_EN = 0` the clock must run during reset (the SoC reset generator requests it) |
| `pclk_en_o` | out | 1 | Clock request for the external ICG (see *Clock request*) |
| `psel_i`, `penable_i`, `paddr_i[ADDRW-1:0]`, `pwrite_i`, `pwdata_i[31:0]`, `pstrb_i[3:0]`, `pprot_i[2:0]`, `psmode_i` | in | | APB4 requester signals and the aRVern S-mode sideband, as in `apb_gpio` |
| `pmaster_i` | in | 4 | Manager ID of the transfer, with the timing of `PPROT` (`ahb_apb_bridge`'s `pmaster_o`, the fabric's `HMASTER`); tie 0 without one |
| `prdata_o[31:0]`, `pready_o`, `pslverr_o` | out | | APB4 completer response; `pready_o` is always 1 |
| `spi_sck_o` | out | 1 | Serial clock: `pclk / (2·HALF)` while a frame is shifting, else at the `CPOL` idle level |
| `spi_cs_o` | out | `CS_NR` | Chip selects, one per device, polarity per `CSCFG.CSPOL` (active low by default); all inactive after reset |
| `spi_io_o` | out | 4 | Data-lane output values: `[0]` MOSI / IO0, `[1]` MISO / IO1, `[2]` IO2 (WP#), `[3]` IO3 (HOLD#) |
| `spi_io_oe_o` | out | 4 | Data-lane output enables, 1 = drive the pad (see *Lanes and pads*) |
| `spi_io_i` | in | 4 | Data-lane input values from the pads (see *Receive timing*); the unused bits per `LANES_MAX`, all unused with `RX_EN = 0` |
| `irq_o` | out | 1 | Interrupt: OR of `IRQ_PEND & IRQ_EN` |

Every serial output is a flop output in the `pclk_i` domain: `spi_sck_o` is a data signal
for the IP and a clock only for the devices it drives; no logic of the IP is clocked by
it.

**Pins out of reset.** From the reset edge (the first requested edge with
`ASYNC_RST_EN = 0`) the IP *drives* its bus to the idle state: `spi_sck_o` low (`CPOL`
reset 0), every `spi_cs_o` inactive (`CSPOL` reset 0: all high), IO0 driven high
(`TX_IDLE` reset 1), IO2 and IO3 driven high (`IO23_REL` reset 0), IO1 an input
(`spi_io_oe_o = 4'b1101`, `spi_io_o = 4'b1101`). This differs from `apb_gpio`, whose
pins are released until software says otherwise: these pins belong to a bus protocol
whose devices need defined idle levels before any software runs — a flash must see HOLD#
high or it pauses (`S25FL128S_256S` §3.9), and the SD card wants its data-in line high
during the power-up clocks (`SD_PLS_v6.00` §6.4.1.1). A board on which another master owns
the lines at boot, or that multiplexes them through `apb_gpio` alternate functions, keeps
the pads released at the pad multiplexer until it hands them over. The four `spi_io_o` /
`spi_io_oe_o` bits exist and follow these rules in every `LANES_MAX` build, so a
single-lane flash board still gets HOLD# and WP# driven high.

The pads, their pull resistors, drive strength, slew rate and Schmitt inputs belong to
the SoC's pad controller or to the FPGA constraints, as for `apb_gpio`; the IP provides
the value, the output enable and takes the input.

---

## Clocks and serial clock

One counter in the `pclk_i` domain produces the serial clock:

```
SCK half-period = HALF pclk cycles         (HALF = CLKDIV.DIV + 1, 1–4096)
SCK             = pclk / (2 · HALF)
```

`SCK` is therefore at most `pclk / 2` and always has a 50 % duty cycle; every `SCK` edge
is a `pclk_i` edge. The chip-select setup, hold and inactive times (`CSCFG`) are counted
in `SCK` half-periods, so they scale with the divider. `pclk_i` is the SoC's choice; the
table is a guide, with example clocks showing the arithmetic and what each rate reaches.
The device data sheet says what it accepts (the two integration examples give their
limits), and *Receive timing* says which `pclk_i` can sample which link.

| `pclk_i` | `DIV` | `HALF` | `SCK` | Use |
|---|---|---|---|---|
| 50 MHz | 0 | 1 | 25 MHz | SD default-speed maximum, flash, most devices |
| 50 MHz | 62 | 63 | 396.8 kHz | SD identification (100–400 kHz) |
| 100 MHz | 0 | 1 | 50 MHz | flash; **not** SD high speed (the 10 ns sampling grid cannot be placed in the card's 8.5 ns window, see *Receive timing*) |
| 100 MHz | 1 | 2 | 25 MHz | SD default-speed maximum |
| 100 MHz | 124 | 125 | 400 kHz | SD identification |
| 200 MHz | 1 | 2 | 50 MHz | SD high speed (`pclk_i` ≥ about 133 MHz), flash |
| 200 MHz | 3 | 4 | 25 MHz | SD default-speed maximum |
| 200 MHz | 249 | 250 | 400 kHz | SD identification |
| 200 MHz | 4095 | 4096 | 24.4 kHz | slowest |

An SD card is identified at the identification clock rate fOD (`SD_PLS_v6.00` §4.2,
"During the card identification process, the card shall operate in the SD clock
frequency of the identification clock rate fOD"), 100–400 kHz, and run at up to 25 MHz in
default speed mode or 50 MHz in high-speed mode (§2, "Default Speed mode: 3.3V signaling,
Frequency up to 25 MHz", "High Speed mode: 3.3V signaling, Frequency up to 50 MHz"); the
SPI mode uses the same bus timing (§7.8, "Bus timing is identical to SD mode"). The SD bus
frequency "can be changed at any time" (§4.4); while the card initialises after ACMD41 the
host either keeps a continuous 100–400 kHz clock or polls at less than 50 ms intervals
(§4.4, "1) Issue continuous clock in the frequency range of 100 KHz-400 KHz. If the host
wants to stop the clock, poll busy bit by ACMD41 command at less than 50 ms intervals"),
which the entry model satisfies either way.

### Divider changes

`CLKDIV` may be written at any time and reads back its stored value. The engine latches
`CLKDIV`, `CSCFG` and the clock mode (`CTRL.CPOL`, `CPHA`, `LSB_FIRST`, `BSWAP`) **when it
starts a transaction** — when it takes an entry while no chip select is asserted — and
keeps those values until the chip select is released. A write during a transaction
therefore takes effect at the next one, never in the middle of a frame or between two
frames of the same chip-select assertion; a write on the very edge a transaction starts
applies from the next one too. The safe point for the SD
identification-to-full-speed change is thus any time; the new rate is in force from the
next command.

The idle levels follow a write whenever no transaction holds them: a `CTRL.CPOL` write
moves `spi_sck_o` to the new idle level on the write's ACCESS edge, a clean flop
transition, unless a chip select is asserted or a `CS_NONE` transaction is open (from its
start until its hold time ends, setup, pauses and waits included: its `SCK` keeps the
polarity it started with); a `CSCFG.CSPOL` write moves the chip selects
likewise whenever none is asserted (`STATUS.CS_ACTIVE = 0`, whether or not the engine is
otherwise busy). With a chip select asserted the write is stored, `spi_sck_o` and the asserted select do not
move — a device that counts clocks from its selection (the SD card, `SD_PLS_v6.00` §7.2)
sees no spurious edge — and the pins take the stored level on the edge that releases the
select, before the inactive time, so the next assertion finds `SCK` at its idle level and
`SETUP` is measured from a quiet clock (a mode-3 flash sees `SCK` high in standby,
`S25FL128S_256S` §4.1.1: "SCK will stay at logic high state with CPOL = 1, CPHA = 1"). The
engine's own copy is latched at transaction start as above.

### Clock request

```
pclk_en_o = psel_i | STATUS.BUSY | (transmit FIFO not empty & CTRL.EN)
```

`BUSY` is "the engine has work that needs clock edges": from the take of an entry, or from
an `ABORT` written while a chip select is held, until the last capture of the entry has
reached the receive FIFO (the receive tail) **and** the chip select has been released or,
with `CS_HOLD`, the entry's last frame has ended; a stall inside an entry is part of
it. An entry waiting at the head of the transmit FIFO with the engine enabled requests the
clock too, whether it is waiting for receive room, for the inactive time or for nothing. A
select held across an empty FIFO, or an engine with `EN = 0` and nothing in progress,
requests no clock: the next bus transfer brings the edges. The inactive time (`INACT`)
counts requested edges only, so under a gated clock it may stretch; it is a minimum in
edges, not in time.

Every effect of a bus transfer — a register write, a FIFO push or pop and the update of
the FIFO's registered head word, a flush, a W1C, the move of an idle output to a new
`CPOL` / `CSPOL` / `TX_IDLE` / `IO23_REL` level — completes on the edge that ends the
transfer's ACCESS cycle. Every event the engine raises (`DONE`, `POLL_TO`, a receive
push) is raised on the edge that ends the work that causes it, never one edge later, so
no edge is ever needed that the request does not cover. With the engine idle and no
transfer, nothing in the IP changes. The request carries no reset term; the SoC reset
generator requests every clock during reset.

`pclk_en_o` must reach the ICG that gates `pclk_i`: in the one-gate topology of
`ahb_apb_bridge` (the bridge's request gates the completers), OR it into the gate enable,
or give the IP a gate of its own. Without it a transaction stops whenever the bus is idle.

---

## Transfers

Software describes each frame in the `XFER` register, then pushes its payload into
`TXDATA`; the push copies `XFER[15:0]` into the FIFO entry beside the payload, so a
sequence of entries with different attributes is queued without a race against the
engine. `XFER` and the `TXDATA` write that uses it are one critical section between
software contexts: a handler that pushes entries saves and restores `XFER`, or owns the
FIFO alone (the driver's entry builders do the save and restore). The engine takes
entries in order while `CTRL.EN` is 1 and executes each to completion.

### Entry attributes (`XFER`)

| Bits | Field | Meaning |
|---|---|---|
| `[4:0]` | `BITS` | Frame length − 1: 1 to 32 bits per frame (a 32-bit frame carries four bytes, most significant byte first unless `BSWAP`) |
| `[6:5]` | `LANES` | 0 = single (IO0 out, IO1 or IO0 in), 1 = dual (IO0–IO1), 2 = quad (IO0–IO3); 3 is refused |
| `[7]` | — | Stores 0, reads 0; a 1 written here is not an error (reserved for a later build) |
| `[9:8]` | `KIND` | 0 = `TX`, 1 = `RX`, 2 = `DUMMY`, 3 = `POLL` (see below) |
| `[10]` | `CAPT` | `TX` only, single lane: also capture the frame received (full duplex). Ignored for other kinds and for dual / quad |
| `[11]` | `CS_HOLD` | Keep the chip select asserted after this entry; the next entry continues the transaction (see *Chip selects*). Ignored with `CS_NONE` |
| `[12]` | `CS_NONE` | No chip select for this entry: the serial clock and the lanes run with every `spi_cs_o` inactive |
| `[15:13]` | `CS_SEL` | Chip select of the entry, 0 to `CS_NR` − 1 |

| `KIND` | Payload (`PWDATA`) | On the lanes | Into the receive FIFO |
|---|---|---|---|
| `TX` | the frame, in `[BITS:0]` | the frame is driven out on the lane(s) | with `CAPT` (single lane): the frame received at the same time |
| `RX` | `[15:0]` = frame count − 1 (1–65536 frames) | single lane: IO0 at its idle state (`TX_IDLE`: driven or released); dual / quad: the lanes are released and read | one word per frame |
| `DUMMY` | `[15:0]` = clock count − 1 (1–65536 `SCK` periods) | single lane: IO0 at its idle state; dual / quad: the lanes released | nothing |
| `POLL` | `[15:0]` = maximum frame count − 1 (1–65536), `[23:16]` = value, `[31:24]` = mask | as `RX`, with a pause after every frame (see *Polling*) | the first frame whose low byte satisfies `(frame[7:0] & mask) != value`, or the last frame if none qualifies (then `POLL_TO` is set) |

A `DUMMY` is counted in clock periods, not frames, because flash read-latency periods are
not byte multiples (`S25FL128S_256S` Table 8.10: "Quad I/O Read … Dummy 1 / 4 / 4 / 5"
cycles by latency code); every other kind is counted in frames. Multi-lane frames carry
`LANES` bits per clock, the least significant of each group on IO0 and the groups in
most-to-least significant order (the flash convention: "Within the dual or quad groups the
least significant bit is on IO0 … transferred in most to least significant bit order",
`S25FL128S_256S` §4.2); with `LSB_FIRST` the group order is reversed and bit 0 of each
group is still on IO0.

**Refused entries.** A `TXDATA` write whose `XFER` is illegal pushes nothing and sets
`IRQ_PEND.XFER_ERR`: `LANES = 3`; `LANES` wider than `LANES_MAX`; `BITS + 1` not a multiple
of the lane count (2 or 4); `CS_SEL ≥ CS_NR` without `CS_NONE`; `KIND = RX` or `POLL`, or
`CAPT`, with `RX_EN = 0`; `KIND = POLL` with `POLL_EN = 0`. The check happens at the push,
against the `XFER` value of the push, so the error is reported to the transfer that made
it. A `TXDATA` write with `PSTRB ≠ 4'hF` pushes nothing and sets no flag: it is a
malformed bus access, not an illegal entry, and the family treats it the same way in every
FIFO register (`apb_i2s`). A legal entry written into a full FIFO pushes nothing and sets
`TX_OVF`; an illegal one sets `XFER_ERR` only, full or not.

### Frame format and clock modes

| `CTRL` field | Meaning |
|---|---|
| `CPOL` | `SCK` idle level: 0 = low, 1 = high. The *leading* edge of a clock period is the edge away from idle, the *trailing* edge the edge back to it |
| `CPHA` | 0: the first bit of a frame is launched when the chip select asserts (or, for a following frame, on the trailing edge that ends the previous bit) and every bit is sampled on the leading edge. 1: bits are launched on the leading edge and sampled on the trailing edge |
| `LSB_FIRST` | 0: bit `BITS` of the payload goes first, a received frame's first bit lands at bit `BITS`. 1: bit 0 goes first and a received frame's first bit lands at bit 0 |
| `BSWAP` | 1: the byte order of the payload word, and of the received word, is reversed for frames of 16, 24 or 32 bits (byte 0 ↔ byte 1 / 2 / 3), so a little-endian buffer streams with word stores and loads; `LSB_FIRST` and the lane-group rule then apply to the swapped word. Thus `BSWAP` alone sends byte 0 first, MSB first within it; `LSB_FIRST` alone sends byte 0 first, LSB first; both together send byte 3 (2, 1) first, LSB first. Frames of other lengths are unaffected |

All four `CPOL` / `CPHA` modes are supported; the pairs `(0,0)` and `(1,1)` are the SD and
flash modes (the SD card samples its input on the rising clock edge and launches its
output on the falling one, `SD_PLS_v6.00` Figures 6-10 and 6-11; the flash accepts "Mode 0
with CPOL = 0 and CPHA = 0" and "Mode 3 with CPOL = 1 and CPHA = 1", `S25FL128S_256S`
§4.1.1). A received frame is right-aligned in its FIFO word, the bits above `BITS` 0. The
transmit payload bits above `BITS` are ignored.

Frames of one entry, and consecutive entries under one chip select, follow each other with
no gap: the launch of a frame's first bit coincides with the edge that ends the previous
frame's last bit. Two exceptions: a `POLL` frame is followed by the engine's evaluation
pause (*Polling*, which names the edge on which the next frame launches), and the serial
clock stops at its idle level, with the chip select unchanged, whenever the engine has
nothing to do (the transmit FIFO is empty, the engine is disabled or stalled); it resumes
with the next entry. **Resuming** after any such pause, with `CPHA = 0` the first bit of the
next frame and the lane output enables are launched on the resume edge and the leading
edge follows `HALF` cycles later, so the device sees a full half-period of setup, as after
`SETUP` for the first frame of a transaction; with `CPHA = 1` the leading edge itself and
the first bit are on the resume edge, as in a gap-free frame (the device samples on the
trailing edge `HALF` later, and `SCK` has been idle for at least `HALF` before the
resume). A device that answered the previous frame keeps driving its last bit until the
next leading edge with `CPHA = 1`, so launching earlier would collide with it. The SPI
devices this IP targets are static: an SD card counts clocks from the chip-select
assertion and needs only that every token is a multiple of eight clocks (`SD_PLS_v6.00`
§7.2, "The card starts to count SPI bus clock cycle at the assertion of the CS signal.
Every command or data token shall be aligned with 8-clock cycle boundary"), and the flash
has no minimum clock frequency ("SCK Clock Frequency … Min DC", `S25FL128S_256S` Table 6.4).

### Polling

A `POLL` entry clocks frames until one satisfies `(frame[7:0] & mask) != value`, pushes
that frame only, and ends; if its frame count runs out first, the last frame is pushed
and `POLL_TO` is set (a frame that qualifies on the last allowed try is a normal end, not a
timeout). The mask and value travel in the entry's payload (`[31:24]`, `[23:16]`), so a
transaction may queue polls for different conditions back to back (an SD command's R1
wait, its start-token wait and its busy wait); the compare is on the frame's low byte,
which for a frame of 8 bits or more is its last byte received with `LSB_FIRST = 0`. The
engine knows whether a frame qualifies only once the frame has been
captured: its last sampling edge is at cycle *E*, the pad value is taken `RX_DLY` cycles
later, crosses the two synchroniser stages and is shifted in on edge `E + RX_DLY + 2`;
the compare is formed on the assembled word in that cycle (the word the receive-FIFO
write uses) and registered on the same edge, beside the push decision, so it is valid
after `E + RX_DLY + 2`. The engine therefore **pauses after every `POLL` frame** until
edge `P = max(E + HALF, E + RX_DLY + 3)`; `E + HALF` is the frame's end (the trailing edge
with `CPHA = 0`, the instant of the next leading edge with `CPHA = 1`). When
`P = E + HALF` there is no pause: the next frame follows as without polling. Otherwise
`SCK` waits at its idle level with the chip select unchanged (the lanes follow the
end-of-frame rule of *Lanes and pads*) and on `P` the engine either ends the entry or
resumes, under the resume rule, with the next poll frame or the next queued entry. The
`SCK` idle time between two poll frames is thus `max(HALF, RX_DLY + 3)` cycles in either
clock phase, never shorter than a half-period; at `HALF = 1` and `RX_DLY = 1` an 8-bit
poll frame takes 19 cycles instead of 16. No frame after the terminating one is
ever clocked, so the byte that follows an SD start-block token is the first byte the next
`RX` entry receives. The pause is legal for the devices polled: the SD card counts clocks
from its selection and needs only byte alignment, which whole frames keep (`SD_PLS_v6.00`
§7.2, quoted above), and the flash accepts a stopped clock at any time ("SCK Clock
Frequency … Min DC", `S25FL128S_256S` Table 6.4) and streams its status "by providing
multiples of eight clock cycles" (§10, RDSR1). A `POLL` frame reserves receive room like
any capturing frame (*Transmit, receive and status*), so a full receive FIFO stalls a
busy poll with the select held, and the card waits.

### Chip selects

An entry asserts `CS_SEL` if no chip select is asserted, or continues under it if the
previous entry ended with `CS_HOLD` on the same select. When the previous entry ended with
`CS_HOLD` and the new entry names a different select, or `CS_NONE`, the engine first
releases the held select with the normal hold and inactive timing, then starts the entry.
An entry with `CS_HOLD = 0` releases its select when it completes; one with `CS_HOLD = 1`
leaves it asserted indefinitely, waiting for the next entry (the transmit FIFO may run
empty and software may take its time: an SD card is read as command, response poll, token
poll, data and CRC entries under one assertion, pushed as the FIFO drains). `CMD.ABORT`
releases a held select without a following entry.

`CSCFG` sets the timing, in `SCK` half-periods (`HALF` `pclk_i` cycles each):

- **`SETUP`** (1–16): from the assertion of the chip select to the first `SCK` edge. With
  `CPHA = 0` the first bit is already on the lanes from the assertion.
- **`HOLD`** (1–16): from the last `SCK` edge of the transaction to the release of the
  chip select. With `CPHA = 0` the last edge is the trailing edge after the last sampled
  bit; with `CPHA = 1` it is the trailing edge that samples the last bit. It is exact
  when the release follows the last frame directly; when the engine has paused first (a
  `POLL` evaluation, a held select across an empty FIFO, an `ABORT`) the hold time is
  counted from the end of the pause, so it is a minimum measured from the last edge.
- **`INACT`** (1–16): minimum number of requested clock edges, in half-periods, with
  every chip select inactive before the next assertion. It is a minimum: the next entry
  may arrive later, and under a gated clock the edges are counted only while the clock
  runs.
- **`CSPOL[7:0]`**: 1 makes `spi_cs_o[n]` active high. Bits at and above `CS_NR` are
  stored but unused.

The defaults (one half-period each) satisfy the flash's 3 ns setup and hold at any rate
("tCSS CS# Active Setup Time 3 ns min, tCSH CS# Active Hold Time 3 ns min",
`S25FL128S_256S` Table 6.4) and its 10 ns inactive time for reads; a page program or erase
wants 50 ns inactive ("tCS CS# High Time (Read Instructions) 10, (Program/Erase) 50 ns"),
which at 50 MHz is `INACT = 5`. The SD card has no chip-select timing of its own ("The
timing of the CS signal is the same as any other card input", `SD_PLS_v6.00` §7.8).

Clocks with no chip select — the SD power-up requirement of at least 74 clocks with CS
high and the data-in line high (`SD_PLS_v6.00` §6.4.1.1: "start to supply at least 74 SD
clocks to the SD card with keeping CMD line to high. In case of SPI mode, CS shall be held
to high during 74 clock cycles") — are a `DUMMY` entry with `CS_NONE`, single lane, with
`TX_IDLE = 1`: it drives IO0 high and clocks without touching any select. A `CS_NONE`
entry is a transaction of its own (it latches the configuration, and ends with the
inactive time).

### Lanes and pads

The IP drives the pads through `spi_io_o` / `spi_io_oe_o` and reads `spi_io_i`; the
bidirectional buffer and the pull resistors are the SoC's. What each lane does:

| Lane | Single | Dual | Quad | Not a data lane |
|---|---|---|---|---|
| IO0 | out: the frame; otherwise (idle, `RX`, `DUMMY`, `POLL`) its idle state per `TX_IDLE`: driven low, driven high, or released | out during `TX`, released during `RX` / `DUMMY` / `POLL` | as dual | — |
| IO1 | in (never driven); the receive lane unless `RX_IO0` | as IO0 | as IO0 | — |
| IO2, IO3 | per `IO23_REL` | per `IO23_REL` | as IO0 | `IO23_REL = 0`: driven high; `1`: released |

**Half-duplex (3-wire) devices** share one data line (a display's `SDA`, a MEMS sensor in
`SIM` mode): `TX_IDLE = 2` releases IO0 whenever it carries no transmit frame, and
`CTRL.RX_IO0 = 1` makes single-lane `RX`, `POLL` and `CAPT` frames read IO0 instead of
IO1. The device's read is then an `RX` entry on the released IO0. With `RX_IO0 = 0` IO1 is
the receive lane and IO0's idle state is free to be driven (the SD and flash setting).

**End of a frame.** `HALF` cycles after a frame's last sampling edge — the trailing edge
that ends it with `CPHA = 0`, the instant at which a following frame's leading edge would
fall with `CPHA = 1` (the last bit is held through its trailing-edge sample) — every lane
returns to its no-frame state, whether or not a frame follows: IO0 per `TX_IDLE`, IO1
released, IO2 / IO3 per `IO23_REL`, except that **a lane a dual or quad frame of the
transaction has used stays released until the select is released**: a later frame drives
it while it carries data, and at that frame's end it returns to released, not to its
`TX_IDLE` / `IO23_REL` level.
A device may go on driving those lanes: a flash streams the next data nibble on the
falling edge after the last one read, or starts driving after its latency cycles, and a
host that took the lanes back to their idle levels would collide with it whenever the next
entry is not queued in time. A frame launched on that same edge takes its lanes over on
it, so the gap-free case changes nothing; a frame that nothing follows leaves the lanes
in their no-frame state until the next launch, which on a 3-wire device is the
turnaround: IO0 is released from that instant, and the device may drive from the next
clock. Output enables and lane values therefore change only at a frame's launch instant
(the trailing edge that ends the previous frame with `CPHA = 0`, the leading edge with
`CPHA = 1`, or the resume edge after a pause), at the end-of-frame instant above, on the
edge an `ABORT` ends a setup (a `CPHA = 0` first group returns to the no-frame state),
when the chip select releases, and on the ACCESS edge of a `TX_IDLE` / `IO23_REL` write for a
lane that carries no frame data; between a transmit entry and a receive entry under one
select the lanes are released at the end-of-frame instant, as early as the protocol
allows. A `TX` + `CAPT` frame with `RX_IO0 = 1` captures the host's
own drive on IO0 (harmless, and of no use). The flash asks the host to "stop driving the IO signals on
the falling edge at the end of the last latency cycle" and recommends releasing them
"during all latency cycles so that there is sufficient time for the host drivers to turn
off before the memory begins to drive" (`S25FL128S_256S` §4.3.16): a `DUMMY` entry of the
device's latency, in the lane width of the read, does exactly that. With zero latency
cycles the host's turn-off and the device's turn-on coincide on the same edge; the IP
cannot do better, and the device data sheet decides whether that is acceptable.

IO2 and IO3 are the flash's WP# and HOLD# when it is not in quad mode. HOLD# low pauses
the flash ("The Hold condition starts on the falling edge of the Hold (HOLD#) signal …
whenever the SCK signal reaches the logic low state", `S25FL128S_256S` §3.9), so a
single-lane transaction with a flash must see IO3 high: the default `IO23_REL = 0` drives
IO2 and IO3 high whenever they are not data lanes, from reset on. Both pins carry an
internal pull-up on the flash ("The signal has an internal pull-up resistor and may be
left unconnected in the host system if not used for Quad commands", Table 3.1), so a
board that would rather leave them to that pull-up, or that uses the pins for something
else, sets `IO23_REL = 1`. In quad mode the flash ignores the WP# and HOLD# functions
("The WP# and HOLD# inputs are not monitored for their normal functions and are internally
set to high (inactive)", §8.5.2 CR1 `QUAD`). An SD card in SPI mode has no use for IO2
and IO3 (its pins 8 and 9 are "RSV" in SPI mode, `SD_PLS_v6.00` Table 3-1, §3.7.1); they
may be driven high or released.

Lines a device leaves undriven (MISO between transactions, the lanes during a latency
period) are held by the SoC's pull-ups, which the SD card and the flash both expect.

### Transmit, receive and status

- **Transmit FIFO.** Entries are taken in order, one at a time, when the engine is enabled
  (`CTRL.EN`), the inactive time of the previous chip-select release has elapsed, the
  previous transaction's last capture has reached the receive FIFO (its receive tail,
  at most `RX_DLY + 2` cycles; a new transaction latches a new `RX_DLY`) and, for an
  entry that captures, the receive FIFO has room (see below). Within a transaction the
  next entry needs no such wait. An entry leaves the
  FIFO when it starts, so `STATUS` counts the entries not yet started. `EN` cleared lets
  the entry in progress complete, chip-select hold included, and takes no further entry.
- **Receive FIFO.** Each captured frame is pushed as a 32-bit word when its last bit has
  been captured (`RX_DLY + 2` `pclk_i` cycles after the last sampling edge, see *Receive
  timing*). The engine never drops a received word: it starts a capturing frame only when
  `receive level + frames in flight < depth`, where a frame is in flight from its start
  until its capture completes, whether it is then pushed or, as a non-terminating `POLL`
  frame, discarded; otherwise it stalls, with the serial clock idle and the chip select
  unchanged, and `STATUS.STALL` reads 1 until software pops. The check is made at each
  frame start from registered state: a pop in the same cycle counts from the next frame.
  The in-flight count covers a receive sampling point that lands after the next frame
  has started. `STALL` reads 1 while a capturing frame is held back for receive room —
  an entry waiting to start for that reason, or an entry stalled between its frames —
  and the engine keeps its clock in both cases; waiting for the inactive time or for
  `EN` is not a stall.
- **`STATUS.BUSY`** is defined under *Clock request*. **`STATUS.CS_ACTIVE`** reads 1 while
  a chip select is asserted, held included. **`STATUS.IDLE`** =
  `~BUSY & ~CS_ACTIVE & transmit FIFO empty` is the one bit that says the bus is free:
  `IRQ_PEND.DONE` is set on the edge on which `IDLE` rises, and only then — a `TXDATA` push
  landing on the edge that releases the last select keeps `IDLE` low and that transaction
  gets no `DONE` of its own (the next one's `DONE` covers it).
- **Flush** (`CMD`): `TX_FLUSH` empties the transmit FIFO, an entry waiting to start (for
  receive room or for the inactive time) included; the entry in progress completes.
  `RX_FLUSH` empties the receive FIFO (a word reaching it in the flush cycle is
  discarded); frames in flight still arrive afterwards. The sticky flags are kept.
- **Abort** (`CMD.ABORT`): the entry in progress ends at its next frame boundary (a
  `DUMMY` at its next clock period; a `POLL` in its pause, or an entry stalled between
  frames, ends at once), the frame in
  flight is still delivered, the transmit FIFO is emptied, and the chip select is released
  with the hold and inactive timing as if the entry had `CS_HOLD = 0`. An `ABORT` during
  the setup time of a select produces no clock edge and releases the select after the hold
  time. An `ABORT` with a select held and nothing in progress starts the release on its
  ACCESS edge and makes the engine `BUSY` until the select is released, so the release
  completes under a gated clock. An `ABORT` with nothing in progress and no select held
  empties the transmit FIFO and does nothing else. For a timed-out SD operation this is the recovery path; the card is then
  re-initialised by the driver.
- **Same-cycle push and pop:** both take effect. A `TXDATA` write is refused when the
  FIFO is full at the start of the cycle, even if the engine takes an entry in that cycle.
- **Loopback.** `CTRL.LOOPBACK` feeds the IO0 output register into the input synchroniser
  of the single-lane receive lane (IO1, or IO0 with `RX_IO0`) in place of the pad, so
  single-lane `TX` + `CAPT` frames return their own payload with the receive timing of a
  zero round trip; the pads are still driven. Dual and quad frames always read the pads.

Writes to `CTRL.TX_IDLE` and `IO23_REL` take effect on the write's ACCESS edge wherever
the lane is not carrying frame data, a held select included (a level change on an idle
lane is harmless to the devices this IP targets; a driver that wants none writes them
while no select is asserted). `CTRL.CPOL`, `CPHA`, `LSB_FIRST`, `BSWAP`, `CLKDIV` and `CSCFG` are latched
at each transaction start (*Divider changes*); `RX_IO0` and `LOOPBACK` are sampled at
each frame start; `XFER` is sampled by each `TXDATA` push.

### Receive timing

`spi_io_i` comes from a device clocked by `spi_sck_o`. Each used lane crosses a
two-flop synchroniser (`arv_synchronizer`, `W = 1` per lane, reset value 1, the idle level
of a pulled-up SPI line), and the deserialiser keeps the **pad value at the `pclk_i` edge
`RX_DLY` cycles after the sampling edge** (`CLKDIV.RX_DLY`, 0–15, reset 0); the
synchroniser output carries that value two cycles later, when it is shifted in. The reset
value matters only to a receiver that detects edges, which this one never does: a
push-pull device whose output idles low shows the synchroniser a transition at reset that
nothing observes. The four lanes are synchronised independently; their coherence as a
nibble comes from the sampling budget below, not from the synchronisers. With `T` the
`pclk_i` period, `H` = `HALF`, `rt` the round trip from the `SCK` flop through the output
pad and the trace to the device and back from its data output to the input pad, and
`t_su` / `t_h` the setup and hold of the first synchroniser flop, a bit is captured
correctly when

```
rt + t_co,max + t_su  <  (H + RX_DLY) · T        (setup side)
RX_DLY · T + t_h      <  H · T + rt + t_ho,min    (hold side: before the next bit)
```

for a device that launches each bit on the edge opposite to the sampling edge (the
trailing edge with `CPHA = 0`, the leading edge with `CPHA = 1`) with a clock-to-output of
`t_co` and holds it `t_ho` after its next launch edge; the formulas are the same in both
phases with the two edges' roles swapped. `RX_DLY = 0` samples the pad at the sampling
edge itself; `RX_DLY ≥ 2·H` samples inside the next bit period, which the hold side allows
when `rt` is long. The budgets of the two target devices, from the data sheets:

- **SD card, default speed** (≤ 25 MHz): the card output becomes valid at most 14 ns after
  the **falling** clock edge and holds at least 0 ns after the next falling edge
  (`SD_PLS_v6.00` Figure 6-11, "14ns(max.)" from the falling edge, "0ns(min.)" after the
  following falling edge). With `CPOL = 0` that is `t_co,max = 14 ns`, `t_ho,min = 0`, and
  the window at the pad is `[E − H·T + 14 ns + rt, E + H·T + rt]` around the sampling
  edge `E`, so the sampling point `E + RX_DLY·T` needs
  `rt − H·T + 14 ns ≤ RX_DLY·T ≤ rt + H·T` (less `t_su + t_h`). At 25 MHz (`H·T = 20 ns`)
  the window is `[E − 6 ns + rt, E + 20 ns + rt]`: `RX_DLY = 0` works for `rt` up to
  about 6 ns, and a longer round trip takes `RX_DLY·T` between `rt − 6 ns` and
  `rt + 20 ns` (`RX_DLY = 1` from a 50 MHz `pclk_i` covers `rt` from 0 to about 26 ns).
  At 16.67 MHz (`H·T = 30 ns`) it is `[E − 16 ns + rt, E + 30 ns + rt]`.
- **SD card, high-speed mode** (≤ 50 MHz): the card output becomes valid at most 14 ns
  after the **rising** clock edge and holds at least 2.5 ns after the *next* rising edge
  (Figure 6-13, "14ns(max.)" from the 50 % point of the rising edge, "2.5ns(min.)" after
  the following rising edge): the card launches bit *i* on the rising edge that samples
  bit *i − 1*, and the host samples it on the next rising edge. The window at the pad is
  `[E − 2·H·T + 14 ns + rt, E + 2.5 ns + rt]`; at 50 MHz it is 8.5 ns wide,
  `[E − 6 ns + rt, E + 2.5 ns + rt]`, so the sampling point must follow the round trip:
  `RX_DLY · T ≈ rt`. A 50 MHz high-speed link therefore needs a `pclk_i` fine enough to
  place a sample in a window of 8.5 ns less `t_su + t_h`: a grid of at most about 8 ns,
  `pclk_i ≥ 133 MHz` (`RX_DLY = 1` or `2` at 200 MHz with `rt ≈ 10 ns`); at 100 MHz
  whether a 10 ns grid point lands inside depends on the board's `rt`, which no contract
  can promise. A card switched to high-speed mode but clocked slower keeps the same
  figure: at 16.67 MHz the window is `[E − 46 ns + rt, E + 2.5 ns + rt]`, so `RX_DLY = 0`
  is right there and any `RX_DLY·T > rt + 2.5 ns` is wrong. The driver selects `RX_DLY`
  with the rate.
- **Quad flash** (S25FL128S): "tV Clock Low to Output Valid … 8.0 / 7.65 / 6.5 ns max",
  "tHO Output Hold Time 2 ns min" (`S25FL128S_256S` Table 6.4), from the falling edge: at
  200 MHz and 50 MHz `SCK` (`H = 2`, `T = 5 ns`) the window is `[E − 2 ns + rt, E + 12 ns +
  rt]`, so `RX_DLY = 1` or `2` with short on-chip or on-board round trips.

A device specified with a valid window around its view of the sampling edge fits the same
formulas by substitution, as in `apb_i2s`. `spi_io_i` is a false path for STA; its budget
is the board-level one above. The `RX_DLY` field delays only the capture; the frame
structure, the chip-select timing and the next frame are unaffected (except for the
`POLL` pause), and a capture that lands after the chip select has released, or after the
next frame has started, is still delivered to the receive FIFO (the engine stays `BUSY`
until it is).

---

## Register map

All registers are 32 bits. Offsets not listed read 0 and ignore writes. A write to a
register updates the byte lanes `PSTRB` selects (`IRQ_PEND` W1C, the `_SET` / `_CLR`
aliases and `CMD` act on the selected lanes); `TXDATA` accepts whole words only
(`PSTRB = 4'hF`): any other write to it pushes nothing and sets no flag. Reads return the
whole word. (`IHI0024D` §3.2.1: "An APB peripheral might support a limited set of access
types, which must be documented for the programmer.")

| Offset | Name | Access | Reset | Meaning |
|---|---|---|---|---|
| `0x00` | `CFG` | RO | — | Build parameters (see below) |
| `0x04` | `CTRL` | RW | `0x10` | Control (see below) |
| `0x08` | `CTRL_SET` | WO | — | Writing 1 sets the `CTRL` bit; reads 0 |
| `0x0C` | `CTRL_CLR` | WO | — | Writing 1 clears the `CTRL` bit; reads 0 |
| `0x10` | `CLKDIV` | RW | `0` | `[11:0]` `DIV` (`HALF` − 1), `[19:16]` `RX_DLY` |
| `0x14` | `CSCFG` | RW | `0` | `[7:0]` `CSPOL`, `[11:8]` `SETUP` − 1, `[15:12]` `HOLD` − 1, `[19:16]` `INACT` − 1 |
| `0x18` | `XFER` | RW | `0` | Attributes of the next pushed entry (see *Entry attributes*); `[31:16]` and `[7]` read 0 |
| `0x1C` | `STATUS` | RO | `0x4000_0000` | `[8:0]` transmit FIFO level (entries), `[24:16]` receive FIFO level (words); `[28]` `CS_ACTIVE`, `[29]` `STALL`, `[30]` `IDLE`, `[31]` `BUSY` |
| `0x20` | `THRESH` | RW | `0` | `[8:0]` `TX_THR`, `[24:16]` `RX_THR` (stored on 9 bits whatever the depth) |
| `0x24` | `IRQ_EN` | RW | `0` | Interrupt enables, one bit per `IRQ_PEND` bit |
| `0x28` | `IRQ_EN_SET` | WO | — | Writing 1 sets the `IRQ_EN` bit; reads 0 |
| `0x2C` | `IRQ_EN_CLR` | WO | — | Writing 1 clears the `IRQ_EN` bit; reads 0 |
| `0x30` | `IRQ_PEND` | RO / RW1C | see below | Interrupt causes (see below) |
| `0x34` | `TXDATA` | WO | — | A whole-word write pushes `{XFER[15:0], PWDATA}` into the transmit FIFO; reads 0 |
| `0x38` | `RXDATA` | RO | `0` | A read pops the receive FIFO; reads 0 when empty |
| `0x3C` | `CMD` | WO | — | Writing 1: `[0]` `TX_FLUSH`, `[1]` `RX_FLUSH`, `[2]` `ABORT`; reads 0 |
| `0x60` | `MDELEG` | RW (M-mode only) | `MDELEG_RST` | Privilege gates (see *Access protection*) |

The fields of an absent feature read 0 and ignore writes: with `RX_EN = 0`, `RX_DLY`,
`CAPT`, `RX_THR`, `STATUS[24:16]`, `STALL`, `RX_IO0`, `DBG_POP`, `LOOPBACK`, `RXDATA` and
the receive bits of `IRQ_EN` / `IRQ_PEND` (`[1]`, `[4]`, `[6]`); with `POLL_EN = 0`,
`POLL_TO`. `CSPOL` bits at and above `CS_NR` and `CS_SEL` values
at and above `CS_NR` are stored (so `XFER` reads back what was written and the refusal is
visible in `XFER_ERR`). The parameter register is named `CFG` as in `apb_gpio`.

`CTRL_SET` / `CTRL_CLR` and `IRQ_EN_SET` / `IRQ_EN_CLR` change individual bits without a
read-modify-write, so an interrupt handler can enable the engine or mask a cause while
the main program owns the register.

**`CTRL`**

| Bits | Field | Reset | Meaning |
|---|---|---|---|
| `[0]` | `EN` | 0 | Take entries from the transmit FIFO (see *Transmit, receive and status*) |
| `[1]` | `CPOL` | 0 | `SCK` idle level (see *Frame format and clock modes*) |
| `[2]` | `CPHA` | 0 | Clock phase |
| `[3]` | `LSB_FIRST` | 0 | Bit order |
| `[5:4]` | `TX_IDLE` | 1 | IO0 when it carries no transmit frame (idle, `RX`, `DUMMY`, `POLL` in single lane): 0 = driven low, 1 = driven high (the SD fill, `0xFF`), 2 and 3 = released (3-wire devices) |
| `[6]` | `RX_IO0` | 0 | Single-lane receive lane: 0 = IO1, 1 = IO0 (3-wire devices; `RX_EN`) |
| `[7]` | `IO23_REL` | 0 | IO2 and IO3 when not data lanes: 0 = driven high (flash WP# / HOLD# inactive), 1 = released |
| `[8]` | `LOOPBACK` | 0 | IO0 output looped to the single-lane receive synchroniser (`RX_EN`) |
| `[9]` | `DBG_POP` | 0 | A debugger read of `RXDATA` pops the FIFO like a core read (see *Debugger accesses*) |
| `[10]` | `BSWAP` | 0 | Byte order of 16-, 24- and 32-bit frames: 0 = payload byte 3 (2, 1) first, 1 = payload byte 0 first (see *Frame format and clock modes*) |

**`IRQ_PEND`**

| Bit | Name | Kind | Set when |
|---|---|---|---|
| `[0]` | `TX_LOW` | level, RO | transmit FIFO level ≤ `TX_THR` |
| `[1]` | `RX_HIGH` | level, RO | receive FIFO level ≥ `RX_THR` and `RX_THR` ≥ 1 |
| `[2]` | `DONE` | sticky, RW1C | `STATUS.IDLE` rose: the last entry completed, its chip select released, nothing queued at that edge — or a `TX_FLUSH` / `ABORT` emptied the queue with the engine quiet |
| `[3]` | `TX_OVF` | sticky, RW1C | a whole-word write to `TXDATA` found the FIFO full (entry dropped) |
| `[4]` | `RX_UDF` | sticky, RW1C | a read of `RXDATA` found the FIFO empty |
| `[5]` | `XFER_ERR` | sticky, RW1C | a `TXDATA` write carried an illegal `XFER` (entry dropped, see *Refused entries*) |
| `[6]` | `POLL_TO` | sticky, RW1C | a `POLL` entry reached its frame count without its condition (the last frame was pushed) |

The two level causes clear themselves as software fills or drains the FIFOs; writes of 1
to them are ignored. A sticky cause set in the same cycle as its W1C stays set. From reset
`TX_LOW` reads 1 (empty FIFO, threshold 0), harmless while `IRQ_EN` is 0. `TX_THR` ≥ the
depth makes `TX_LOW` permanent and `RX_THR` = 0 or above the depth disables `RX_HIGH`: use
`TX_THR` < depth and 1 ≤ `RX_THR` ≤ depth. The end of a receive can leave up to
`RX_THR − 1` words that never raise `RX_HIGH`: software drains them on `DONE`.

Against a level-triggered PLIC gateway, a handler services the FIFOs until the level cause
drops, clears the sticky causes, then completes; at the end of a transaction `TX_LOW` is
masked in `IRQ_EN`, or the gateway re-pends on every completion. `irq_o` is an AND-OR of
registers in the gated `pclk_i` domain; every cause is raised on an edge the IP itself
requested, so the line is stable whenever the clock is gated.

**`CFG`**

| Bits | Field | Value |
|---|---|---|
| `[3:0]` | `TX_FIFO_AW` | The parameter |
| `[7:4]` | `RX_FIFO_AW` | The parameter (0 with `RX_EN = 0`) |
| `[10:8]` | `CS_NR` − 1 | The parameter |
| `[13:12]` | `LANES_MAX` | 0 = single, 1 = dual, 2 = quad |
| `[14]` | `RX_EN` | The parameter |
| `[15]` | `POLL_EN` | The parameter |
| `[16]` | `DBG` | `DBG_PMASTER_MASK` is not 0: debugger reads of `RXDATA` follow `DBG_POP` |
| `[31:28]` | `VERSION` | `1` |

### Debugger accesses

A transfer whose `pmaster_i` has any bit of `DBG_PMASTER_MASK` set is a debugger access
(the aRVern Debug Module tags its system-bus accesses with `HMASTER` bit 3, which
`ahb_apb_bridge` forwards on `pmaster_o`). With `CTRL.DBG_POP = 0`, a debugger read of
`RXDATA` returns the word at the head of the receive FIFO without popping it and without
setting `RX_UDF` (0 when the FIFO is empty at the ACCESS edge), so a memory view in a
debugger does not disturb a transaction. With `CTRL.DBG_POP = 1` a debugger read pops
like a core read. Every other register, and every debugger write, behaves as for the core.
A debugger access passes `MDELEG` like any other: the aRVern Debug Module presents
Machine mode.

---

## Access protection

`MDELEG` at `0x60`, with the layout, encoding and behaviour of
[`apb_periph_example`](../../apb_periph_example/doc/apb_periph_example.md#mdeleg-register-layout):
`WR_PRIV[1:0]`, `RD_PRIV[3:2]`, `RESP[8]`; a refused access changes nothing (a refused
`RXDATA` read pops nothing, a refused `TXDATA` write pushes nothing and sets no flag),
reads 0 and gets `PSLVERR` with `RESP = 1`. Behind `ahb_apb_bridge` a `PSLVERR` is the AHB
ERROR of the transfer, which an aRVern hart takes as a resumable data-bus NMI; an S-mode
kernel that hands the bus to U-mode tasks has Machine-mode firmware clear `RESP`.

---

## Shift engine

`apb_spi_core` is the clock generator, chip-select sequencer, serialiser and deserialiser,
with no bus, no FIFO and no interrupt; `apb_spi` adds those. Its interface, all in
`clk_i`:

| Group | Signals |
|---|---|
| Configuration (latched by the core at transaction start) | `div_i[11:0]`, `rx_dly_i[3:0]`, `cpol_i`, `cpha_i`, `lsb_first_i`, `bswap_i`, `cs_pol_i[CS_NR-1:0]`, `cs_setup_i[3:0]`, `cs_hold_i[3:0]`, `cs_inact_i[3:0]`; the core latches the register's value before the current edge, so a write on the very edge a transaction starts applies from the next one. `cpol_i` and `cs_pol_i` are the value after the current edge: they also set the idle levels, which follow a write on its ACCESS edge whenever no transaction holds them, and the core's idle copy is what a transaction starts with |
| Configuration (immediate or per frame) | `tx_idle_i[1:0]`, `io23_rel_i`, `rx_io0_i`, `loopback_i` |
| Entry | `e_valid_i`, `e_attr_i[15:0]` (the `XFER` word), `e_data_i[31:0]`, `e_take_o` (pulse: the entry started), `e_abort_i` |
| Control / status | `run_i` (`CTRL.EN`), `busy_o`, `cs_active_o`, `stall_o`, `quiet_nxt_o` (after this edge: not busy and no select asserted, for `DONE`), `rx_room_i` (the wrapper's "a capturing frame may start"), `poll_to_o` (pulse) |
| Receive | `rx_start_o` (pulse: a capturing frame started), `rx_done_o` (pulse: a capturing frame's capture completed, pushed or discarded, or the frame was ended by an `ABORT` during its setup), `rx_valid_o` (pulse: `rx_data_o` is to be pushed), `rx_data_o[31:0]` |
| Pins | `spi_sck_o`, `spi_cs_o[CS_NR-1:0]`, `spi_io_o[3:0]`, `spi_io_oe_o[3:0]`, `spi_io_i[3:0]` |

The entry interface is one attribute word and one payload per handshake. The wrapper
keeps the in-flight count (up on `rx_start_o`, down on `rx_done_o`; `rx_valid_o` is a
subset of `rx_done_o`) and derives `rx_room_i` from it and its receive level; the FIFO
policy, the refusal of illegal entries and the interrupt are the wrapper's too.
Parameters: `LANES_MAX`, `CS_NR`, `RX_EN`, `POLL_EN`, `ASYNC_RST_EN`.

---

## Timing and integration

Every serial output is a flop output and every multiplexer is a flat AND-OR structure.
Each FIFO has a registered head word, so the read path does not grow with the depth; the
receive delay line takes the variable `RX_DLY` on its way in and captures from a fixed
stage, so the capture path is the assembly of one frame (lane select, shift, alignment,
byte swap) into the receive FIFO; settings latched at a transaction start come from the
registers, so no write-data path reaches the engine except to the idle levels. The
reference synthesis flow closes every configuration of `rtl_configs.py` at 66 MHz in a
130 nm library (see *Synthesis*); the rate tables above that use a faster `pclk_i` show
the arithmetic, and a SoC running the IP faster checks it in its own flow.

`spi_sck_o` is a clock for the devices it drives: the SoC constraints declare it as a
generated clock of `pclk_i` for the fastest setting the board uses (`HALF` is a register,
the constraint is per SoC: `create_generated_clock -divide_by 2·HALF`), `spi_io_o` and
`spi_cs_o` as outputs relative to it, and `spi_io_i` as a false path whose budget is the
board-level one of *Receive timing*. Transmit setup and hold at the device are an `SCK`
half-period minus pad skew: at 50 MHz that is 10 ns against the flash's "tSU Data in
Setup Time 2 ns, tHD Data in Hold Time 2 ns" (`S25FL128S_256S` Table 6.4) and the SD
card's 6 ns setup and 2 ns hold in high-speed mode (`SD_PLS_v6.00` Figure 6-12:
"6ns(min.)", "2ns(min.)"); at 25 MHz, 20 ns against the card's 5 ns and 5 ns (Figure 6-10).
`SCK` never has a pulse shorter than `HALF` cycles: a start, a stop, a pause, an abort or a
reset produces no runt.

Pads: ordinary LVCMOS at the device's I/O voltage, bidirectional for IO0–IO3 (IO1 may be
input-only on a single-lane board), with pull-ups on the lanes. Pull resistors, drive
strength and slew rate are the SoC's or the FPGA constraints' choice, not the IP's. The
pins can be offered through `apb_gpio` alternate functions: `spi_io_o[k]` / `spi_io_oe_o[k]`
into an `alt<k>_o_i` / `alt<k>_oe_i` bit, `spi_io_i[k]` from the pad.

## Integration examples

**SD card in SPI mode** (an SD or microSD slot; `SD_PLS_v6.00` Table 3-1 names the SPI
roles of the pins): `CLK` (`SCLK`) → `spi_sck_o`; `CMD` (`DI`) → IO0; `DAT0` (`DO`) →
IO1; `CD/DAT3` (`CS`) → `spi_cs_o[n]`; `DAT1` and `DAT2` unused, left to the board's
pull-ups. A card-detect switch, if the slot has one, belongs to a GPIO input and is not
an `apb_spi` concern. Settings: `CTRL` = `EN | TX_IDLE = 1` (mode 0, MSB first,
`RX_IO0 = 0`), `CSCFG` = 0 (one half-period each), `CLKDIV` with a `DIV` that puts `SCK`
in 100–400 kHz for identification, then one at or below 25 MHz for default speed, with
the `RX_DLY` that *Receive timing* gives for the board's round trip (from a 50 MHz
`pclk_i`: `DIV 62` for 396.8 kHz, then `DIV 0, RX_DLY 1` for 25 MHz). The SD card is a
single-lane device: `LANES_MAX = 1` is enough for a board with only the card, and the
`DUMMY`/`POLL` kinds carry the protocol's clocking and polling (see *Software*). The card
requires a valid CRC on CMD0 and on CMD8, and is otherwise in CRC-off mode by default
(`SD_PLS_v6.00` §7.2.2: "The SPI interface is initialized in the CRC OFF mode in default …
A valid reset command is: 0x40, 0x0, 0x0, 0x0, 0x0, 0x95"; "The CMD8 CRC verification is
always enabled"): both are constants in the driver, which leaves CRC off.

**Quad SPI NOR flash** (an S25FL128S-class device): `spi_sck_o` → SCK, `spi_cs_o[n]` → CS#,
IO0 → SI/IO0, IO1 → SO/IO1, IO2 → WP#/IO2, IO3 → HOLD#/IO3, all four pads bidirectional,
`LANES_MAX = 4`, `IO23_REL = 0` so that WP# and HOLD# read high during single-lane commands.
Mode 0 or 3 (`S25FL128S_256S` §4.1.1). The flash's `QUAD` configuration bit must be set by
the driver before any quad command ("The QUAD bit must be set to one when using Read Quad
Out, Quad I/O Read, Read DDR Quad I/O, and Quad Page Program commands", §8.5.2). A Quad
I/O Read (`EBh`, `S25FL128S_256S` Figure 4.11) at the latency code for ≤ 50 MHz (Table 8.10:
"Quad I/O Read … Mode 2, Dummy 1") is five entries under one chip select: `TX` single
8-bit `0xEB`; `TX` quad 24-bit address; `TX` quad 8-bit mode byte `0x00`; `DUMMY` quad 1
clock; `RX` quad, *N* 32-bit words. The mode byte must not have `Ah` in its upper nibble,
or the flash stays in continuous read mode and takes the next command's instruction byte
as address bits ("If the Mode bits equal Axh, then the device remains in Quad I/O High
Performance Read Mode and the next address can be entered … without requiring the EBh or
ECh instruction", §10.9; released by any other mode value at the next chip-select rise, or
by the Mode Bit Reset command `FFh`, §10.9.2). The chip select must rise on a byte
boundary for commands and write data ("the CS# signal must be driven high when the number
of clock cycles after CS# signal was driven low is an exact multiple of eight cycles",
§4.2), which whole frames guarantee; a page program or erase is followed by
`INACT ≥ 50 ns` ("tCS … (Program/Erase) 50 ns"), i.e. `INACT = 5` at 50 MHz, or by the
time the driver takes anyway to poll the status register (`TX` single `05h` with
`CS_HOLD`, then `POLL` with mask `0x01`, value `0x01`: the flash repeats its
status "by providing multiples of eight clock cycles", §10 RDSR1). tCSH also has a
maximum of 3000 ns, which "only applies during Program/Erase Suspend/Resume commands"
(Table 6.4, note 6): those single-byte commands go in an entry with `CS_HOLD = 0` and a
`HOLD` that stays under 3000 ns at the rate in use, never with a select held across an
empty FIFO. The flash's maximum
clock for quad reads (104 MHz) is beyond this IP's `pclk / 2`; 50 MHz is reached from a
100 MHz or faster `pclk_i`.

A board that carries both devices gives each its own `spi_cs_o`; the card's single lane
is IO0/IO1 of the same bus, and IO2/IO3 stay high for the flash during card transactions.

**Other devices.** A display or similar device with a data/command pin takes that pin from
`apb_gpio`; the entry model has no per-entry sideband, so the driver either waits for
`STATUS.IDLE` (or `DONE`) before toggling it, or releases the chip select between the
command byte (`CS_HOLD = 0`) and the data bytes, which the common controllers accept. A
3-wire device (one shared data line) uses `TX_IDLE = 2` and `RX_IO0 = 1` (*Lanes and
pads*). Daisy-chained devices take one `TX` entry per device word under `CS_HOLD`, released
after the last, and latch on the select's release. An ADC or DAC that clocks on the
trailing edge is `CPHA = 1`; a device that wants its least significant bit first is
`LSB_FIRST`; a word longer than 32 bits is consecutive entries under `CS_HOLD`, which
follow each other with no gap. A device that needs more than 16 half-periods of
chip-select inactive time gets a larger divider for its transactions, or software pacing
between them.

---

## Software

`sw/` holds the register map (`apb_spi_regs.h`) and a driver (`apb_spi.h`,
`src/apb_spi.c`, functions prefixed `apb_spi_`): the rate from a `pclk` frequency (the
divider and the `RX_DLY` for the link), clock mode, byte order and lane idle states,
chip-select timing, entry builders (`apb_spi_tx`, `apb_spi_rx`, `apb_spi_dummy`,
`apb_spi_poll`, each taking the chip select, the lane width, the frame length and the
flags, each saving and restoring `XFER` around its push), `apb_spi_run`, which pushes a
list of entries as the transmit FIFO has room and stores the words each one receives at
its own destination (so a transaction longer than the FIFOs never deadlocks on them),
thresholds and interrupts, flush, abort, and the `MDELEG` gates. On top of it, `sw/sd/`
holds the SD-card SPI sequence (power-up clocks, CMD0 / CMD8 / ACMD41 / CMD58
identification, CMD16 on a standard-capacity card, CMD17 / CMD24 single-block and
CMD18 / CMD25 multi-block transfers with CMD12 and the stop-tran token) and `sw/flash/`
a minimal flash reader and programmer (status, Quad I/O Read or READ, Quad Page Program
or Page Program with its WIP poll), both written only with entries.

**SD single-block read, as entries** (8-bit frames unless noted, `CS_SEL = 0`, `BSWAP` set):

| # | Entry | Payload | Note |
|---|---|---|---|
| 1 | six `TX` 8-bit, `CS_HOLD` | `0x40 \| 17`, `addr[31:24]` … `addr[7:0]`, `CRC7 \| 1` | the command, one byte per entry so that `BSWAP`, set for the block data of the same transaction, leaves it in order (CRC don't-care in CRC-off mode) |
| 2 | `POLL`, `CS_HOLD` | `{0x80, 0x80, 15}` (≤ 16 frames) | mask `0x80`, value `0x80`: ends at the R1 byte, whose MSB is 0 (`SD_PLS_v6.00` §7.3.2.1: "the MSB is always set to zero") |
| 3 | `POLL`, `CS_HOLD` | `{0xFF, 0xFF, 65535}` | mask `0xFF`, value `0xFF`: ends at the start-block token `0xFE` or a data-error token (§7.3.3.2, §7.3.3.3); repeated on `POLL_TO` until the driver's timeout. The pause after the terminating frame keeps the first data byte for entry 4 |
| 4 | `RX` 32-bit, `CS_HOLD` | 127 (128 words) | the 512-byte block, four bytes per word (`BSWAP` for a little-endian buffer) |
| 5 | `RX` 16-bit | 0 (1 frame) | the CRC16, releases the chip select |
| 6 | `DUMMY`, `CS_NONE` | 7 (8 clocks) | the trailing clocks with the select inactive that SD drivers send after every command |

A write (CMD24) sends the command the same way, polls R1, sends the token `0xFE`, 128
words and a 16-bit CRC, receives the data-response byte (`RX`, 1 frame; "x x x 0 Status
1", §7.3.3.1), then polls the busy stream (the card "will respond with a data response
token … As long as the card is busy programming, a continuous stream of busy tokens will
be sent to the host (effectively holding the DataOut line low)", §7.2.4; "A zero value
indicates card is busy. A non-zero value indicates the card is ready for the next
command", §7.3.2.2) with mask `0xFF`, value `0x00`. A multi-block write ends
with the stop-tran token `0xFD` (§7.3.3.2) after which the card goes busy (Figure 7-7); as
the busy may not have started on the next byte, the driver polls in two steps — first for
a byte that is not `0xFF`, then for one that is not `0x00` — and a multi-block read ends
with CMD12 ("Stop transmission command (CMD12) will actually stop the data transfer
operation", §7.2.3) followed by one `RX` frame to skip the byte the card may still be
shifting before the R1 poll. Every poll has a bounded frame count, so a removed card ends
in `POLL_TO`, never in a hang; the driver aborts and re-initialises.

---

## Verification

`bench/verilog/tb_apb_spi.v` drives the IP from an APB4 requester (`apb_tasks.v`:
transfers back to back or separated by idle cycles, random bus values while `PSEL` is
low, a `PMASTER` per transfer) with the bus clock gated by `pclk_en_o` alone, and models
each lane as a bidirectional pad with a pull-up. `spi_dev.v`, written from this document,
holds:

- **A register model**: every admitted APB write is snooped into a mirror of `CTRL`,
  `CLKDIV`, `CSCFG`, `XFER`, `THRESH`, `IRQ_EN` and `MDELEG` (byte lanes, aliases, the
  bits a build stores); expected reads and `PSLVERR` come from it. Whole-word `TXDATA`
  writes are classified as legal, refused (`XFER_ERR`) or dropped (`TX_OVF`) against a
  level model of the transmit FIFO; the legal ones form the queue of entries the monitor
  expects on the wire, and a flush or an abort drops those not yet taken.
- **A monitor** that opens a transaction when the engine starts one and closes it on the
  release, and at each sampling edge follows the entry queue (entry, frame, clock): it
  checks the chip selects, the role of every lane (driven with data, released, idle level
  per `TX_IDLE` / `IO23_REL`, kept released after a dual or quad frame), assembles each
  transmit frame with its own bit- and byte-order rules against the payload, and takes
  each received group from the pads at the IP's sampling point (`RX_DLY` cycles after the
  edge), so that the word the IP must push, a `POLL`'s end and `POLL_TO` are predicted.
- **Timing checks in ns**: the first edge exactly `SETUP` half-periods after the start,
  every leading-to-trailing interval exactly `HALF`, every trailing-to-leading interval at
  least `HALF` (no runt, the poll pause measured), the release at least `HOLD` after the
  last edge and the next start at least `INACT` after a release; a lane the IP drives
  stable for at least `HALF` before each sampling edge and changing no sooner than `HALF`
  after one (the resume rule); no `SCK` edge outside a transaction; idle levels per the
  mirror between transactions; pad contention beyond the device's round trip.
- **Devices**: a scripted frame source (each capturing frame takes the next word of a
  response queue and launches it on the lanes it reads after a round trip and a
  launch-to-valid delay, with the lanes unknown from the hold time); an SD card in SPI
  mode (`sd_card.v`: power-up clock count, byte alignment of every release, CMD0 / CMD8
  CRCs, ACMD41 initialisation, R1 / R3 / R7, single- and multi-block reads and writes,
  CMD12 with its stuff byte, data-response tokens, busy, stop-tran token); and a quad
  SPI NOR flash (`spi_flash.v`: WREN, RDSR1, READ, QPP, QIOR with programmable dummy
  clocks and the `Axh` continuous-read rule, HOLD# checked high in single-lane phases).

Always-on checks cover `PSLVERR` and `PRDATA` outside an ACCESS cycle, `PREADY`,
`pclk_en_o` against its formula every cycle, and X on any output.

Tests (`sim_configs.py`, `DEFAULT_TESTS`): `reset_values`, `reg_rdwr`, `mdeleg_access`,
`pclk_gating`, `clk_div` (`HALF` 1 to 8, 42, 250 and 4096), `clk_modes` (the four
`CPOL` / `CPHA` pairs × MSB first, `BSWAP`, `LSB_FIRST` and both, 8- to 32-bit frames, every
lane width), `frame_bits` (every frame length in single, dual and quad), `lanes`
(transmit, receive and dummy in every width, `IO23_REL`, `TX_IDLE` during receive, the
3-wire mode, lanes kept released after a quad frame), `loopback`, `rx_timing` (both
phases, `HALF` 1 to 3, three round trips, every `RX_DLY` up to `2·HALF + 2`: correct
words exactly when the budget holds, wrong words when it fails by a margin; then every
`RX_DLY` 0 to 15 with a round trip inside the budget, through single, dual and quad
frames, loopback and the 3-wire lane), `cs_timing`
(every `SETUP`, `HOLD`, `INACT` value measured exactly, every select, random polarity, a
held select released for another select and for `CS_NONE`), `cs_hold_gaps` (one
transaction across an empty FIFO with the clock gated, `EN` cleared and set, a receive
stall), `cs_none`, `inact_gated`, `config_latch`, `rx_stall`, `poll` (R1, token and busy
waits each followed by the byte after the terminating frame, first and last allowed
frame, timeout, more discarded frames than the FIFO holds, `RX_DLY` 0, 1 and 15, both
phases, dual and quad, the pause length), `fifo_errors` (every `XFER_ERR` cause a build
can be given, `TX_OVF`, `RX_UDF`, sparse writes, a W1C racing `DONE`), `fifo_walk` (both
FIFOs filled to their depth three times with random entries and words), `thresholds`,
`flush`, `abort` (in each kind, in a `POLL` pause, on a stalled entry, during `SETUP`,
with a held select and an idle bus, with nothing in progress), `enable`, `dbg_access`,
`sd_sequence` (identification at 396.8 kHz, then CMD24, CMD17, CMD25 and CMD18 / CMD12 at
`pclk / 2`, every block read compared with what was written), `flash_sequence` (status,
READ, WREN + QPP + WIP poll, QIOR with 1, 4 and 0 dummy clocks, the continuous read mode,
modes 0 and 3), `reset_in_operation` and `random_stress` (random batches of every kind,
lane width, frame length, select, `CS_HOLD` / `CS_NONE`, clock mode, order, divider,
round trip and `RX_DLY` within the budget, with random gaps).

The sweep runs the tests over the 17 configurations of `sim_configs.py`: lane builds 1,
2 and 4; `CS_NR` 1, 2, 3 and 8; `RX_EN = 0`; `POLL_EN = 0`; FIFO depths 2, 256 and unequal;
window width 7, 12 and 16; `MDELEG_RST` open and Supervisor; debugger mask none and
non-default; both reset styles; a free-running bus clock; the SD-card build. The
mandatory functional cover bins (`MANDATORY_COVER_BINS`, 75) must all be hit: the
bus-level set shared with the family (back to back, `PSLVERR`, silent refusal, S- and
U-mode admitted, `PENABLE` without `PSEL`, the gated clock, reset in operation), every
clock mode, every `KIND` × lane width, a 1-bit and a 32-bit frame, `LSB_FIRST`, `BSWAP`
and both, `CS_HOLD` continued, switched and to `CS_NONE`, active-high select, a held
select with the clock gated, a stall and a stall between frames, a capture after the
release, `RX_DLY` 0, 15 and at least `2·HALF`, `POLL` ending on its first, a middle and
its last frame and by timeout, the poll pause, `POLL` in quad, every flag and both level
interrupts, a W1C racing an event, `ABORT` in shift, pause, wait and setup, `EN` cleared
while busy, a `CPOL` write with a select held, a resume, the 3-wire mode, `IO23_REL`,
loopback, debugger peek and pop, both flushes, full FIFOs, a timing value of 16 and an
inactive time enforced against a queued entry. Verilator coverage over every
configuration reaches 100 % of lines, branches and toggles (accumulated over the
configurations); the waived points, constants of a build and points unreachable by
construction, are argued in `sim/rtl_sim/run/waivers_cov.md`.

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
create `libraries/setup_lib_default.tcl` from `setup_lib_example.tcl` first. The RTL
sweep (`rtl_configs.py`, whose header states this rationale) covers the parameters that
select a generate branch or an interface width: `LANES_MAX` (lane multiplexers and the
IO2 / IO3 branch), `CS_NR` (output width and `CS_SEL` decode), `RX_EN` and `POLL_EN` (the
receive and poll branches), the two FIFO depths at 1 and 8 bits, `ADDRW` at 7 and 16;
`MDELEG_RST` and `DBG_PMASTER_MASK` are constants, and `ASYNC_RST_EN = 0` is the only
setting that builds the synchronous-reset branches of the primitives.
