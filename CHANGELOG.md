# Changelog

All notable changes to the aRVern IP library are listed here. Versions follow
[Semantic Versioning](https://semver.org/) and are released together with the aRVern core.

## Versions

| Version | Date |
|---|---|
| [1.1.0](#v1.1.0) | Nov 14, 2026 |
| [1.0.1](#v1.0.1) | Oct 5, 2026 |
| [1.0.0](#v1.0.0) | Oct 2, 2026 |
| [0.1.0-preview](#v0.1.0-preview) | Jun 24, 2026 |

<a id="v1.1.0"></a>

## 1.1.0

Adds an APB peripheral layer behind a new AHB-to-APB bridge: GPIO, I2S audio, SPI and a
USB host for HID devices, each with a C driver. Existing IPs keep their ports and
defaults, so 1.0.1 integrations build unchanged.

### Added

- `ahb_interconnect`: new fused-fabric parameter `X_SRAM_B_APH_REG`, one bit per fused
  SRAM controller, to raise the clock frequency of a design whose critical path runs from
  the data bus into a large program memory. With the bit set, every data access to that
  memory takes one wait state (two when it competes with an instruction fetch), and in
  exchange the memory's address no longer depends on
  the data bus's address decoding. Instruction fetches are not affected.
  Off by default, which leaves existing designs unchanged.
- `ahb_apb_bridge`: AHB-Lite to APB4 bridge, 1 to 16 completers in aligned power-of-two
  windows, registered AHB response (two wait states plus the completer's), no posted
  writes. APB errors, unmapped addresses, misaligned transfers and transfers wider than a
  word are answered with the two-cycle ERROR, with `HRDATA` at 0. No privilege filtering
  of its own: `PPROT` and the supervisor-mode sideband go to the completers, which filter.
  The manager ID (`HMASTER`) goes to them too, on `pmaster_o`, so a completer can tell a
  debugger access from the core's.
- `apb_periph_example`: APB4 completer template with the register map and `MDELEG`
  privilege gate of `ahb_periph_example`, no wait states, refused accesses answered with
  `PSLVERR` or dropped; the gate's reset value is a parameter (`MDELEG_RST`, Machine mode
  only by default); C driver in `sw/`.
- `apb_gpio`: general-purpose I/O on an APB4 completer port, 1 to 32 pins, synchronised
  inputs, edge and level interrupts per pin (one line per pin and a combined line, and
  `IRQ_STAT` for the enabled pending pins), set / clear aliases for `OUTPUT`, `OE` and
  `IRQ_EN`, up to four alternate functions per pin, a per-pin input-enable output for the
  pad receivers, a `CFG` register with the build parameters, and an always-on input path
  with a wake request that follows each pin's interrupt modes. The `MDELEG` privilege
  gate of `apb_periph_example` controls access, Machine mode only by default
  (`MDELEG_RST`); C driver in `sw/`.
- `apb_i2s`: serial-audio master on an APB4 completer port: `MCLK`, `BCLK` and `LRCK`
  from the APB clock by integer dividers, every common format selected by software
  (I2S, left- and right-justified, DSP/PCM modes A and B, 32- or 16-bit slots, both clock
  polarities), 16-bit stereo or packed mono samples, flip-flop transmit and receive FIFOs
  (2 to 256 words) with software thresholds, sticky under- and overrun flags and one
  interrupt line, a programmable receive sampling point, frame-boundary start and stop,
  internal loopback, debugger-aware `RXDATA` reads and the `MDELEG` privilege gate. The
  shift engine is a separate module with its own FuseSoC target; C driver in `sw/`.
- `apb_spi`: SPI controller on an APB4 completer port: `SCK` from the APB clock by an
  integer divider, all four clock modes, MSB or LSB first and a byte swap, up to eight
  chip selects with setup, hold and inactive times, single, dual and quad lanes per
  entry, a 3-wire mode and an adjustable receive sampling point. Software queues entries
  (transmit, receive, dummy clocks and polls carrying their own mask and value) with
  their attributes in a transmit FIFO, so a whole SD-card or flash transaction runs under
  one chip select without CPU bit timing; a receive FIFO, software thresholds, sticky
  flags and one interrupt line, debugger-aware `RXDATA` reads and the `MDELEG` privilege
  gate. The shift engine is a separate module with its own FuseSoC target; C driver in
  `sw/`, with an SD-card layer and a SPI NOR flash layer.
- `apb_usb_host`: USB host for one low-speed HID device (keyboard, mouse, gamepad) on an
  APB4 completer port, driven from two pads without an external PHY: attachment
  detection, bus reset and enumeration in hardware, selection of the first HID interface
  with an interrupt IN endpoint, then polling and raw reports to software. Every state is
  bounded in time, a failed transaction is retried and a failed enumeration starts again
  from a bus reset. Software control transfers (`CTRL_EN`) and diagnostic counters
  (`DIAG_EN`) are build options; the `MDELEG` privilege gate controls access. C driver in
  `sw/`, with a HID layer for keyboards, mice and gamepads.
- `arv_primitives`: a simulation-only jitter model in `arv_synchronizer`
  (`` `ARV_SYNC_JITTER ``): a changed input is captured one edge late at random, so
  clock-domain crossings are exercised with both latencies. Synthesis and lint never see
  it.

### Changed

- `ahb_periph_example`: the `MDELEG` reset value is a parameter, `MDELEG_RST`. Its default,
  `9'h10F` (Machine mode only, ERROR on a refused access), is the previous fixed value,
  so existing integrations are unchanged.
- `ahb_plic`: a claim read takes one wait state. The claim winner is registered in the
  first data-phase cycle and returned in the second, with the claim applied on the edge
  that completes the transfer, so the arbiter tree is no longer in the read-data path;
  completions and every other access stay zero-wait. Software is unaffected.
- Coverage tooling (`cov_const.py`, every repository's copy): the parameters of a
  configuration are set with one `chparam`, so a design whose packed parameters depend on
  another one elaborates without passing through an inconsistent intermediate set.

### Fixed

- Coverage tooling (`cov_html.py`, every repository's copy): the HTML report now matches
  `cov_report.py`. It counted each toggle bit twice (Verilator records both directions)
  and missed `label@column` branch names, so correct waivers showed as stale. The page
  title names its own repository, so every copy is byte-identical again.
- `arv_primitives` document: it now names `apb_gpio`'s internal clock gate, the cJTAG
  escape detector's deliberate reset-to-0 TMSC sample, and the reset synchronisers inside
  `arv_dtm` and `ahb_aclint`.

<a id="v1.0.1"></a>

## 1.0.1

Adds C drivers for the ACLINT, the PLIC and the example peripheral. Bug fix for the DTM. No port, parameter or register change.

### Added

- `ahb_aclint/sw`, `ahb_plic/sw`, `ahb_periph_example/sw`: register maps and drivers in C
  (no `malloc`, RV32E-clean).

### Fixed

- **arv_dtm (JTAG and cJTAG).** A `dmireset` on the TCK edge where an outstanding DMI
  operation completed with `PSLVERR` cleared that failure: the next scan reported success. The
  failure now stands, as for a failure held behind busy. The UART and I2C transports have no
  sticky error state and were not affected.

### Documentation

- **C drivers.** The repository README lists the IPs that ship a driver and how they pair
  with the core support library.
- **ahb_aclint.** A two-store MTIME write shows the mixed value to the read view and to MTIP
  between the stores; the guide now gives the store order that keeps it from asserting MTIP.

### Upgrading from 1.0.0

Drop-in replacement. FuseSoC core versions follow their changes: `ahb_aclint`, `ahb_plic`,
`ahb_periph_example` and `arv_dtm` are `1.0.1`; the unchanged cores, `arv_primitives`
included, are `1.0.0`.

<a id="v1.0.0"></a>

## 1.0.0

First stable release. Adds the debug transport modules and the shared primitives library, and
closes verification: every IP with a simulation flow reaches 100 % line, branch and toggle
coverage over its configuration sweep.

### Added

- **`arv_dtm`, debug transport modules** for the core's RISC-V Debug 1.0 Debug Module. Four
  transports share one APB4 DMI master with clock-domain crossing:
  - a Debug Spec 1.0 **JTAG** DTM (GDB / OpenOCD);
  - a 2-pin IEEE 1149.7 OScan1 **cJTAG** DTM;
  - **UART** and **I2C** "DMI-over-serial" transports.

  A build-time `DTM_TYPE` selects one.
- **`arv_primitives`**, the shared primitives every IP is built from: `arv_ipdff`,
  `arv_ipdff_sinit`, `arv_synchronizer`, `arv_cgate`, `arv_and` and `arv_or`. It also holds the
  reference reset generator `arv_reset_gen` and oscillator controller `arv_osc_ctrl`. It is the
  single place to apply technology or physical-design rules.
- **`ahb_interconnect`**: HMASTER tagging on every fabric variant.
- **Coverage flow** for every IP (`./run_all -cov`), with argued exclusions in each
  `sim/rtl_sim/run/waivers_cov.md`, and new directed and walk tests closing the gaps.

### Changed

- **`ahb_aclint`**: the MTIME crossing into the always-on low-frequency domain was redesigned.
  It is now an open-loop crossing protected by timing constraints, replacing the gray-code read
  and level-toggle write synchronizers. The deep-sleep and `mtimecmp` semantics were clarified.
- **`ahb_rom_controller`**: writes are rejected with an AHB ERROR response.
- **Documentation**: rewritten or extended across the IPs (integration, timing and reset
  semantics).

### Removed

- `arv_common`, replaced by `arv_primitives`.
- The ACLINT gray-code MTIME synchronizers (`aclint_gray2bin`, `aclint_mtimer_gray_sync`,
  `aclint_mtimer_write_cdc`), superseded by the redesigned low-frequency crossing.

### Fixed

- Protocol and corner-case fixes in the interconnect, ROM and SRAM controllers, the PLIC priority
  arbiter, the ACLINT and the DTM transports, each covered by a directed test.

### Upgrading from 0.1.0-preview

1. Replace `arv_common` with `arv_primitives` in your file lists.
2. ACLINT integrations: apply the new clock-crossing timing constraints described in
   [`ahb_aclint/doc/ahb_aclint.md`](ahb_aclint/doc/ahb_aclint.md).

<a id="v0.1.0-preview"></a>

## 0.1.0-preview

Initial hardware baseline preview of the aRVern IPs: the open-source repository baseline, build
tooling and a basic verification setup. A pre-release for early evaluation and integration
testing; features, interfaces and register structures were subject to change before the first
stable release.
