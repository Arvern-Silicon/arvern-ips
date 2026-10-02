<p align="center">
  <img src="arv_custom_csr/doc/img/aRVern_light.png" alt="aRVern" width="220">
</p>

<h1 align="center">arvern-ips</h1>

<p align="center">
  Open-source Verilog IP library for the
  <strong>aRVern</strong> RISC-V ecosystem.
</p>

---

## IPs in this repository

| IP                    | Description                                                                                                                | Documentation                                                                                  |
|-----------------------|----------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| `ahb_interconnect`    | Parameterizable AHB-Lite multi-manager / multi-subordinate fabric. Three variants (generic / hiperf / fused) sharing the same external AHB contract, with a built-in default-subordinate ERROR responder. | [`ahb_interconnect/doc/ahb_interconnect.md`](ahb_interconnect/doc/ahb_interconnect.md)         |
| `ahb_rom_controller`  | Parameterizable AHB ROM controller with single-cycle read latency. Bridges an AHB-Lite-style read master to a sync ROM.    | [`ahb_rom_controller/doc/ahb_rom_controller.md`](ahb_rom_controller/doc/ahb_rom_controller.md) |
| `ahb_sram_controller` | Parameterizable AHB SRAM controller with byte-enable writes and a 1-deep pause buffer that resolves read-after-write hazards on the shared SRAM port. | [`ahb_sram_controller/doc/ahb_sram_controller.md`](ahb_sram_controller/doc/ahb_sram_controller.md) |
| `ahb_periph_example`  | Reference AHB-Lite slave wiring 8 read-write + 8 read-only 32-bit registers, with an `MDELEG` privilege-delegation register that gates accesses by the master's privilege level. Intended as a starting template for new peripherals. | [`ahb_periph_example/doc/ahb_periph_example.md`](ahb_periph_example/doc/ahb_periph_example.md) |
| `ahb_aclint`          | RISC-V ACLINT (Advanced Core-Local INTerruptor) as a single AHB-Lite slave, consolidating the MSWI / MTIMER / SSWI banks. The MTIME counter is paced by an always-on low-frequency clock so timer ticks advance for wake-from-WFI while the main oscillator is off. | [`ahb_aclint/doc/ahb_aclint.md`](ahb_aclint/doc/ahb_aclint.md) |
| `ahb_plic`            | RISC-V PLIC (Platform-Level Interrupt Controller) as a single AHB-Lite slave, routing up to `NUM_SOURCES` level-triggered interrupt lines into per-hart M-mode and (optional) S-mode contexts. SiFive-compatible address layout, so mainstream PLIC drivers (Linux, OpenSBI, FreeRTOS, Zephyr) work unchanged. | [`ahb_plic/doc/ahb_plic.md`](ahb_plic/doc/ahb_plic.md) |
| `arv_custom_csr`      | Parameterizable custom CSR peripheral. Configurable counts of User / Supervisor / Machine-mode RO and RW registers.        | [`arv_custom_csr/doc/arv_custom_csr.md`](arv_custom_csr/doc/arv_custom_csr.md)                 |
| `arv_dtm`             | Debug Transport Modules (DTMs) — the master side of the aRVern core's external-debug link. Drives the core's transport-agnostic DMI bus (an APB4 slave) through one shared `arv_dtm_dmi_master` (APB4 master + CDC) backend, offering four interchangeable physical transports: a standards-compliant RISC-V Debug Spec 1.0 **JTAG** DTM (OpenOCD + GDB out of the box with any adapter OpenOCD supports, a J-Link, or [`arvern-tools`](https://github.com/Arvern-Silicon/arvern-tools) with an FT232H), a 2-pin IEEE 1149.7 OScan1 **cJTAG** DTM driven by a J-Link in its cJTAG mode (SEGGER Ozone or the J-Link GDB Server; validated with Ozone, OpenOCD over cJTAG not validated, `arvern-tools` support planned), plus non-standard "DMI-over-serial" **UART** and **I2C** transports for boards without a JTAG pod, driven by `arvern-tools`. A build-time `DTM_TYPE` on the `arv_dtm` wrapper selects one. | [`arv_dtm/doc/arv_dtm.md`](arv_dtm/doc/arv_dtm.md) |
| `arv_primitives`      | Shared primitives library (not a standalone IP): the reset-style-selectable flip-flops `arv_ipdff` / `arv_ipdff_sinit`, the 2-FF clock-domain-crossing synchronizer `arv_synchronizer`, the clock gate `arv_cgate`, and the `arv_and` / `arv_or` gate primitives, plus two reference blocks built from them: the reset generator `arv_reset_gen` and the oscillator controller `arv_osc_ctrl`. Every other IP depends on it, and it is the intended place to apply your own PD/technology rules. | [`arv_primitives/doc/arv_primitives.md`](arv_primitives/doc/arv_primitives.md) |

More IPs will land here as the ecosystem grows.

## Release notes

Latest release: **1.0.0**.

What changed in each release, and how to upgrade: [`CHANGELOG.md`](CHANGELOG.md).

## Repository layout

Each IP follows a uniform layout:

```
<ip_name>/
├── rtl/verilog/             RTL sources (.v) + filelist.f
├── bench/verilog/           Testbench sources
├── doc/                     Markdown documentation
├── sim/rtl_sim/             Simulation flow (run/, src/, bin/)
└── synthesis/synopsys/      Synthesis flow (Design Compiler)
```

The shared primitives library `arv_primitives/` holds the six modules every other IP
is built from — and is the **single place to apply technology or physical-design
rules** (`dont_touch`/`size_only`, a library ICG, a hardened synchroniser, a different
reset style). See [`arv_primitives.md`](arv_primitives/doc/arv_primitives.md) and
[Reset architecture](#reset-architecture).

## Synthesis

Every IP's Design Compiler flow uses a uniform `LIB_FLAVOR` mechanism for
selecting the target technology:

Each IP ships only the library template
`synthesis/synopsys/libraries/setup_lib_example.tcl`; the default flavor file
`setup_lib_default.tcl` is intentionally absent, because it names your
technology. Create it for your environment before the first run:

```bash
cd <ip_name>/synthesis/synopsys
cp libraries/setup_lib_example.tcl libraries/setup_lib_default.tcl
$EDITOR libraries/setup_lib_default.tcl    # .db paths, library names, opcons, period
```

```bash
./run_syn                         # default flavor (lib_default)
./run_syn -lib <flavor>           # synthesise with a specific library flavor
./run_syn -lib <flavor> -i        # interactive (keep dc_shell open after synthesis)
```

Naming it `setup_lib_default.tcl` makes it the default; any other
`setup_<flavor>.tcl` is selected with `-lib <flavor>`. Without a flavor file
`./run_syn` stops with "Unknown library flavor", which also prints the list it
found. A new technology is added by dropping a `setup_<flavor>.tcl` into the
same directory; foundry `.db` files are typically symlinked in to avoid
duplication across IPs.

## Simulation and regression

The full testbench / lint / regression flow lives under each IP's
`sim/rtl_sim/run/`:

```bash
cd <ip_name>/sim/rtl_sim/run
./run_lint                   # Verilator --lint-only
./run <testname>             # run a single test
./run_all                    # full regression (all tests × variants)
./run_all -cov               # line / branch / toggle coverage (Verilator)
```

Every IP with a simulation flow reaches **100 % line, branch and toggle coverage**
over its configuration sweep; each exclusion is argued in the IP's
`sim/rtl_sim/run/waivers_cov.md`. `arv_primitives` has no flow of its own: it is
exercised through every IP that instantiates it.

Each test run produces a flattened, absolute-path filelist at
`run/submit_sim.f` for inspection (the simulator consumes that file
rather than the raw source `submit.f` so paths resolve regardless of
cwd).  The filelist preprocessor is `sim/rtl_sim/bin/flatten_filelist.py`.

## Reset architecture

Every IP exposes a build-time parameter selecting the reset style — **`ASYNC_RST_EN`**
on the AHB IPs and `arv_custom_csr`, and **`ARST_EN`** on `arv_dtm` (matching the
parameter name used by `arv_primitives` itself):

| Value | Reset style | Reset assertion |
|-------|-------------|-----------------|
| `1` (default) | asynchronous active-low | takes effect immediately, independent of the clock |
| `0`           | synchronous  | sampled on a clock edge |

The selection is threaded down to every flop through the shared `arv_primitives`
primitive **`arv_ipdff`** (a parameterizable enabled flip-flop whose generate
picks an async- or sync-reset `always` block). Clock-domain-crossing
synchronizers use **`arv_synchronizer`** (a 2-FF synchronizer that follows the
same `ASYNC_RST_EN` knob). Because the choice lives in the primitives, a single
top-level parameter flips the reset style of the entire IP coherently — there is
no mixed-reset state.

## SoC integration (FuseSoC)

For projects that want to pull these IPs into their own SoC build flow
without learning aRVern's testbench scripts, each IP carries a minimal
[FuseSoC](https://fusesoc.readthedocs.io/) `.core` manifest at its top
level.  The manifest lists the RTL files and exposes a `lint` target.

```bash
# One-time: register this library with FuseSoC
fusesoc library add aRVern_ips /path/to/aRVern/arvern-ips

# Lint any IP (smoke test that the RTL elaborates clean)
fusesoc run --target=lint arvern:ips:ahb_rom_controller

# Export the RTL filelist for use in your own tool flow
fusesoc run --target=lint --setup arvern:ips:ahb_rom_controller
# -> build/arvern_ips_ahb_rom_controller_1.0/lint/arvern_ips_ahb_rom_controller_1.0.vc
# -> build/arvern_ips_ahb_rom_controller_1.0/lint/src/.../rtl/verilog/*.v
```

The `--setup` form stops *before* invoking the tool — you get a clean
filelist + a copy of the RTL files, ready to feed into Verilator, VCS,
Modelsim, Genus, OpenLane, or any other tool that accepts a `.f`
filelist.

Available targets per IP (all `lint` flavours by default; the AHB
interconnect exposes `lint`, `lint_hiperf`, `lint_fused` — one per
fabric variant, and `arv_dtm` exposes `lint_jtag`, `lint_cjtag`,
`lint_uart`, `lint_i2c` — one per transport — plus `lint_wrapper`
for the selectable `arv_dtm` top):

```bash
fusesoc core-info <vlnv>
```

**Scope of the `.core` files:** they cover RTL file discovery + lint for
external integration only.  Functional testing, the full regression
matrix, timing-variant sweeps, and waveform inspection all live in the
native flow above.  The native flow does not use FuseSoC.

## License

BSD 3-Clause — see [`LICENSE`](LICENSE).
