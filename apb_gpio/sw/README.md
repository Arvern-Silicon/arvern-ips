<p align="center">
  <img src="../../arv_custom_csr/doc/img/aRVern_light.png" alt="aRVern" width="180">
</p>

# GPIO driver library

*Bare-metal C driver for the aRVern GPIO: the register overlay, input and wake
enables, pin direction and output, single-store set / clear / toggle, and per-pin edge
and level interrupt configuration.*

The hardware is described in [doc/apb_gpio.md](../doc/apb_gpio.md).

---

## Layout

```
sw/
├── include/
│   ├── apb_gpio_regs.h   register map: APB_GPIO_TypeDef overlay, APB_GPIO_<REG>_<FIELD>_Pos/_Msk
│   └── apb_gpio.h        the API; pin values and pending bits are inline
└── src/
    └── apb_gpio.c        init, input / wake enables, direction, interrupt mode and enable
```

| Layer | Files | Use it for |
|---|---|---|
| Registers | `apb_gpio_regs.h` | direct register access; the API is built on it |
| Driver | `apb_gpio.h`, `src/apb_gpio.c` | binding an instance, pins, interrupts |

---

## Using it

Add the source and the include directory to the application build:

```make
APB_GPIO_SW = <path>/arvern-ips/apb_gpio/sw
SRCS   += $(APB_GPIO_SW)/src/apb_gpio.c
CFLAGS += -I$(APB_GPIO_SW)/include \
          -ffunction-sections -fdata-sections -Wl,--gc-sections
```

The library is C11, needs no `malloc`, no libc beyond `<stdint.h>`, `<stdbool.h>` and
`<stddef.h>`, and builds for RV32E. With `--gc-sections` an application only pays for
the functions it calls.

```c
#include "apb_gpio.h"

#define LED     (1u << 0)
#define BUTTON  (1u << 4)

static apb_gpio_t gpio;

void board_init(void)                                    /* Machine mode */
{
    const apb_gpio_config_t cfg = { .base = 0x10042000u, .pin_nr = 8 };  /* e.g. */
    if (apb_gpio_init(&gpio, &cfg) != APB_GPIO_OK)               /* reads INFO and CFG */
        return;

    apb_gpio_set_dir(&gpio, LED, APB_GPIO_DIR_OUT);
    apb_gpio_input_enable(&gpio, BUTTON);                    /* sample the button */
    apb_gpio_irq_config(&gpio, 4, APB_GPIO_IRQ_FALL);            /* button press */
    apb_gpio_wake_enable(&gpio, BUTTON);                     /* a press restarts a stopped clock */
    apb_gpio_irq_enable(&gpio, BUTTON);
    /* ... route irq_o[4] (or irq_any_o) through the PLIC and enable it ... */
}

void apb_gpio_isr(void)
{
    uint32_t pend = apb_gpio_irq_status(&gpio);              /* pending and enabled */
    apb_gpio_irq_clear(&gpio, pend);                         /* before acting, before PLIC complete */
    if (pend & BUTTON)
        apb_gpio_toggle(&gpio, LED);
}
```

---

## Conventions

- **Device handle.** Every call takes the `apb_gpio_t` filled by `apb_gpio_init()`; the
  library keeps no global state, so several instances can coexist. The hardware
  reports its pins in `INFO` (bits 0 .. `GPIO_NR`-1 set) and `ALT_NR` in `CFG`, so the
  configuration is the base address plus an optional expected pin count and
  alternate-function count (`pin_nr`, `alt_nr`; 0 accepts what the hardware says, a
  different non-zero value is an error). `apb_gpio_init()` reads `INFO` and `CFG` and
  writes nothing.
- **Inputs are off after reset.** A pin is sampled, and raises interrupts or wake
  requests, only once `apb_gpio_input_enable()` has set its `IN_EN` bit. The pin's input
  stage then flushes for one to three `pclk_aon_i` cycles (`SYNC_EN`): `apb_gpio_read()`
  returns 0 for it and no event is reported until then, so the step from the held 0
  to the pin's level is never seen as an edge. `apb_gpio_input_disable()` stops the pin at
  once. `apb_gpio_wake_enable()` lets a change on an enabled pin raise `gpio_wake_o`, in
  the direction the pin's detection mode reports (any change with `APB_GPIO_IRQ_NONE`);
  set the mode first. A change that persists is reported in `IRQ_PEND`; a short event
  is reported only by a wake hold in the SoC, where it has one (IP document, *Wake*).
- **Status codes.** `apb_gpio_init()`, `apb_gpio_input_enable()`, `apb_gpio_input_disable()`,
  `apb_gpio_wake_enable()`, `apb_gpio_wake_disable()`, `apb_gpio_set_dir()`, `apb_gpio_irq_config()`,
  `apb_gpio_irq_enable()`, `apb_gpio_irq_disable()`, `apb_gpio_alt_select()`, `apb_gpio_alt_release()`
  and `apb_gpio_set_access()` return `apb_gpio_status_t`: `APB_GPIO_OK`, `APB_GPIO_ERR_PARAM`
  for a null pointer, a misaligned base, a pin at or above the pin count, an unknown
  mode or privilege code, a function at or above `alt_nr`, or a pin or function count
  different from the expected one, and `APB_GPIO_ERR_ABSENT` when `INFO` does not hold
  a mask of pins 0 .. n-1 at the base or `CFG` does not hold version 1.
  Accessors return their value directly.
- **Privilege.** With the default `MDELEG_RST`, only Machine mode may access the window
  after reset (`APB_GPIO_MDELEG_RESET`), `apb_gpio_init()` included; a build may reset it
  open. `MDELEG` (`apb_gpio_set_access`, `apb_gpio_get_access`) is Machine mode only
  whatever the gates say; the gates then admit lower modes to every other register. An
  access below a gate is refused at every offset: with `error_resp` it gets PSLVERR,
  which `ahb_apb_bridge` turns into an AHB ERROR and an aRVern hart takes as a
  resumable data-bus NMI (not a load/store access fault); without it a write is
  dropped and a read returns 0. That NMI is taken in Machine mode only, so when an
  S-mode kernel gives the pins to U-mode tasks, Machine-mode firmware clears
  `error_resp`. The library does not read the privilege mode: calling a function from
  a mode the gates refuse is the caller's error, including Machine-mode code running
  with `mstatus.MPRV = 1` and `MPP` below Machine.
- **Atomic and read-modify-write updates.** `apb_gpio_set()`, `apb_gpio_clear()`,
  `apb_gpio_toggle()`, `apb_gpio_set_dir()`, `apb_gpio_irq_enable()` and
  `apb_gpio_irq_disable()` are one store to a set / clear / toggle alias, so the main
  program and an interrupt handler can work on different pins safely. `IN_EN`,
  `WAKE_EN`, the mode registers and the alternate-function registers have no such
  aliases: the functions that change them read-modify-write and are not atomic against
  a handler or another manager writing the same register.
- **Open drain.** Keep the pin's `OUTPUT` bit at 0 and switch its direction:
  `apb_gpio_set_dir(..., APB_GPIO_DIR_OUT)` pulls the line low,
  `APB_GPIO_DIR_IN` releases it to the external pull-up, and `apb_gpio_read()` returns
  the line (with the pin's input enabled). Pull-ups, drive strength and slew rate are
  the SoC's pad controller's, not this library's.
- **Mode changes.** `apb_gpio_irq_config()` clears the pin's old mode bits, then its
  latched edge, then sets the new mode bits: an edge latched under the old mode is
  discarded and no edge of the new mode is lost. It leaves `IRQ_EN` alone; a level
  mode whose condition already holds on an enabled pin is pending at once.
- **Edges and levels.** An edge stays pending until `apb_gpio_irq_clear()`; a clear in the
  same cycle as a new edge leaves the bit set. A level is live: `apb_gpio_irq_clear()`
  does not clear it, removing its cause does (the pin, or the mode). A handler reads
  `apb_gpio_irq_status()` (`IRQ_STAT`, pending and enabled) and clears those bits:
  clearing all of `apb_gpio_irq_pending()` would also discard the edges of pins
  software polls.
- **Alternate functions.** `apb_gpio_alt_select()` releases the pins, sets their function
  number, then hands them over with one `ALT_EN` write, so a pin never passes through
  another function (it is under `OUTPUT`/`OE` for the few stores in between).
  `apb_gpio_alt_release()` returns pins to `OUTPUT`/`OE`, which kept their values. Which
  peripheral signal sits in which function slot is SoC wiring: keep it in the board
  support.
- **Hot paths are not wrapped.** `apb_gpio_write`, `apb_gpio_set`, `apb_gpio_clear`,
  `apb_gpio_toggle`, `apb_gpio_read`, `apb_gpio_read_output`, `apb_gpio_irq_pending`,
  `apb_gpio_irq_status` and `apb_gpio_irq_clear` are inline and compile to one load or store; masks are not
  checked (the hardware ignores bits above its pin count).
- **No CSR or PLIC code.** Interrupt routing, the PLIC and the core's enables belong to
  their own layers; this library only touches the IP's registers.

---

## API summary

| Area | Functions |
|---|---|
| Set-up | `apb_gpio_init` |
| Input and wake | `apb_gpio_input_enable`, `apb_gpio_input_disable`, `apb_gpio_wake_enable`, `apb_gpio_wake_disable` |
| Direction | `apb_gpio_set_dir` |
| Pin values | `apb_gpio_write`, `apb_gpio_set`, `apb_gpio_clear`, `apb_gpio_toggle`, `apb_gpio_read`, `apb_gpio_read_output` |
| Interrupts | `apb_gpio_irq_config`, `apb_gpio_irq_enable`, `apb_gpio_irq_disable`, `apb_gpio_irq_pending`, `apb_gpio_irq_status`, `apb_gpio_irq_clear` |
| Alternate functions | `apb_gpio_alt_select`, `apb_gpio_alt_release` |
| Privilege gates | `apb_gpio_set_access`, `apb_gpio_get_access` |

`apb_gpio.h` documents each function; the
[IP document](../doc/apb_gpio.md#register-map) has the register map and the
interrupt semantics.

---

## Verification

The library compiles warning-free (`-Wall -Wextra -Werror`) for `rv32ec_zicsr`/`ilp32e`
and `rv32imac_zicsr`/`ilp32`. The `_Static_assert`s of `apb_gpio_regs.h` check the
register offsets at compile time.
