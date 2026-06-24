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
| `arv_custom_csr`      | Parameterizable custom CSR peripheral. Configurable counts of User / Supervisor / Machine-mode RO and RW registers.        | [`arv_custom_csr/doc/arv_custom_csr.md`](arv_custom_csr/doc/arv_custom_csr.md)                 |
| `arv_common`          | Shared building-block library (not a standalone IP): the reset-style-selectable flip-flop primitive `arv_ipdff` and the 2-FF clock-domain-crossing synchronizer `arv_synchronizer`. Every other IP depends on it. See [Reset architecture](#reset-architecture). | `arv_common/rtl/verilog/` |

More IPs will land here as the ecosystem grows.

## Repository layout

Each IP follows a uniform layout:

```
<ip_name>/
├── rtl/verilog/             RTL sources (.v) + filelist.f
├── bench/verilog/           Testbench sources
├── doc/                     Markdown documentation (+ private/ source)
├── sim/rtl_sim/             Simulation flow (run/, src/, bin/)
└── synthesis/synopsys/      Synthesis flow (Design Compiler)
```

The shared building-block library `arv_common/` carries only `rtl/verilog/`
(the `arv_ipdff` and `arv_synchronizer` primitives); every other IP depends on
it. See [Reset architecture](#reset-architecture).

## Synthesis

Every IP's Design Compiler flow uses a uniform `LIB_FLAVOR` mechanism for
selecting the target technology:

```bash
cd <ip_name>/synthesis/synopsys
./run_syn                         # default flavor (lib_default)
./run_syn -lib <flavor>           # synthesise with a specific library flavor
./run_syn -lib <flavor> -i        # interactive (keep dc_shell open after synthesis)
./run_syn_d -lib <flavor>         # same, inside the docker image
```

Available `<flavor>` values are derived from `setup_*.tcl` files under each
IP's `synthesis/synopsys/libraries/` directory — running `./run_syn` with
an unknown flavor prints the full list. A new technology is added by
dropping a `setup_<flavor>.tcl` next to the existing ones; foundry `.db`
files are typically symlinked in to avoid duplication across IPs.

## Simulation and regression

The full testbench / lint / regression flow lives under each IP's
`sim/rtl_sim/run/`:

```bash
cd <ip_name>/sim/rtl_sim/run
./run_lint                   # Verilator --lint-only
./run <testname>             # run a single test
./run_all                    # full regression (all tests × variants)
```

Each test run produces a flattened, absolute-path filelist at
`run/submit_sim.f` for inspection (the simulator consumes that file
rather than the raw source `submit.f` so paths resolve regardless of
cwd).  The filelist preprocessor is `sim/rtl_sim/bin/flatten_filelist.py`.

## Reset architecture

Every IP exposes a uniform **`ASYNC_RST_EN`** parameter selecting the reset
style at build time:

| `ASYNC_RST_EN` | Reset style | Reset assertion |
|----------------|-------------|-----------------|
| `1` (default)  | asynchronous active-low | takes effect immediately, independent of the clock |
| `0`            | synchronous  | sampled on a clock edge |

The selection is threaded down to every flop through the shared `arv_common`
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
fabric variant):

```bash
fusesoc core-info <vlnv>
```

**Scope of the `.core` files:** they cover RTL file discovery + lint for
external integration only.  Functional testing, the full regression
matrix, timing-variant sweeps, and waveform inspection all live in the
native flow above.  The native flow does not use FuseSoC.

## License

BSD 3-Clause — see [`LICENSE`](LICENSE).
