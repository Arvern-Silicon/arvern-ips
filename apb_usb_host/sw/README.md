<p align="center">
  <img src="../../arv_custom_csr/doc/img/aRVern_light.png" alt="aRVern" width="180">
</p>

# APB USB host driver library

*Bare-metal C driver for the low-speed USB host: the register overlay, the port's state
and device information, the report read, software control transfers, and an HID layer
that turns the raw reports of keyboards, mice and gamepads into key events, mouse
movement and button states.*

The hardware is described in [doc/apb_usb_host.md](../doc/apb_usb_host.md).

---

## Layout

```
sw/
├── include/
│   ├── apb_usb_host_regs.h   register map: APB_USB_HOST_TypeDef overlay, APB_USB_HOST_<REG>_<FIELD>_Pos/_Msk
│   └── apb_usb_host.h        the API, with the inline state, interrupt and transfer accesses
├── src/
│   └── apb_usb_host.c        init, enable, names, device information, report read, control transfers, MDELEG
└── hid/
    ├── apb_usb_host_hid.h    HID report decoder: boot keyboard, boot mouse, gamepad layouts
    ├── apb_usb_host_hid.c
    └── test/                 host unit tests (make -C sw/hid/test)
```

| Layer | Files | Use it for |
|---|---|---|
| Registers | `apb_usb_host_regs.h` | direct register access; the API is built on it |
| Driver | `apb_usb_host.h`, `src/apb_usb_host.c` | binding an instance, enabling the port, its state and device, reports, interrupts, control transfers, the privilege gates |
| HID | `hid/apb_usb_host_hid.*` | keyboard events and keys held, mouse movement and buttons, gamepad buttons and axes |

---

## Using it

Add the sources and the include directories to the application build:

```make
USB_SW  = <path>/arvern-ips/apb_usb_host/sw
SRCS   += $(USB_SW)/src/apb_usb_host.c $(USB_SW)/hid/apb_usb_host_hid.c
CFLAGS += -I$(USB_SW)/include -I$(USB_SW)/hid \
          -ffunction-sections -fdata-sections -Wl,--gc-sections
```

The library is C11, needs no `malloc`, no libc beyond `<stdint.h>`, `<stdbool.h>` and
`<stddef.h>`, and builds for RV32E. With `--gc-sections` an application only pays for
the functions it calls.

A port with its decoder, fed from the port's interrupt:

```c
#include "apb_usb_host_hid.h"

static apb_usb_host_t     usb;
static apb_usb_host_hid_t hid;

void usb_irq(void)                                  /* the PLIC source of the port */
{
    uint32_t pend = apb_usb_host_hid_service(&hid);  /* decodes the new report, follows the device */
    if (pend & APB_USB_HOST_IRQ_FAIL)
        log_failure(apb_usb_host_err_name(apb_usb_host_err(&usb)), apb_usb_host_step(&usb));
}

int usb_setup(void)                                 /* Machine mode */
{
    const apb_usb_host_config_t cfg = { .base = 0x10043000u };          /* e.g. */
    if (apb_usb_host_init(&usb, &cfg) != APB_USB_HOST_OK)
        return -1;
    apb_usb_host_hid_init(&hid, &usb);
    apb_usb_host_irq_enable(&usb, APB_USB_HOST_HID_IRQ_MASK);
    apb_usb_host_enable(&usb, APB_USB_HOST_OPT_DEFAULT);                /* SET_PROTOCOL(boot), SET_IDLE(0) */
    return 0;
}

void frame(void)                                    /* once a frame */
{
    apb_usb_host_hid_key_t ev;
    int32_t dx, dy;

    while (apb_usb_host_hid_key_pop(&hid, &ev))
        if (ev.down)
            putchar(apb_usb_host_hid_key_ascii(ev.key, ev.mods));
    apb_usb_host_hid_mouse_take(&hid, &dx, &dy, 0);
    uint32_t pad = apb_usb_host_hid_pad_buttons(&hid);  /* APB_USB_HOST_HID_PAD_* */
    ...
}
```

Without the interrupt, the same `apb_usb_host_hid_service()` called once a frame from
the main loop keeps the gamepad state, the keys held and the device kind current; only
the key events and the movement of reports that came and went between two calls are
lost.

A software control transfer (builds with `CTRL_EN = 1`): the HID report descriptor of
the selected interface, read through the 8-byte `XDATA` window packet by packet:

```c
uint8_t  desc[256];
size_t   len;
unsigned result;
const apb_usb_host_setup_t get_report_desc = {
    .bmRequestType = 0x81u, .bRequest = 0x06u,       /* GET_DESCRIPTOR, interface */
    .wValue = 0x2200u, .wIndex = 0u, .wLength = sizeof(desc) };
apb_usb_host_control(&usb, &get_report_desc, desc, sizeof(desc), &len, &result, 1000000u);
```

---

## Conventions

- **Device handle.** Every driver call takes the `apb_usb_host_t` filled by
  `apb_usb_host_init()`, which reads `INFO` (version 1) and records whether the build has
  full speed, control transfers and the diagnostic counters; the library keeps no global
  state, so several ports can coexist. A decoder (`apb_usb_host_hid_t`) belongs to one port.
- **Status codes.** Calls that can fail return `apb_usb_host_status_t`: `APB_USB_HOST_OK`,
  `APB_USB_HOST_E_PARAM` for an argument out of range, `APB_USB_HOST_E_ABSENT` when
  `INFO` does not hold version 1 or the build lacks the feature (control transfers with
  `CTRL_EN = 0`), `APB_USB_HOST_E_TIMEOUT` when a bounded wait ran out,
  `APB_USB_HOST_E_STATE` when the port is not in `RUN`, `APB_USB_HOST_E_XFER` for a
  control transfer whose `XFER.RESULT` is not OK. The `APB_USB_HOST_ERR_*` names of the
  register header are the `STATUS.ERR` codes, a different thing; `apb_usb_host_err_name()`,
  `apb_usb_host_state_name()` and `apb_usb_host_result_name()` give them names.
- **Enable.** `apb_usb_host_enable()` sets `CTRL.EN` with the options and keeps
  `POLL_MS`; a port already enabled keeps its device. The IP leaves reset with `CTRL.EN = 0`.
- **Device information.** `apb_usb_host_device()` reads `DEV_ID`, `DEV_IF` and `DEV_EP`,
  then `STATUS`: `APB_USB_HOST_OK` only when the port is in `RUN` after the reads, so the
  values belong to the device in `RUN` (doc *Register map*).
- **Reports.** `apb_usb_host_report_read()` reads `REPORT_INFO`, the report words and
  `REPORT_INFO` again, and repeats when it moved (doc *Report buffer*);
  `apb_usb_host_report_fetch()` also compares `SEQ` with the caller's last one, so each
  report is taken once. `SEQ` restarts with the port's next `RUN`; a fetch that finds no
  report resets the caller's `SEQ`, so the first report of the next device is new.
- **Interrupts.** `IRQ_PEND` latches whatever `IRQ_EN` holds and `irq_o` is a level:
  every enabled cause must be cleared by its handler. `apb_usb_host_hid_service()` clears
  `REPORT`, `READY`, `DETACH`, `FAIL` and `STATE` (`APB_USB_HOST_HID_IRQ_MASK`) and
  returns what it found; it leaves `XFER_PKT` and `XFER_DONE` alone.
- **Control transfers.** `apb_usb_host_control()` runs a whole transfer: it clears
  `IRQ_PEND.XFER_PKT` and `XFER_DONE`, starts the transfer, moves each data-stage packet
  when `XFER.PKT` rises (IN: into the caller's buffer, packets beyond its size
  acknowledged and dropped; OUT: `min(bMaxPacketSize0, remaining)` bytes), and returns at
  `IRQ_PEND.XFER_DONE` with `XFER.RESULT`. A transfer refused at the start
  (`RESULT = REFUSED`, no `XFER_BUSY`) ends the same way. Its bound counts status reads
  without progress; past it the transfer is aborted. The primitives
  (`apb_usb_host_xfer_start`, `_pkt`, `_read`, `_write`, `_next`, `_done`, `_result`,
  `_abort`) build the same thing around an interrupt instead.
- **HID decoder.** The device kind comes from `DEV_IF` (boot subclass, protocol 1
  keyboard, 2 mouse), then from `DEV_ID` in the gamepad tables (an application table
  given with `apb_usb_host_hid_set_pads()`, then the built-in one); any other HID device
  is `UNKNOWN` and decoded with the generic gamepad layout. Keyboard press and release
  events go to a 16-entry ring (overflow counted in `key_lost`) and carry the
  modifiers of their report; a modifier alone changes the state, not the queue.
  Reports with an error code in a key slot (rollover), short reports and gamepad reports
  that fail their layout's check change nothing (`ignored`). Mouse movement is summed;
  `apb_usb_host_hid_mouse_take()` returns the movement since the last take. A
  gamepad's state is its latest report. The getters need no lock against the service
  in an interrupt (header comment *Contexts*).
- **Gamepad layouts.** A layout names the bytes of the directions (two X/Y pairs: below
  `0x40` left / up, `0xC0` and above right / down; or a hat in a low nibble), the bit of
  each of A, B, X, Y, Select, Start, L and R, a minimum length, and two checks on one
  byte each: one a report must pass, one that marks a report to ignore. The built-in table
  holds the DragonRise-style SNES pad `0079:0011`, whose reports must have the low
  nibble of byte 5 at `F`. The generic layout is the DragonRise-style one most cheap pads
  use: X / Y in bytes 0 / 1 and 3 / 4, X A B Y in byte 5 bits 4–7, L R Select Start in
  byte 6 bits 0, 1, 4, 5; a report with bits 1:0 of byte 0 at `10` is ignored.
- **Privilege.** With the default `MDELEG_RST` only Machine mode may access the window
  after reset (`APB_USB_HOST_MDELEG_RESET`). `MDELEG` (`apb_usb_host_set_access`,
  `apb_usb_host_get_access`) is Machine mode only whatever the gates say. The library does
  not read the privilege mode: calling a function from a mode the gates refuse is the
  caller's error.

---

## API summary

| Area | Functions |
|---|---|
| Set-up | `apb_usb_host_init`, `apb_usb_host_enable`, `apb_usb_host_disable`, `apb_usb_host_enabled`, `apb_usb_host_set_poll_ms`, `apb_usb_host_restart` |
| State | `apb_usb_host_status`, `apb_usb_host_state`, `apb_usb_host_running`, `apb_usb_host_err`, `apb_usb_host_attempt`, `apb_usb_host_step`, `apb_usb_host_line`, `apb_usb_host_fs_dev`, `apb_usb_host_state_name`, `apb_usb_host_err_name`, `apb_usb_host_result_name` |
| Device, reports | `apb_usb_host_device`, `apb_usb_host_report_read`, `apb_usb_host_report_fetch` |
| Interrupts | `apb_usb_host_irq_enable`, `apb_usb_host_irq_disable`, `apb_usb_host_irq_pending`, `apb_usb_host_irq_clear` |
| Control transfers | `apb_usb_host_control`, `apb_usb_host_xfer_start`, `apb_usb_host_xfer_busy`, `apb_usb_host_xfer_pkt`, `apb_usb_host_xfer_read`, `apb_usb_host_xfer_write`, `apb_usb_host_xfer_next`, `apb_usb_host_xfer_done`, `apb_usb_host_xfer_result`, `apb_usb_host_xfer_abort` |
| Privilege gates | `apb_usb_host_set_access`, `apb_usb_host_get_access` |
| HID | `apb_usb_host_hid_init`, `apb_usb_host_hid_set_pads`, `apb_usb_host_hid_service`, `apb_usb_host_hid_kind`, `apb_usb_host_hid_kind_name`, `apb_usb_host_hid_pad_name`, `apb_usb_host_hid_device`, `apb_usb_host_hid_key_pop`, `apb_usb_host_hid_kbd_state`, `apb_usb_host_hid_key_held`, `apb_usb_host_hid_key_ascii`, `apb_usb_host_hid_mouse_take`, `apb_usb_host_hid_mouse_buttons`, `apb_usb_host_hid_pad`, `apb_usb_host_hid_pad_buttons` |
| HID decoder alone | `apb_usb_host_hid_identify`, `apb_usb_host_hid_decode`, `apb_usb_host_hid_forget` |

---

## Verification

The `_Static_assert`s of `apb_usb_host_regs.h` check the register offsets at compile
time, and the library builds warning-free with `-Wall -Wextra -Werror -Wpedantic` for
`rv32ec_zicsr`/`ilp32e` and `rv32imac_zicsr`/`ilp32`. `hid/test` runs the decoder and the
driver's report path on the host (`make -C sw/hid/test`, with the address and
undefined-behaviour sanitizers): the SNES pad's captured reports (idle, every button,
every direction) against a reference decode of the DragonRise layout, byte-shifted
reports, keyboard press / release / rollover / overflow, mouse accumulation,
random reports of every length to every kind, and the driver on a register window in
memory: the service entry (identification at `READY`, a port found already in `RUN`,
detach, failure), the setup and `XDATA` byte lanes of the control-transfer primitives
and a refused transfer. The packet loop of `apb_usb_host_control()` needs the IP: the
window in memory has no packet flow.
