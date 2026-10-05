<p align="center">
  <img src="../../arv_custom_csr/doc/img/aRVern_light.png" alt="aRVern" width="180">
</p>

# AHB peripheral example driver library

*Bare-metal C driver for the AHB peripheral example: the register overlay, inline
accesses to the read-write and read-only banks, and the `MDELEG` privilege gates. It is
also the worked example of a driver for a new aRVern peripheral.*

The hardware is described in [doc/ahb_periph_example.md](../doc/ahb_periph_example.md).

---

## Layout

```
sw/
├── include/
│   ├── ahb_periph_example_regs.h   register map: PERIPH_TypeDef overlay, PERIPH_<REG>_<FIELD>_Pos/_Msk
│   └── ahb_periph_example.h        the API, with the inline register bank accesses
└── src/
    └── ahb_periph_example.c        init, MDELEG privilege gates
```

| Layer | Files | Use it for |
|---|---|---|
| Registers | `ahb_periph_example_regs.h` | direct register access; the API is built on it |
| Driver | `ahb_periph_example.h`, `src/ahb_periph_example.c` | binding an instance, the register banks, the privilege gates |

---

## Using it

Add the source and the include directory to the application build:

```make
PERIPH_SW = <path>/arvern-ips/ahb_periph_example/sw
SRCS     += $(PERIPH_SW)/src/ahb_periph_example.c
CFLAGS   += -I$(PERIPH_SW)/include \
            -ffunction-sections -fdata-sections -Wl,--gc-sections
```

The library is C11, needs no `malloc`, no libc beyond `<stdint.h>`, `<stdbool.h>` and
`<stddef.h>`, and builds for RV32E. With `--gc-sections` an application only pays for
the functions it calls.

```c
#include "ahb_periph_example.h"

static periph_t periph;

void periph_setup(void)                                  /* Machine mode */
{
    const periph_config_t cfg = { .base = 0x10041000u };  /* e.g. */
    periph_init(&periph, &cfg);

    /* Let Supervisor and User code read, Supervisor code write; refuse the rest
     * with an AHB ERROR */
    const periph_access_t acc = { .wr_priv = PERIPH_PRIV_S, .rd_priv = PERIPH_PRIV_U,
                                  .error_resp = true };
    periph_set_access(&periph, &acc);

    periph_out_write(&periph, 0, 0x000000FFu);           /* register_00_o */
    uint32_t in = periph_in_read(&periph, 0);            /* register_08_i */
    periph_out_modify(&periph, 1, 0x0000FF00u, in << 8); /* bits [15:8] of register_01_o */
}
```

---

## Conventions

- **Device handle.** Every call takes the `periph_t` filled by `periph_init()`; the
  library keeps no global state, so several instances can coexist. The hardware has no
  identification register and no parameter software can see (`ADDRW` only sizes the
  window, `ASYNC_RST_EN` the reset style), so the configuration is the base address
  alone and `periph_init()` touches no register.
- **Status codes.** `periph_init()` and `periph_set_access()` return `periph_status_t`:
  `PERIPH_OK`, or `PERIPH_ERR_PARAM` for a null pointer, a misaligned base or the
  reserved privilege code `2`. Accessors return their value directly.
- **Privilege.** After reset only Machine mode may access the window. `MDELEG`
  (`periph_set_access`, `periph_get_access`) is Machine mode only whatever the gates
  say; the gates then admit lower modes to the banks. An access below a gate is refused
  at every offset: with `error_resp` it gets an AHB ERROR, which an aRVern hart takes as
  a resumable data-bus NMI (not a load/store access fault); without it a write is
  dropped and a read returns 0, which software cannot tell from data. The library does
  not read the privilege mode: calling a function from a mode the gates refuse is the
  caller's error.
- **One transfer per gate change.** `periph_set_access()` writes `MDELEG` with one word
  store, so both gates and the response change together and are in force for the next
  transfer.
- **Hot paths are not wrapped.** `periph_out_write`, `periph_out_read` and
  `periph_in_read` are inline and compile to one store or load; the bank index (`0..7`)
  is not checked. `periph_out_modify` is a read-modify-write, not atomic. `REGIN`
  index `n` is `REGIN_(08+n)`. Byte and half-word stores to `REGOUT` are lane-exact.

---

## API summary

| Area | Functions |
|---|---|
| Set-up | `periph_init` |
| Register banks | `periph_out_write`, `periph_out_read`, `periph_out_modify`, `periph_in_read` |
| Privilege gates | `periph_set_access`, `periph_get_access` |

`ahb_periph_example.h` documents each function; the
[IP document](../doc/ahb_periph_example.md#register-map) has the register map and the
access outcomes.

---

## Writing a driver for your own peripheral

A peripheral copied from this IP gets its driver the same way; these files are the
template.

**Register overlay.** `ahb_periph_example_regs.h` describes the register window as one
`typedef struct` of `volatile` 32-bit members (`PERIPH_IO` read-write, `PERIPH_I`
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
comment saying why the order matters, like `periph_set_access()`.

---

## Verification

The `_Static_assert`s of `ahb_periph_example_regs.h` check the register offsets at
compile time, and the library builds warning-free with `-Wall -Wextra -Werror` for
`rv32ec_zicsr`/`ilp32e` and `rv32imac_zicsr`/`ilp32`. The register behaviour it relies
on is the one the IP's test suite checks (see the
[IP document](../doc/ahb_periph_example.md#verification)).
