<p align="center">
  <img src="../../arv_custom_csr/doc/img/aRVern_light.png" alt="aRVern" width="180">
</p>

# APB peripheral example driver library

*Bare-metal C driver for the APB peripheral example: the register overlay, inline
accesses to the read-write and read-only banks, and the `MDELEG` privilege gates. It is
also the worked example of a driver for a new aRVern peripheral.*

The hardware is described in [doc/apb_periph_example.md](../doc/apb_periph_example.md).

---

## Layout

```
sw/
├── include/
│   ├── apb_periph_example_regs.h   register map: APB_PERIPH_TypeDef overlay, APB_PERIPH_<REG>_<FIELD>_Pos/_Msk
│   └── apb_periph_example.h        the API, with the inline register bank accesses
└── src/
    └── apb_periph_example.c        init, MDELEG privilege gates
```

| Layer | Files | Use it for |
|---|---|---|
| Registers | `apb_periph_example_regs.h` | direct register access; the API is built on it |
| Driver | `apb_periph_example.h`, `src/apb_periph_example.c` | binding an instance, the register banks, the privilege gates |

---

## Using it

Add the source and the include directory to the application build:

```make
APB_PERIPH_SW = <path>/arvern-ips/apb_periph_example/sw
SRCS     += $(APB_PERIPH_SW)/src/apb_periph_example.c
CFLAGS   += -I$(APB_PERIPH_SW)/include \
            -ffunction-sections -fdata-sections -Wl,--gc-sections
```

The library is C11, needs no `malloc`, no libc beyond `<stdint.h>`, `<stdbool.h>` and
`<stddef.h>`, and builds for RV32E. With `--gc-sections` an application only pays for
the functions it calls.

```c
#include "apb_periph_example.h"

static apb_periph_t periph;

void apb_periph_setup(void)                                  /* Machine mode */
{
    const apb_periph_config_t cfg = { .base = 0x10041000u };  /* e.g. */
    apb_periph_init(&periph, &cfg);

    /* Let Supervisor and User code read, Supervisor code write; refuse the rest
     * with PSLVERR */
    const apb_periph_access_t acc = { .wr_priv = APB_PERIPH_PRIV_S, .rd_priv = APB_PERIPH_PRIV_U,
                                      .error_resp = true };
    apb_periph_set_access(&periph, &acc);

    apb_periph_out_write(&periph, 0, 0x000000FFu);           /* register_00_o */
    uint32_t in = apb_periph_in_read(&periph, 0);            /* register_08_i */
    apb_periph_out_modify(&periph, 1, 0x0000FF00u, in << 8); /* bits [15:8] of register_01_o */
}
```

---

## Conventions

- **Device handle.** Every call takes the `apb_periph_t` filled by `apb_periph_init()`; the
  library keeps no global state, so several instances can coexist. The hardware has no
  identification register and no parameter software can see (`ADDRW` only sizes the
  window, `ASYNC_RST_EN` the reset style, `MDELEG_RST` only the value `MDELEG` holds after
  reset), so the configuration is the base address alone and `apb_periph_init()` touches
  no register.
- **Status codes.** `apb_periph_init()` and `apb_periph_set_access()` return `apb_periph_status_t`:
  `APB_PERIPH_OK`, or `APB_PERIPH_ERR_PARAM` for a null pointer, a misaligned base or the
  reserved privilege code `2`. Accessors return their value directly.
- **Privilege.** With the default `MDELEG_RST`, only Machine mode may access the window
  after reset (`APB_PERIPH_MDELEG_RESET`); a build may reset it open. `MDELEG`
  (`apb_periph_set_access`, `apb_periph_get_access`) is Machine mode only whatever the gates
  say; the gates then admit lower modes to the banks. An access below a gate is refused
  at every offset: with `error_resp` it gets PSLVERR, which `ahb_apb_bridge` turns into an
  AHB ERROR and an aRVern hart takes as a resumable data-bus NMI (not a load/store
  access fault); without it a write is dropped and a read returns 0, which software
  cannot tell from data. That NMI is taken in Machine mode only, so when an S-mode kernel
  hands the peripheral to U-mode tasks, Machine-mode firmware clears `error_resp` and the
  kernel never sees an NMI for their refused accesses. The library does not read the
  privilege mode: calling a function from a mode the gates refuse is the caller's error.
  That includes Machine-mode code running with `mstatus.MPRV = 1` and `MPP` below
  Machine, whose loads and stores carry the lower privilege.
- **One transfer per gate change.** `apb_periph_set_access()` writes `MDELEG` with one word
  store, so both gates and the response change together and are in force for the next
  transfer.
- **Hot paths are not wrapped.** `apb_periph_out_write`, `apb_periph_out_read` and
  `apb_periph_in_read` are inline and compile to one store or load; the bank index (`0..7`)
  is not checked. `apb_periph_out_modify` is a read-modify-write, not atomic. `REGIN`
  index `n` is `REGIN_(08+n)`. Byte and half-word stores to `REGOUT` are lane-exact.

---

## API summary

| Area | Functions |
|---|---|
| Set-up | `apb_periph_init` |
| Register banks | `apb_periph_out_write`, `apb_periph_out_read`, `apb_periph_out_modify`, `apb_periph_in_read` |
| Privilege gates | `apb_periph_set_access`, `apb_periph_get_access` |

`apb_periph_example.h` documents each function; the
[IP document](../doc/apb_periph_example.md#register-map) has the register map and the
access outcomes.

---

## Writing a driver for your own peripheral

A peripheral copied from this IP gets its driver the same way; these files are the
template.

**Register overlay.** `apb_periph_example_regs.h` describes the register window as one
`typedef struct` of `volatile` 32-bit members (`APB_PERIPH_IO` read-write, `APB_PERIPH_I`
read-only), in address order, with explicit `RESERVED` padding for holes. A
`_Static_assert` on the `offsetof` of each register (or the first of each group) and
on the `sizeof` of the whole window turns a padding mistake into a compile error. All
register accesses go through a pointer to this structure: the compiler then emits a
plain load or store at a constant offset.

**Field macros.** Every field gets a `<PREFIX>_<REG>_<FIELD>_Pos` and `_Msk` (CMSIS
naming), built with the `<PREFIX>_FIELD(pos, width)` helper, plus the reset value and
any encoding constants. The driver composes values from these and never writes a bare
bit number.

**Handle and configuration.** `<prefix>_init(&dev, &cfg)` fills a handle from a
configuration structure: the base address, and the build parameters that change what
software sees but that the hardware does not report (counts of channels, optional
blocks). If your peripheral exposes an ID or capability register, read it in `init`
and record the result in the handle; every other call takes the handle, so no global
state is needed and several instances can coexist.

**Status codes.** Calls that can fail return a `<prefix>_status_t` enum: `OK = 0`,
negative errors (`ERR_PARAM` for an argument out of range for this build, `ERR_ABSENT`
for a feature that is not built, and so on). Trivial accessors return their value.

**Inline hot paths.** Accesses that sit in a loop or an interrupt handler (a data
register, a status read) are `static inline` in the API header and do no checking, so
they cost one load or store. Anything with an ordering constraint (a multi-word
update, a lock, a gate change) lives in the `.c` file as one function, with a one-line
comment saying why the order matters, like `apb_periph_set_access()`.

---

## Verification

The `_Static_assert`s of `apb_periph_example_regs.h` check the register offsets at
compile time, and the library builds warning-free with `-Wall -Wextra -Werror` for
`rv32ec_zicsr`/`ilp32e` and `rv32imac_zicsr`/`ilp32`. The register behaviour it relies
on is the one the IP's test suite checks (see the
[IP document](../doc/apb_periph_example.md#verification)).
