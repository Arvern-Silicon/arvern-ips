/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_usb_host_hid.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * HID report decoder for apb_usb_host: boot keyboard and boot mouse (HID 1.11
 * Appendix B), gamepads by a layout table keyed by idVendor / idProduct.
 *
 *   apb_usb_host_hid_init              bind a decoder to a port (or to none)
 *   apb_usb_host_hid_service           the port's event entry: interrupt
 *                                      handler or polling loop
 *   apb_usb_host_hid_kind / _pad_name  what is attached
 *   apb_usb_host_hid_key_pop           keyboard: next press / release event
 *   apb_usb_host_hid_kbd_state         keyboard: modifiers and keys held
 *   apb_usb_host_hid_key_ascii         US-layout character of a key
 *   apb_usb_host_hid_mouse_take        mouse: movement since the last take
 *   apb_usb_host_hid_mouse_buttons     mouse: buttons held
 *   apb_usb_host_hid_pad / _pad_buttons  gamepad: the latest report
 *   apb_usb_host_hid_set_pads          an application table of gamepad layouts
 *   apb_usb_host_hid_identify / _decode / _forget   the decoder alone
 *
 * Device kind. From DEV_IF: a boot-subclass interface (subclass 1) with
 * protocol 1 is a keyboard, protocol 2 a mouse; their reports are decoded
 * with the boot layout (exact once DEV_IF.BOOT is set; a device that refused
 * SET_PROTOCOL runs report protocol, which most keyboards lay out the same
 * way). Otherwise DEV_ID is looked up in the application table, then in the
 * built-in one: a match is a GAMEPAD with that layout. Anything else is
 * UNKNOWN and decoded as a gamepad with the generic layout below, so a pad
 * missing from the tables still gives directions and buttons.
 *
 * Generic layout (the DragonRise-style reports of most cheap USB pads, 7 or
 * more bytes): byte 0 X and byte 1 Y (below 0x40 left / up, 0xC0 and above
 * right / down), bytes 3 and 4 a second X / Y with the same thresholds,
 * byte 5 bits 4-7 X A B Y, byte 6 bits 0-1 L R and bits 4-5 Select Start.
 * A report whose byte 0 has bits 1:0 = 10 is ignored (the second record of
 * the DualShock 2 adapters).
 *
 * Reports. Every report the port delivers goes through the decoder once (the
 * SEQ of the last one is kept): keyboard presses and releases are queued
 * (a ring of APB_USB_HOST_HID_KEYQ events; an event that finds it full is
 * dropped and counted), mouse movement is accumulated, a gamepad's state is
 * its latest report. Keyboard reports carrying an error code (0x01
 * ErrorRollOver, 0x02 POSTFail, 0x03 ErrorUndefined) in a key slot, short
 * reports and gamepad reports that fail their layout's check change nothing
 * and are counted in 'ignored'.
 *
 * Contexts. apb_usb_host_hid_service runs in one context: the port's
 * interrupt handler, or a polling loop when the port's interrupt is not
 * used. The getters run in another (the application) and need no lock: the
 * event ring has one writer per index, the mouse movement is kept as running
 * sums the taker differences, the gamepad state is one word, and the
 * keyboard state is read under a generation count.
 *
 * Device change. A port that leaves RUN, or a READY (a new enumeration), ends
 * the device: keys still held are released (events queued), buttons clear,
 * and the kind returns to NONE until the port is in RUN again. A device
 * found already in RUN (a port left running by a previous program) takes
 * its current report as the starting state, without events.
 *----------------------------------------------------------------------------*/
#ifndef APB_USB_HOST_HID_H
#define APB_USB_HOST_HID_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "apb_usb_host.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    APB_USB_HOST_HID_NONE     = 0,  /* no device in RUN                              */
    APB_USB_HOST_HID_KEYBOARD = 1,  /* boot keyboard                                  */
    APB_USB_HOST_HID_MOUSE    = 2,  /* boot mouse                                     */
    APB_USB_HOST_HID_GAMEPAD  = 3,  /* a gamepad of the tables                        */
    APB_USB_HOST_HID_UNKNOWN  = 4   /* any other HID device: generic gamepad layout   */
} apb_usb_host_hid_kind_t;

/* IRQ_PEND causes apb_usb_host_hid_service consumes (clears): enable these */
#define APB_USB_HOST_HID_IRQ_MASK   (APB_USB_HOST_IRQ_REPORT | APB_USB_HOST_IRQ_READY | \
                                     APB_USB_HOST_IRQ_DETACH | APB_USB_HOST_IRQ_FAIL  | \
                                     APB_USB_HOST_IRQ_STATE)

/* Gamepad buttons */
#define APB_USB_HOST_HID_PAD_LEFT    (1u << 0)
#define APB_USB_HOST_HID_PAD_RIGHT   (1u << 1)
#define APB_USB_HOST_HID_PAD_UP      (1u << 2)
#define APB_USB_HOST_HID_PAD_DOWN    (1u << 3)
#define APB_USB_HOST_HID_PAD_A       (1u << 4)
#define APB_USB_HOST_HID_PAD_B       (1u << 5)
#define APB_USB_HOST_HID_PAD_X       (1u << 6)
#define APB_USB_HOST_HID_PAD_Y       (1u << 7)
#define APB_USB_HOST_HID_PAD_SELECT  (1u << 8)
#define APB_USB_HOST_HID_PAD_START   (1u << 9)
#define APB_USB_HOST_HID_PAD_L       (1u << 10)
#define APB_USB_HOST_HID_PAD_R       (1u << 11)

/* Keyboard modifiers (report byte 0) */
#define APB_USB_HOST_HID_MOD_LCTRL   (1u << 0)
#define APB_USB_HOST_HID_MOD_LSHIFT  (1u << 1)
#define APB_USB_HOST_HID_MOD_LALT    (1u << 2)
#define APB_USB_HOST_HID_MOD_LGUI    (1u << 3)
#define APB_USB_HOST_HID_MOD_RCTRL   (1u << 4)
#define APB_USB_HOST_HID_MOD_RSHIFT  (1u << 5)
#define APB_USB_HOST_HID_MOD_RALT    (1u << 6)
#define APB_USB_HOST_HID_MOD_RGUI    (1u << 7)
#define APB_USB_HOST_HID_MOD_SHIFT   (APB_USB_HOST_HID_MOD_LSHIFT | APB_USB_HOST_HID_MOD_RSHIFT)

/* Mouse buttons (report byte 0) */
#define APB_USB_HOST_HID_MOUSE_LEFT   (1u << 0)
#define APB_USB_HOST_HID_MOUSE_RIGHT  (1u << 1)
#define APB_USB_HOST_HID_MOUSE_MIDDLE (1u << 2)

#define APB_USB_HOST_HID_KEYQ        16u        /* key event ring, a power of two */
#define APB_USB_HOST_HID_KEYS        6u         /* key slots of a boot report     */

typedef struct {                    /* a keyboard event */
    uint8_t key;                    /* usage ID (HID Usage Tables, Keyboard page): 0x04 'a' ... */
    uint8_t mods;                   /* the modifiers of the report that made it   */
    bool    down;                   /* press (true) or release                    */
} apb_usb_host_hid_key_t;

typedef struct {                    /* a gamepad's latest report */
    uint16_t buttons;               /* APB_USB_HOST_HID_PAD_*                     */
    int8_t   x, y;                  /* first axes, centred: report byte - 128 (0 without axes) */
} apb_usb_host_hid_pad_t;

/* Gamepad layout. A bit field is a byte index and a mask (byte 0xFF: none);
 * a check passes when (report[byte] & mask) == value (mask 0: no check). */
typedef struct { uint8_t byte, mask; }        apb_usb_host_hid_bit_t;
typedef struct { uint8_t byte, mask, value; } apb_usb_host_hid_check_t;

#define APB_USB_HOST_HID_NO_BYTE     0xFFu

typedef struct {
    uint16_t vid, pid;              /* idVendor, idProduct                                */
    const char *name;
    uint8_t  min_len;               /* shorter reports are ignored                        */
    uint8_t  x, y;                  /* axis bytes: < 0x40 left / up, >= 0xC0 right / down  */
    uint8_t  x2, y2;                /* second axes, same thresholds, ORed in               */
    uint8_t  hat;                   /* byte whose low nibble is a hat: 0 up, clockwise to 7; others centred */
    apb_usb_host_hid_check_t need;  /* a report must pass it                               */
    apb_usb_host_hid_check_t skip;  /* a report that passes it is ignored                  */
    apb_usb_host_hid_bit_t   a, b, x_btn, y_btn, select, start, l, r;
} apb_usb_host_hid_pad_layout_t;

typedef struct {                    /* decoder state; fields are private */
    apb_usb_host_t *host;
    const apb_usb_host_hid_pad_layout_t *app_pads;
    size_t   app_pads_nr;
    const apb_usb_host_hid_pad_layout_t *pad;
    apb_usb_host_device_t dev;
    uint8_t  last_seq;
    volatile uint8_t  kind;
    /* keyboard */
    volatile uint32_t kbd_gen;
    volatile uint8_t  kbd_mods;
    volatile uint8_t  kbd_keys[APB_USB_HOST_HID_KEYS];
    volatile uint8_t  ev_key[APB_USB_HOST_HID_KEYQ];
    volatile uint8_t  ev_mods[APB_USB_HOST_HID_KEYQ];
    volatile uint8_t  ev_down[APB_USB_HOST_HID_KEYQ];
    volatile uint32_t ev_head, ev_tail;
    /* mouse */
    volatile uint8_t  mouse_btn;
    volatile uint32_t mouse_sx, mouse_sy, mouse_sw;
    uint32_t mouse_tx, mouse_ty, mouse_tw;
    /* gamepad: buttons [15:0], x [23:16], y [31:24] */
    volatile uint32_t pad_word;
    /* counts */
    volatile uint32_t reports;      /* reports decoded                         */
    volatile uint32_t ignored;      /* reports that changed nothing (see above) */
    volatile uint32_t key_lost;     /* key events dropped on a full ring        */
} apb_usb_host_hid_t;

/*---------------------------------------------------------------------------
 * Set-up and the event entry
 *---------------------------------------------------------------------------*/

/* host: the bound port, or NULL for the decoder alone (identify / decode) */
void apb_usb_host_hid_init(apb_usb_host_hid_t *hid, apb_usb_host_t *host);

/* Layouts searched before the built-in table (kept by reference) */
void apb_usb_host_hid_set_pads(apb_usb_host_hid_t *hid, const apb_usb_host_hid_pad_layout_t *pads, size_t nr);

/* Clear the APB_USB_HOST_HID_IRQ_MASK causes, follow the device (identify
 * it in RUN, end it outside), decode a new report. Returns the IRQ_PEND
 * value it found, for the caller's own use of READY, DETACH, FAIL, ... */
uint32_t apb_usb_host_hid_service(apb_usb_host_hid_t *hid);

/*---------------------------------------------------------------------------
 * Getters (application context)
 *---------------------------------------------------------------------------*/
static inline apb_usb_host_hid_kind_t apb_usb_host_hid_kind(const apb_usb_host_hid_t *hid)
{ return (apb_usb_host_hid_kind_t) hid->kind; }
const char *apb_usb_host_hid_kind_name(apb_usb_host_hid_kind_t kind);
/* The gamepad layout in use ("generic" for UNKNOWN), NULL for another kind */
const char *apb_usb_host_hid_pad_name(const apb_usb_host_hid_t *hid);
/* The identified device (valid while the kind is not NONE) */
static inline const apb_usb_host_device_t *apb_usb_host_hid_device(const apb_usb_host_hid_t *hid)
{ return &hid->dev; }

bool apb_usb_host_hid_key_pop(apb_usb_host_hid_t *hid, apb_usb_host_hid_key_t *ev);
void apb_usb_host_hid_kbd_state(const apb_usb_host_hid_t *hid, uint8_t *mods, uint8_t keys[APB_USB_HOST_HID_KEYS]);
bool apb_usb_host_hid_key_held(const apb_usb_host_hid_t *hid, uint8_t key);
/* US layout: letters, digits, punctuation, Space, Enter '\n', Tab, Backspace
 * '\b', Escape 0x1B; 0 for the others */
char apb_usb_host_hid_key_ascii(uint8_t key, uint8_t mods);

/* Movement since the previous take, all three taken (a NULL pointer discards its axis) */
void apb_usb_host_hid_mouse_take(apb_usb_host_hid_t *hid, int32_t *dx, int32_t *dy, int32_t *dwheel);
static inline uint32_t apb_usb_host_hid_mouse_buttons(const apb_usb_host_hid_t *hid) { return hid->mouse_btn; }

static inline uint32_t apb_usb_host_hid_pad_buttons(const apb_usb_host_hid_t *hid)
{ return hid->pad_word & 0xFFFFu; }
static inline void apb_usb_host_hid_pad(const apb_usb_host_hid_t *hid, apb_usb_host_hid_pad_t *pad)
{
    uint32_t w   = hid->pad_word;
    pad->buttons = (uint16_t) (w & 0xFFFFu);
    pad->x       = (int8_t) (uint8_t) (w >> 16);
    pad->y       = (int8_t) (uint8_t) (w >> 24);
}

/*---------------------------------------------------------------------------
 * The decoder alone (what apb_usb_host_hid_service runs)
 *---------------------------------------------------------------------------*/
/* Take a device: kind and layout from its descriptors; state cleared */
void apb_usb_host_hid_identify(apb_usb_host_hid_t *hid, const apb_usb_host_device_t *dev);
/* Decode one report of the identified device */
void apb_usb_host_hid_decode(apb_usb_host_hid_t *hid, const uint8_t *report, size_t len);
/* End the device: held keys released (events), buttons cleared, kind NONE */
void apb_usb_host_hid_forget(apb_usb_host_hid_t *hid);

/* The built-in gamepad table and the generic layout */
extern const apb_usb_host_hid_pad_layout_t apb_usb_host_hid_pads[];
extern const size_t                         apb_usb_host_hid_pads_nr;
extern const apb_usb_host_hid_pad_layout_t apb_usb_host_hid_pad_generic;

#ifdef __cplusplus
}
#endif

#endif /* APB_USB_HOST_HID_H */
