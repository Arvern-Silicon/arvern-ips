<p align="center">
  <img src="../../arv_custom_csr/doc/img/aRVern_light.png" alt="aRVern" width="180">
</p>

# PLIC driver library

*Bare-metal C driver for the aRVern PLIC: register definitions and a small API for
source priorities, per-context enables and thresholds, the pending bits and the
claim / complete handshake.*

The hardware and its programming model are described in
[doc/ahb_plic.md](../doc/ahb_plic.md).

---

## Layout

```
sw/
├── include/
│   ├── ahb_plic_regs.h  register map: PLIC_TypeDef overlay, PLIC_<REG>_<FIELD>_Pos/_Msk
│   └── ahb_plic.h       the API, with plic_claim() / plic_complete() inline
└── src/
    └── ahb_plic.c       configuration, contexts, priorities, enables, thresholds,
                         pending query, dispatch
```

| Layer | Files | Use it for |
|---|---|---|
| Registers | `ahb_plic_regs.h` | direct register access; the API is built on it |
| Driver | `ahb_plic.h`, `src/ahb_plic.c` | everything the PLIC does |

---

## Using it

Add the source and the include directory to the application build:

```make
PLIC_SW   = <path>/arvern-ips/ahb_plic/sw
SRCS     += $(PLIC_SW)/src/ahb_plic.c
CFLAGS   += -I$(PLIC_SW)/include -ffunction-sections -fdata-sections -Wl,--gc-sections
```

The library is C11, needs no `malloc`, no libc beyond `<stdint.h>`, `<stdbool.h>` and
`<stddef.h>`, and builds for RV32E. With `--gc-sections` an application only pays for
the functions it calls.

```c
#include "ahb_plic.h"

#define UART_IRQ  3u

static plic_t   plic;
static unsigned ctx_m;                                   /* hart 0, M-mode */

static void plic_isr(uint32_t src, void *arg)
{
    (void) arg;
    if (src == UART_IRQ)
        uart_service();                                  /* drops the UART's request line */
}

void irq_init(void)
{
    const plic_config_t cfg = { .base = 0x0C000000u, .num_sources = 31u,
                                .num_harts = 1u, .prio_bits = 3u, .su_mode = true };
    plic_init(&plic, &cfg);                              /* checks the parameters only */
    plic_context(&plic, 0u, false, &ctx_m);

    plic_set_priority(&plic, UART_IRQ, 1u);
    plic_set_threshold(&plic, ctx_m, 0u);
    plic_enable(&plic, ctx_m, UART_IRQ);
    /* then mie.MEIE and mstatus.MIE, in the platform's trap layer */
}

/* Called by the platform's trap layer on a machine external interrupt. A claim
 * ignores the threshold, so the loop also drains sources at or below it. */
void external_irq(void)
{
    while (plic_dispatch(&plic, ctx_m, plic_isr, NULL) > 0)
        ;
}
```

The configuration must match the RTL parameters of the PLIC instance (`NUM_SOURCES`,
`NUM_HARTS`, `PRIO_BITS`, `SU_MODE_EN`): the PLIC has no register reporting them.

---

## Conventions

- **Device handle.** Every call takes the `plic_t` filled by `plic_init()`; the library
  keeps no global state. The handle records the build parameters and every call checks
  its source, context, priority and threshold arguments against them. `plic_init()`
  writes no register: the PLIC is shared by every hart and resets with every priority,
  enable and threshold at 0. `plic_context_clear()` returns one context to that state.
- **Status codes.** Functions that can fail return `plic_status_t`: `PLIC_OK`, an
  argument out of range for this build (`PLIC_ERR_PARAM`: source 0 or above
  `NUM_SOURCES`, context at or above `NUM_CONTEXTS`, priority or threshold above
  `2^PRIO_BITS - 1`), or an S-mode context in a build without one (`PLIC_ERR_ABSENT`).
  Getters return 0 or `false` for an out-of-range argument.
- **Context numbering.** With `SU_MODE_EN=1`, `ctx = 2*hart + s_mode`: even contexts are
  the M-mode contexts, odd ones the S-mode contexts. With `SU_MODE_EN=0`, `ctx = hart`,
  all M-mode. Context `ctx` drives its hart's `mip.MEIP` (M) or `mip.SEIP` (S).
  `plic_context()` computes the index.
- **Access control.** Every access is a 32-bit word access: the overlay has no byte or
  halfword fields, and the PLIC answers any other size with ERROR. With the IP's
  privilege filter (`PRIV_CHECK_EN=1`):

  | Registers | M-mode | S-mode | U-mode |
  |---|:-:|:-:|:-:|
  | Priorities | RW | RW | denied |
  | Pending bits | read (writes ignored) | read (writes ignored) | denied |
  | Enables and target (threshold, claim / complete) of an M-context | RW | denied | denied |
  | Enables and target of an S-context | RW | RW | denied |
  | Reserved offsets | read 0 | read 0 | denied |

  With `SU_MODE_EN=0` every context is an M-context, so S-mode software can reach only
  the priorities and the pending bits. A denied access is answered with an AHB ERROR: a
  denied write changes nothing, a denied claim claims nothing, a denied read returns 0,
  and an aRVern hart takes the ERROR as a resumable NMI (`mncause = 0x80000003`) — not
  as a status code. The library cannot detect it beforehand: call each function only
  from a privilege allowed on the registers it touches. With `PRIV_CHECK_EN=0` the
  fabric decides, and with `hsmode` tied 0 every privileged access counts as M-mode.
- **Level-triggered gateway.** Every source is level-triggered; there is no
  edge-triggered mode. The pending bit is set while the line is high and the source is
  not in service, and only a claim clears it. A claim marks the source in service;
  completing it releases the gateway, and if the line is still high the source pends
  again on the next clock edge and is delivered again. **The handler must clear the
  device's request before the completion.** A request that went away before the claim
  still leaves the pending bit set: the handler must cope with a device that no longer
  needs service.
- **Claim and complete.** `plic_claim()` returns the highest-priority pending and enabled
  source of non-zero priority, ignoring the threshold (the threshold only gates the
  interrupt output), and 0 when there is none. `plic_complete()` must be given the ID its
  own claim returned, on the same context: completing an ID claimed elsewhere releases a
  source still being serviced. A completion of a source that is not enabled for the
  context is ignored by the PLIC and leaves the source in service, so **complete before
  disabling** a source. `plic_dispatch()` does claim, handler call, complete in that
  order and completes only a non-zero claim. A source at priority 0 is never delivered
  nor claimed; its pending bit stays set until its priority is raised and it is claimed.
- **Enables are read-modify-write.** One enable word holds 32 sources of one context. An
  M-mode and an S-mode program that both edit the same S-context word must serialise
  their edits.
- **No trap layer.** The library touches only PLIC registers: enabling `mie.MEIE` /
  `mie.SEIE`, the trap vector and the handler entry belong to the platform. The
  dispatch helper takes a function pointer and an argument, so it needs no global
  state either.

---

## API summary

| Area | Functions |
|---|---|
| Set-up | `plic_init`, `plic_context`, `plic_context_clear` |
| Sources | `plic_set_priority`, `plic_get_priority`, `plic_is_pending`, `plic_pending_word` |
| Contexts | `plic_enable`, `plic_disable`, `plic_is_enabled`, `plic_set_threshold`, `plic_get_threshold` |
| Claim / complete | `plic_claim`, `plic_complete` (inline: one load / one store), `plic_dispatch` |

`ahb_plic.h` documents each function; [doc/ahb_plic.md](../doc/ahb_plic.md) describes the
registers behind them.

---

## Verification

The `_Static_assert`s of `ahb_plic_regs.h` check every window offset and the per-context
strides at compile time. The library builds without warnings under `-Wall -Wextra
-Werror` for RV32E (`rv32ec_zicsr`, `ilp32e`) and RV32IMAC (`rv32imac_zicsr`, `ilp32`);
`plic_claim()` and `plic_complete()` compile to a bound check and a single word load or
store.
