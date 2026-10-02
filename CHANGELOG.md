# Changelog

All notable changes to the aRVern IP library are listed here. Versions follow
[Semantic Versioning](https://semver.org/) and are released together with the aRVern core.

## Versions

| Version | Date |
|---|---|
| [1.0.0](#v1.0.0) | Oct 2, 2026 |
| [0.1.0-preview](#v0.1.0-preview) | Jun 24, 2026 |

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
