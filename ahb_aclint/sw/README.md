<p align="center">
  <img src="../../arv_custom_csr/doc/img/aRVern_light.png" alt="aRVern" width="180">
</p>

# ACLINT driver library

*Bare-metal C driver for the aRVern ACLINT: register definitions and a small API for
the machine timer (MTIME, MTIMECMP), the machine software interrupts (MSWI) and the
supervisor software interrupts (SSWI).*

The hardware and its programming model are described in
[doc/ahb_aclint.md](../doc/ahb_aclint.md).

---

## Layout

```
sw/
├── include/
│   ├── ahb_aclint_regs.h   register map: ACLINT_TypeDef overlay, ACLINT_<REG>_<FIELD>_Pos/_Msk
│   └── ahb_aclint.h        the API; MSWI / SSWI and the MTIME low word are inline
└── src/
    └── ahb_aclint.c        init, MTIME read and write, MTIMECMP programming, delays
```

| Layer | Files | Use it for |
|---|---|---|
| Registers | `ahb_aclint_regs.h` | direct register access; the API is built on it |
| Driver | `ahb_aclint.h`, `src/ahb_aclint.c` | time, deadlines, delays and inter-processor interrupts |

---

## Using it

Add the source and the include directory to the application build:

```make
ACLINT_SW = <path>/arvern-ips/ahb_aclint/sw
SRCS     += $(ACLINT_SW)/src/ahb_aclint.c
CFLAGS   += -I$(ACLINT_SW)/include \
            -ffunction-sections -fdata-sections -Wl,--gc-sections
```

The library is C11, needs no `malloc`, no libc beyond `<stdint.h>`, `<stdbool.h>` and
`<stddef.h>`, and builds for RV32E. The delay conversions divide by shift-subtract
rather than with a 64-bit `/`, so they do not pull libgcc's divide routine into the
image (a 64-bit product still uses `__muldi3` without M); a loop that tests a deadline
converts its duration once, outside the loop. With `--gc-sections` an application only
pays for the functions it calls.

```c
#include "ahb_aclint.h"

static aclint_t clint;

void timer_init(void)
{
    const aclint_config_t cfg = { .base = 0x02000000u, .num_harts = 1,
                                  .sswi = true, .mtime_hz = 32768u };
    aclint_init(&clint, &cfg);                   /* checks the config, touches no register */

    aclint_timer_set_rel(&clint, 0, clint.mtime_hz);    /* MTIP on hart 0 in one second */
    /* ... enable mie.MTIE and mstatus.MIE through the core's CSR layer ... */
}

void mtimer_isr(void)
{
    aclint_timer_set_rel(&clint, 0, clint.mtime_hz);    /* re-arm; clears MTIP */
}

void wait_a_bit(void)
{
    aclint_delay_ms(&clint, 10);
}
```

---

## Conventions

- **Device handle.** Every call takes the `aclint_t` filled by `aclint_init()`; the
  library keeps no global state. The configuration carries what the hardware does not
  report: the base address, `NUM_HARTS`, whether the SSWI bank is built
  (`SU_MODE_EN`), and the MTIME tick rate, which is the `clk_lf_i` frequency of the
  platform. `aclint_init()` writes nothing, so it leaves the deadlines and IPIs of
  other harts alone.
- **Status codes.** Functions that take a hart index return `aclint_status_t`:
  `ACLINT_OK`, `ACLINT_ERR_PARAM` for a hart index at or above `num_harts` (or a
  configuration out of range, or a delay with `mtime_hz` 0), `ACLINT_ERR_ABSENT` for
  `aclint_ssip_set()` without SSWI.
- **Privilege.** With `PRIV_CHECK_EN=1` the IP answers MSWI and MTIMER accesses from
  M-mode only; anything else gets a bus ERROR (a resumable NMI on aRVern). Every
  function is M-mode only, except `aclint_ssip_set()`, which S-mode may call too.
- **Ordering-sensitive sequences** are implemented as the IP prescribes:
  - `aclint_mtime_read()` is the HI / LO / HI retry loop. A `MTIME_LO` read snapshots
    the upper half for the next `MTIME_HI` read, and that snapshot is shared by every
    reader; the retry makes the read consistent even when an interrupt handler or
    another hart reads MTIME in between.
  - `aclint_timer_set()` stores all-ones to LO, then the new HI, then the new LO, so no
    intermediate comparand falls below both the old and the new deadline and MTIP is
    never raised spuriously. `aclint_timer_disable()` stores all-ones to LO, then HI.
  - `aclint_mtime_write()` stores both halves back to back; the IP merges them into one
    atomic load. Its constraints (latency of two to three LF periods, interrupts masked
    across the two stores, `csrr time` not ordered against it, read back through MMIO)
    are listed in `ahb_aclint.h`.
- **Waiting.** Delays poll the MTIME low word with a wrap-safe difference, in chunks of
  up to 2^31 ticks, and wait one tick more than asked since a wait starts anywhere in
  the current tick. They need `clk_lf_i` running: an `MTIME_LO` read stalls the bus
  until the IP's view of MTIME is valid.
- **Hot paths are not wrapped.** `aclint_mtime_lo()`, `aclint_msip_set()`,
  `aclint_msip_clear()`, `aclint_msip_pending()` and `aclint_ssip_set()` are inline: a
  bounds check and one word load or store. All accesses are word accesses, as the IP
  requires.
- **No CSR code.** Interrupt enables, `sip.SSIP` clearing and trap handling belong to the
  core's CSR layer; this library only touches the IP's registers.

---

## API summary

| Area | Functions |
|---|---|
| Set-up | `aclint_init` |
| MTIME | `aclint_mtime_read`, `aclint_mtime_lo`, `aclint_mtime_write` |
| Timer compare | `aclint_timer_set`, `aclint_timer_set_rel`, `aclint_timer_disable`, `aclint_timer_get`, `aclint_timer_expired` |
| Delays | `aclint_delay_ticks`, `aclint_delay_us`, `aclint_delay_ms`, `aclint_us_to_ticks`, `aclint_ms_to_ticks` |
| Software interrupts | `aclint_msip_set`, `aclint_msip_clear`, `aclint_msip_pending`, `aclint_ssip_set` |

`ahb_aclint.h` documents each function; the
[programming model](../doc/ahb_aclint.md#programming-model) explains the registers
behind them.

---

## Verification

The library compiles warning-free (`-Wall -Wextra -Werror`) for `rv32ec_zicsr`/`ilp32e`
and `rv32imac_zicsr`/`ilp32`. The `_Static_assert`s of `ahb_aclint_regs.h` check the
register offsets at compile time.
