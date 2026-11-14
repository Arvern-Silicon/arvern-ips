<p align="center">
  <img src="../../arv_custom_csr/doc/img/aRVern_light.png" alt="aRVern" width="180">
</p>

# APB SPI driver library

*Bare-metal C driver for the APB SPI controller: the register overlay, entry builders,
a transaction runner that pushes entries and collects what they receive, and two
device layers written only with entries: an SD card in SPI mode and a SPI NOR flash.*

The hardware is described in [doc/apb_spi.md](../doc/apb_spi.md).

---

## Layout

```
sw/
├── include/
│   ├── apb_spi_regs.h      register map: APB_SPI_TypeDef overlay, APB_SPI_<REG>_<FIELD>_Pos/_Msk
│   └── apb_spi.h           the API, with the inline status, push and pop accesses
├── src/
│   └── apb_spi.c           init, rate, mode, select timing, entry builders, apb_spi_run, MDELEG
├── sd/
│   ├── apb_spi_sd.h        SD card in SPI mode
│   └── apb_spi_sd.c
└── flash/
    ├── apb_spi_flash.h     SPI NOR flash (S25FL128S command set)
    └── apb_spi_flash.c
```

| Layer | Files | Use it for |
|---|---|---|
| Registers | `apb_spi_regs.h` | direct register access; the API is built on it |
| Driver | `apb_spi.h`, `src/apb_spi.c` | binding an instance, the serial clock and mode, entries, interrupts, the privilege gates |
| SD card | `sd/apb_spi_sd.*` | initialising a card and reading / writing 512-byte blocks |
| Flash | `flash/apb_spi_flash.*` | status, reads (quad when the build has four lanes), page programs |

---

## Using it

Add the sources and the include directories to the application build:

```make
APB_SPI_SW = <path>/arvern-ips/apb_spi/sw
SRCS     += $(APB_SPI_SW)/src/apb_spi.c $(APB_SPI_SW)/sd/apb_spi_sd.c
CFLAGS   += -I$(APB_SPI_SW)/include -I$(APB_SPI_SW)/sd \
            -ffunction-sections -fdata-sections -Wl,--gc-sections
```

The library is C11, needs no `malloc`, no libc beyond `<stdint.h>`, `<stdbool.h>` and
`<stddef.h>`, and builds for RV32E. With `--gc-sections` an application only pays for
the functions it calls.

```c
#include "apb_spi_sd.h"

static apb_spi_t    spi;
static apb_spi_sd_t card;
static uint32_t     block[128];                       /* 512 bytes, little-endian */

int sd_setup(void)                                    /* Machine mode */
{
    const apb_spi_config_t cfg = { .base = 0x10045000u };          /* e.g. */
    if (apb_spi_init(&spi, &cfg) != APB_SPI_OK)
        return -1;
    /* e.g. 50 MHz pclk, SCK at pclk / 2 for data, RX_DLY 1 (doc "Receive timing") */
    if (apb_spi_sd_init(&card, &spi, 0, 50000000u, 25000000u, 1) != APB_SPI_SD_OK)
        return -1;
    return apb_spi_sd_read(&card, 0, block, 1);        /* block 0 */
}
```

A device of your own is a list of entries; `apb_spi_run()` pushes them as the transmit
FIFO has room and stores each entry's received words at its own destination:

```c
uint32_t id;
const apb_spi_entry_t read_id[] = {
    { APB_SPI_XFER(APB_SPI_KIND_TX,  8, 1, APB_SPI_HOLD, 0), 0x9F, 0   },  /* command, select held */
    { APB_SPI_XFER(APB_SPI_KIND_RX, 24, 1, 0,            0), 0,    &id },  /* 3 bytes, select released */
};
apb_spi_run(&spi, read_id, 2);
```

---

## Conventions

- **Device handle.** Every call takes the `apb_spi_t` filled by `apb_spi_init()`, which
  reads `CFG` (version 1) and records the FIFO depths, the selects, the lane width and
  whether the build receives and polls; the library keeps no global state, so several
  instances can coexist.
- **Status codes.** Calls that can fail return `apb_spi_status_t`: `APB_SPI_OK`,
  `APB_SPI_ERR_PARAM` for an argument this build refuses (a lane width it does not have,
  a frame length not a multiple of the lanes, a select beyond `CS_NR`, a receiving entry
  without a receive path), `APB_SPI_ERR_ABSENT` when `CFG` does not hold version 1,
  `APB_SPI_ERR_TIMEOUT` when a `POLL` ran out of frames or a wait ran out. The SD layer
  has its own `apb_spi_sd_status_t`.
- **Entries and FIFOs.** The entry builders wait for room in the transmit FIFO but pop
  nothing; a transaction that receives more words than the receive FIFO holds goes
  through `apb_spi_run()`, which pops while it pushes, or the caller pops itself. A
  `POLL`'s mask and value travel in its payload (`APB_SPI_POLL_ARG`), so polls for
  different conditions queue back to back.
- **XFER.** The builders and `apb_spi_run()` save `XFER` and restore it afterwards, so a
  handler that pushes entries does not disturb an interrupted push sequence;
  `apb_spi_push()` is the raw form for a caller that owns `XFER`.
- **Configuration.** The mode (`apb_spi_set_mode`), rate (`apb_spi_set_rate`,
  `apb_spi_set_clkdiv`) and select timing (`apb_spi_set_cs`) may be written at any time;
  the IP latches them at each transaction start.
- **SD layer.** Runs the card in mode 0 with `BSWAP`, so a 512-byte block moves as 128
  words in little-endian byte order with plain loads and stores; commands go out as
  single bytes. Identification at 400 kHz, then the caller's data rate; standard- and
  high-capacity cards; CRC off (CMD0 and CMD8 carry their constant CRCs). Busy waits and
  token waits are bounded `POLL`s repeated a bounded number of times; on an error the
  transaction is aborted and the card must be initialised again.
- **Flash layer.** Words carry the flash bytes in order, the lowest address in bits
  31:24. Quad reads and programs need the flash's `QUAD` configuration bit set
  beforehand; `apb_spi_flash_t.dummy` is the Quad I/O Read latency of the flash's
  latency code.
- **Privilege.** With the default `MDELEG_RST` only Machine mode may access the window
  after reset (`APB_SPI_MDELEG_RESET`). `MDELEG` (`apb_spi_set_access`,
  `apb_spi_get_access`) is Machine mode only whatever the gates say. The library does not
  read the privilege mode: calling a function from a mode the gates refuse is the
  caller's error.

---

## API summary

| Area | Functions |
|---|---|
| Set-up | `apb_spi_init`, `apb_spi_set_rate`, `apb_spi_set_clkdiv`, `apb_spi_set_mode`, `apb_spi_set_cs`, `apb_spi_enable`, `apb_spi_disable` |
| Entries | `apb_spi_tx`, `apb_spi_rx`, `apb_spi_dummy`, `apb_spi_poll`, `apb_spi_run`, `apb_spi_push`, `apb_spi_pop` |
| Status | `apb_spi_status`, `apb_spi_tx_level`, `apb_spi_rx_level`, `apb_spi_idle`, `apb_spi_wait_idle` |
| Interrupts, commands | `apb_spi_set_thresholds`, `apb_spi_irq_enable`, `apb_spi_irq_disable`, `apb_spi_irq_pending`, `apb_spi_irq_clear`, `apb_spi_flush`, `apb_spi_abort` |
| Privilege gates | `apb_spi_set_access`, `apb_spi_get_access` |
| SD card | `apb_spi_sd_init`, `apb_spi_sd_read`, `apb_spi_sd_write` |
| Flash | `apb_spi_flash_status`, `apb_spi_flash_read`, `apb_spi_flash_program` |

---

## Verification

The `_Static_assert`s of `apb_spi_regs.h` check the register offsets at compile time,
and the library builds warning-free with `-Wall -Wextra -Werror` for
`rv32ec_zicsr`/`ilp32e` and `rv32imac_zicsr`/`ilp32`. The sequences the SD and flash
layers issue are the ones the IP's `sd_sequence` and `flash_sequence` tests run against
the bench's SD-card and flash models (see the
[IP document](../doc/apb_spi.md#verification)).
