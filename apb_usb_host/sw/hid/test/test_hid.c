/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      test_hid.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Host unit tests of the HID decoder (apb_usb_host_hid.c) and of the
 * driver's report path, on a register window in host memory. Build and run:
 * make -C sw/hid/test
 *----------------------------------------------------------------------------*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "apb_usb_host_hid.h"

static unsigned fails, checks;

#define CHECK(c) do { checks++; if (!(c)) { fails++; \
    printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

#define R8(a, b, c, d, e, f, g, h)  ((const uint8_t[8]) { a, b, c, d, e, f, g, h })

/* Devices */
static const apb_usb_host_device_t dev_kbd   = { .vid = 0x1209u, .pid = 0x0001u, .subclass = 1u, .protocol = 1u, .boot = true };
static const apb_usb_host_device_t dev_mouse = { .vid = 0x1209u, .pid = 0x0002u, .subclass = 1u, .protocol = 2u, .boot = true };
static const apb_usb_host_device_t dev_pad   = { .vid = 0x0079u, .pid = 0x0011u };
static const apb_usb_host_device_t dev_other = { .vid = 0x0F0Du, .pid = 0x00C1u };

/*---------------------------------------------------------------------------
 * Reference decode of the DragonRise-style layout (exact 0x00 / 0xFF on
 * bytes 0 / 1, bits 7:6 of bytes 3 / 4, no L / R): the SNES pad's reports
 * must give the same buttons here.
 *---------------------------------------------------------------------------*/
static uint32_t ref_decode(const uint8_t *d)
{
    uint32_t b = 0u;
    int valid = (d[0] & 3u) != 2u;
    if (d[0] == 0x00u) b |= APB_USB_HOST_HID_PAD_LEFT;
    if (d[0] == 0xFFu) b |= APB_USB_HOST_HID_PAD_RIGHT;
    if (d[1] == 0x00u) b |= APB_USB_HOST_HID_PAD_UP;
    if (d[1] == 0xFFu) b |= APB_USB_HOST_HID_PAD_DOWN;
    if (valid) {
        if ((d[3] >> 6) == 0u) b |= APB_USB_HOST_HID_PAD_LEFT;
        if ((d[3] >> 6) == 3u) b |= APB_USB_HOST_HID_PAD_RIGHT;
        if ((d[4] >> 6) == 0u) b |= APB_USB_HOST_HID_PAD_UP;
        if ((d[4] >> 6) == 3u) b |= APB_USB_HOST_HID_PAD_DOWN;
        if (d[5] & 0x10u) b |= APB_USB_HOST_HID_PAD_X;
        if (d[5] & 0x20u) b |= APB_USB_HOST_HID_PAD_A;
        if (d[5] & 0x40u) b |= APB_USB_HOST_HID_PAD_B;
        if (d[5] & 0x80u) b |= APB_USB_HOST_HID_PAD_Y;
        if (d[6] & 0x10u) b |= APB_USB_HOST_HID_PAD_SELECT;
        if (d[6] & 0x20u) b |= APB_USB_HOST_HID_PAD_START;
    }
    return b;
}

/* The SNES pad's reports as captured (report words 0 and 1) */
static const uint32_t capture[][2] = {
    { 0x80007F7Fu, 0x00000F80u }, { 0x800000FFu, 0x00000F80u }, { 0x80007FFFu, 0x00000F80u },
    { 0x80007F7Fu, 0x00002F80u }, { 0x80007F7Fu, 0x00004F80u }, { 0x80007F7Fu, 0x00001F80u },
    { 0x80007F7Fu, 0x00008F80u }, { 0x80007F7Fu, 0x00010F80u }, { 0x80007F7Fu, 0x00020F80u },
    { 0x80007F7Fu, 0x00100F80u }, { 0x80007F7Fu, 0x00200F80u }, { 0x8000007Fu, 0x00000F80u },
    { 0x8000FF7Fu, 0x00000F80u }, { 0x8000FFFFu, 0x00000F80u }, { 0x80007F00u, 0x00000F80u },
    { 0x80000000u, 0x00000F80u },
};
/* Byte-shifted reports (the pad's report misaligned by one byte) */
static const uint32_t corrupt[][2] = {
    { 0x00FFFFFFu, 0x000F8080u },      /* FF FF FF 00 80 80 0F 00 */
    { 0x007FFFFFu, 0x000F8080u },      /* FF FF 7F 00 80 80 0F 00 */
};

static void unpack(const uint32_t w[2], uint8_t r[8])
{
    for (unsigned i = 0u; i < 4u; i++) {
        r[i]      = (uint8_t) (w[0] >> (8u * i));
        r[i + 4u] = (uint8_t) (w[1] >> (8u * i));
    }
}

static uint32_t pad_of(apb_usb_host_hid_t *h, const uint8_t *r, size_t len)
{
    apb_usb_host_hid_decode(h, r, len);
    return apb_usb_host_hid_pad_buttons(h);
}

static void test_identify(void)
{
    apb_usb_host_hid_t h;
    apb_usb_host_hid_init(&h, NULL);
    CHECK(apb_usb_host_hid_kind(&h) == APB_USB_HOST_HID_NONE);
    apb_usb_host_hid_identify(&h, &dev_kbd);
    CHECK(apb_usb_host_hid_kind(&h) == APB_USB_HOST_HID_KEYBOARD);
    CHECK(apb_usb_host_hid_pad_name(&h) == NULL);
    apb_usb_host_hid_identify(&h, &dev_mouse);
    CHECK(apb_usb_host_hid_kind(&h) == APB_USB_HOST_HID_MOUSE);
    apb_usb_host_hid_identify(&h, &dev_pad);
    CHECK(apb_usb_host_hid_kind(&h) == APB_USB_HOST_HID_GAMEPAD);
    CHECK(strcmp(apb_usb_host_hid_pad_name(&h), "SNES pad 0079:0011") == 0);
    apb_usb_host_hid_identify(&h, &dev_other);
    CHECK(apb_usb_host_hid_kind(&h) == APB_USB_HOST_HID_UNKNOWN);
    CHECK(strcmp(apb_usb_host_hid_pad_name(&h), "generic") == 0);
    /* boot subclass, protocol 0: not a keyboard or a mouse */
    const apb_usb_host_device_t odd = { .subclass = 1u, .protocol = 0u };
    apb_usb_host_hid_identify(&h, &odd);
    CHECK(apb_usb_host_hid_kind(&h) == APB_USB_HOST_HID_UNKNOWN);
    /* an application layout wins over the built-in table */
    static const apb_usb_host_hid_pad_layout_t mine[] = { {
        .vid = 0x0079u, .pid = 0x0011u, .name = "mine", .min_len = 1u,
        .x = APB_USB_HOST_HID_NO_BYTE, .y = APB_USB_HOST_HID_NO_BYTE,
        .x2 = APB_USB_HOST_HID_NO_BYTE, .y2 = APB_USB_HOST_HID_NO_BYTE, .hat = 0u,
        .need = { APB_USB_HOST_HID_NO_BYTE, 0u, 0u }, .skip = { APB_USB_HOST_HID_NO_BYTE, 0u, 0u },
        .a = { 1u, 0x01u }, .b = { APB_USB_HOST_HID_NO_BYTE, 0u }, .x_btn = { APB_USB_HOST_HID_NO_BYTE, 0u },
        .y_btn = { APB_USB_HOST_HID_NO_BYTE, 0u }, .select = { APB_USB_HOST_HID_NO_BYTE, 0u },
        .start = { APB_USB_HOST_HID_NO_BYTE, 0u }, .l = { APB_USB_HOST_HID_NO_BYTE, 0u },
        .r = { APB_USB_HOST_HID_NO_BYTE, 0u } } };
    apb_usb_host_hid_set_pads(&h, mine, 1u);
    apb_usb_host_hid_identify(&h, &dev_pad);
    CHECK(strcmp(apb_usb_host_hid_pad_name(&h), "mine") == 0);
    /* hat: 2 is right, 6 left, 8 centred */
    CHECK(pad_of(&h, (const uint8_t[]) { 0x02u, 0x01u }, 2u) == (APB_USB_HOST_HID_PAD_RIGHT | APB_USB_HOST_HID_PAD_A));
    CHECK(pad_of(&h, (const uint8_t[]) { 0x07u, 0x00u }, 2u) == (APB_USB_HOST_HID_PAD_UP | APB_USB_HOST_HID_PAD_LEFT));
    CHECK(pad_of(&h, (const uint8_t[]) { 0x08u, 0x00u }, 2u) == 0u);
    CHECK(pad_of(&h, (const uint8_t[]) { 0x0Fu, 0x00u }, 2u) == 0u);
}

static void test_user_pad(void)
{
    apb_usb_host_hid_t h;
    apb_usb_host_hid_pad_t st;
    uint8_t r[8];

    apb_usb_host_hid_init(&h, NULL);
    apb_usb_host_hid_identify(&h, &dev_pad);

    CHECK(pad_of(&h, R8(0x7F, 0x7F, 0x00, 0x80, 0x80, 0x0F, 0x00, 0x00), 8u) == 0u);
    apb_usb_host_hid_pad(&h, &st);
    CHECK(st.buttons == 0u && st.x == -1 && st.y == -1);
    CHECK(pad_of(&h, R8(0xFF, 0x7F, 0x00, 0x80, 0x80, 0x0F, 0x00, 0x00), 8u) == APB_USB_HOST_HID_PAD_RIGHT);
    CHECK(pad_of(&h, R8(0x00, 0x7F, 0x00, 0x80, 0x80, 0x0F, 0x00, 0x00), 8u) == APB_USB_HOST_HID_PAD_LEFT);
    apb_usb_host_hid_pad(&h, &st);
    CHECK(st.x == -128 && st.y == -1);
    CHECK(pad_of(&h, R8(0x7F, 0x00, 0x00, 0x80, 0x80, 0x0F, 0x00, 0x00), 8u) == APB_USB_HOST_HID_PAD_UP);
    CHECK(pad_of(&h, R8(0x7F, 0xFF, 0x00, 0x80, 0x80, 0x0F, 0x00, 0x00), 8u) == APB_USB_HOST_HID_PAD_DOWN);
    apb_usb_host_hid_pad(&h, &st);
    CHECK(st.y == 127);
    CHECK(pad_of(&h, R8(0x7F, 0x7F, 0x00, 0x80, 0x80, 0x1F, 0x00, 0x00), 8u) == APB_USB_HOST_HID_PAD_X);
    CHECK(pad_of(&h, R8(0x7F, 0x7F, 0x00, 0x80, 0x80, 0x2F, 0x00, 0x00), 8u) == APB_USB_HOST_HID_PAD_A);
    CHECK(pad_of(&h, R8(0x7F, 0x7F, 0x00, 0x80, 0x80, 0x4F, 0x00, 0x00), 8u) == APB_USB_HOST_HID_PAD_B);
    CHECK(pad_of(&h, R8(0x7F, 0x7F, 0x00, 0x80, 0x80, 0x8F, 0x00, 0x00), 8u) == APB_USB_HOST_HID_PAD_Y);
    CHECK(pad_of(&h, R8(0x7F, 0x7F, 0x00, 0x80, 0x80, 0x0F, 0x01, 0x00), 8u) == APB_USB_HOST_HID_PAD_L);
    CHECK(pad_of(&h, R8(0x7F, 0x7F, 0x00, 0x80, 0x80, 0x0F, 0x02, 0x00), 8u) == APB_USB_HOST_HID_PAD_R);
    CHECK(pad_of(&h, R8(0x7F, 0x7F, 0x00, 0x80, 0x80, 0x0F, 0x10, 0x00), 8u) == APB_USB_HOST_HID_PAD_SELECT);
    CHECK(pad_of(&h, R8(0x7F, 0x7F, 0x00, 0x80, 0x80, 0x0F, 0x20, 0x00), 8u) == APB_USB_HOST_HID_PAD_START);
    /* the tst_usb_hid vector: right + A */
    CHECK(pad_of(&h, R8(0xFF, 0x7F, 0x00, 0x80, 0x80, 0x2F, 0x00, 0x00), 8u) ==
          (APB_USB_HOST_HID_PAD_RIGHT | APB_USB_HOST_HID_PAD_A));
    CHECK(pad_of(&h, R8(0xFF, 0x00, 0x00, 0x80, 0x80, 0xFF, 0x33, 0x00), 8u) ==
          (APB_USB_HOST_HID_PAD_RIGHT | APB_USB_HOST_HID_PAD_UP | APB_USB_HOST_HID_PAD_X | APB_USB_HOST_HID_PAD_A |
           APB_USB_HOST_HID_PAD_B | APB_USB_HOST_HID_PAD_Y | APB_USB_HOST_HID_PAD_L | APB_USB_HOST_HID_PAD_R |
           APB_USB_HOST_HID_PAD_SELECT | APB_USB_HOST_HID_PAD_START));

    /* every captured report: the reference buttons (it has no L / R) */
    for (size_t i = 0u; i < sizeof(capture) / sizeof(capture[0]); i++) {
        unpack(capture[i], r);
        uint32_t b = pad_of(&h, r, 8u) & ~(APB_USB_HOST_HID_PAD_L | APB_USB_HOST_HID_PAD_R);
        CHECK(b == ref_decode(r));
    }

    /* shifted reports: ignored, the state stays the last good one */
    CHECK(pad_of(&h, R8(0xFF, 0x7F, 0x00, 0x80, 0x80, 0x2F, 0x00, 0x00), 8u) ==
          (APB_USB_HOST_HID_PAD_RIGHT | APB_USB_HOST_HID_PAD_A));
    uint32_t ign = h.ignored;
    for (size_t i = 0u; i < sizeof(corrupt) / sizeof(corrupt[0]); i++) {
        unpack(corrupt[i], r);
        CHECK(pad_of(&h, r, 8u) == (APB_USB_HOST_HID_PAD_RIGHT | APB_USB_HOST_HID_PAD_A));
    }
    CHECK(h.ignored == ign + 2u);

    /* short and empty reports */
    CHECK(pad_of(&h, r, 0u) == (APB_USB_HOST_HID_PAD_RIGHT | APB_USB_HOST_HID_PAD_A));
    CHECK(pad_of(&h, r, 3u) == (APB_USB_HOST_HID_PAD_RIGHT | APB_USB_HOST_HID_PAD_A));
    apb_usb_host_hid_decode(&h, NULL, 0u);

    apb_usb_host_hid_forget(&h);
    CHECK(apb_usb_host_hid_kind(&h) == APB_USB_HOST_HID_NONE && apb_usb_host_hid_pad_buttons(&h) == 0u);
    /* no device: reports are dropped */
    CHECK(pad_of(&h, R8(0xFF, 0x7F, 0x00, 0x80, 0x80, 0x2F, 0x00, 0x00), 8u) == 0u);
}

static void test_generic_pad(void)
{
    apb_usb_host_hid_t h;
    apb_usb_host_hid_init(&h, NULL);
    apb_usb_host_hid_identify(&h, &dev_other);
    /* the generic layout is the reference one, plus L / R */
    CHECK(pad_of(&h, R8(0xFF, 0x7F, 0x00, 0x80, 0x80, 0x2F, 0x00, 0x00), 8u) ==
          (APB_USB_HOST_HID_PAD_RIGHT | APB_USB_HOST_HID_PAD_A));
    CHECK(pad_of(&h, R8(0x7F, 0x7F, 0x00, 0x00, 0xFF, 0x0F, 0x03, 0x00), 8u) ==
          (APB_USB_HOST_HID_PAD_LEFT | APB_USB_HOST_HID_PAD_DOWN | APB_USB_HOST_HID_PAD_L | APB_USB_HOST_HID_PAD_R));
    /* a DualShock 2 adapter's second record (byte 0 bits 1:0 = 10): ignored */
    CHECK(pad_of(&h, R8(0x02, 0x7F, 0x00, 0x80, 0x80, 0xFF, 0x00, 0x00), 8u) ==
          (APB_USB_HOST_HID_PAD_LEFT | APB_USB_HOST_HID_PAD_DOWN | APB_USB_HOST_HID_PAD_L | APB_USB_HOST_HID_PAD_R));
    /* the generic layout against the reference on every captured report */
    uint8_t r[8];
    for (size_t i = 0u; i < sizeof(capture) / sizeof(capture[0]); i++) {
        unpack(capture[i], r);
        CHECK((pad_of(&h, r, 8u) & ~(APB_USB_HOST_HID_PAD_L | APB_USB_HOST_HID_PAD_R)) == ref_decode(r));
    }
    /* the shifted ones too: no check in the generic layout, same buttons as the reference */
    for (size_t i = 0u; i < sizeof(corrupt) / sizeof(corrupt[0]); i++) {
        unpack(corrupt[i], r);
        CHECK((pad_of(&h, r, 8u) & ~(APB_USB_HOST_HID_PAD_L | APB_USB_HOST_HID_PAD_R)) == ref_decode(r));
    }
    uint32_t b = pad_of(&h, r, 8u);
    CHECK(pad_of(&h, R8(0xFF, 0x7F, 0x00, 0x80, 0x80, 0x2F, 0x00, 0x00), 6u) == b);   /* shorter than 7: ignored */
}

static bool pop(apb_usb_host_hid_t *h, uint8_t key, uint8_t mods, bool down)
{
    apb_usb_host_hid_key_t ev;
    return apb_usb_host_hid_key_pop(h, &ev) && ev.key == key && ev.mods == mods && ev.down == down;
}

static void test_keyboard(void)
{
    apb_usb_host_hid_t     h;
    apb_usb_host_hid_key_t ev;
    uint8_t                mods, keys[6];

    apb_usb_host_hid_init(&h, NULL);
    apb_usb_host_hid_identify(&h, &dev_kbd);
    CHECK(!apb_usb_host_hid_key_pop(&h, &ev));

    /* the tst_usb_hid vector: left shift + 'a' -> one press */
    apb_usb_host_hid_decode(&h, R8(0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00), 8u);
    CHECK(apb_usb_host_hid_key_pop(&h, &ev));
    CHECK(ev.key == 0x04u && ev.mods == APB_USB_HOST_HID_MOD_LSHIFT && ev.down);
    CHECK(apb_usb_host_hid_key_ascii(ev.key, ev.mods) == 'A');
    CHECK(!apb_usb_host_hid_key_pop(&h, &ev));
    CHECK(apb_usb_host_hid_key_held(&h, 0x04u));
    apb_usb_host_hid_kbd_state(&h, &mods, keys);
    CHECK(mods == 0x02u && keys[0] == 0x04u && keys[1] == 0u);

    /* the same report again: nothing */
    apb_usb_host_hid_decode(&h, R8(0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00), 8u);
    CHECK(!apb_usb_host_hid_key_pop(&h, &ev));

    /* rollover: ignored, no event, keys kept */
    apb_usb_host_hid_decode(&h, R8(0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01), 8u);
    CHECK(!apb_usb_host_hid_key_pop(&h, &ev));
    CHECK(apb_usb_host_hid_key_held(&h, 0x04u));

    /* 'b' added, then 'a' released, then all released: releases before presses */
    apb_usb_host_hid_decode(&h, R8(0x00, 0x00, 0x04, 0x05, 0x00, 0x00, 0x00, 0x00), 8u);
    CHECK(pop(&h, 0x05u, 0x00u, true));
    apb_usb_host_hid_decode(&h, R8(0x00, 0x00, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00), 8u);
    CHECK(pop(&h, 0x04u, 0x00u, false));
    CHECK(pop(&h, 0x06u, 0x00u, true));
    apb_usb_host_hid_decode(&h, R8(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00), 8u);
    CHECK(pop(&h, 0x05u, 0x00u, false));
    CHECK(pop(&h, 0x06u, 0x00u, false));
    CHECK(!apb_usb_host_hid_key_pop(&h, &ev));
    CHECK(!apb_usb_host_hid_key_held(&h, 0x05u));

    /* a modifier alone changes the state, not the queue */
    apb_usb_host_hid_decode(&h, R8(0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00), 8u);
    CHECK(!apb_usb_host_hid_key_pop(&h, &ev));
    apb_usb_host_hid_kbd_state(&h, &mods, NULL);
    CHECK(mods == APB_USB_HOST_HID_MOD_RSHIFT);

    /* a duplicated key code counts once; a 3-byte report is enough */
    apb_usb_host_hid_decode(&h, R8(0x00, 0x00, 0x2C, 0x2C, 0x00, 0x00, 0x00, 0x00), 8u);
    CHECK(pop(&h, 0x2Cu, 0x00u, true));
    CHECK(!apb_usb_host_hid_key_pop(&h, &ev));
    apb_usb_host_hid_decode(&h, (const uint8_t[]) { 0x00u, 0x00u, 0x28u }, 3u);
    CHECK(pop(&h, 0x2Cu, 0x00u, false));
    CHECK(pop(&h, 0x28u, 0x00u, true));
    apb_usb_host_hid_decode(&h, (const uint8_t[]) { 0x00u, 0x00u }, 2u);   /* too short */
    CHECK(!apb_usb_host_hid_key_pop(&h, &ev));

    /* six keys, then the device goes: six releases */
    apb_usb_host_hid_decode(&h, R8(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00), 8u);
    CHECK(pop(&h, 0x28u, 0x00u, false));
    apb_usb_host_hid_decode(&h, R8(0x00, 0x00, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15), 8u);
    for (uint8_t k = 0x10u; k <= 0x15u; k++)
        CHECK(pop(&h, k, 0x00u, true));
    apb_usb_host_hid_forget(&h);
    for (uint8_t k = 0x10u; k <= 0x15u; k++)
        CHECK(pop(&h, k, 0x00u, false));
    CHECK(apb_usb_host_hid_kind(&h) == APB_USB_HOST_HID_NONE);

    /* ring overflow: events past APB_USB_HOST_HID_KEYQ are counted, not queued */
    apb_usb_host_hid_identify(&h, &dev_kbd);
    for (unsigned i = 0u; i < 10u; i++) {
        apb_usb_host_hid_decode(&h, R8(0x00, 0x00, (uint8_t) (0x04u + i), 0x00, 0x00, 0x00, 0x00, 0x00), 8u);
    }
    /* 1 press + 9 x (release + press) = 19 events, 16 queued */
    CHECK(h.key_lost == 3u);
    unsigned n = 0u;
    while (apb_usb_host_hid_key_pop(&h, &ev))
        n++;
    CHECK(n == APB_USB_HOST_HID_KEYQ);

    /* ASCII */
    CHECK(apb_usb_host_hid_key_ascii(0x04u, 0u) == 'a');
    CHECK(apb_usb_host_hid_key_ascii(0x1Du, APB_USB_HOST_HID_MOD_RSHIFT) == 'Z');
    CHECK(apb_usb_host_hid_key_ascii(0x1Eu, 0u) == '1');
    CHECK(apb_usb_host_hid_key_ascii(0x1Eu, APB_USB_HOST_HID_MOD_LSHIFT) == '!');
    CHECK(apb_usb_host_hid_key_ascii(0x27u, 0u) == '0');
    CHECK(apb_usb_host_hid_key_ascii(0x28u, 0u) == '\n');
    CHECK(apb_usb_host_hid_key_ascii(0x2Cu, 0u) == ' ');
    CHECK(apb_usb_host_hid_key_ascii(0x38u, 0u) == '/');
    CHECK(apb_usb_host_hid_key_ascii(0x38u, APB_USB_HOST_HID_MOD_LSHIFT) == '?');
    CHECK(apb_usb_host_hid_key_ascii(0x39u, 0u) == 0);
    CHECK(apb_usb_host_hid_key_ascii(0x00u, 0u) == 0);
}

static void test_mouse(void)
{
    apb_usb_host_hid_t h;
    int32_t dx, dy, dw;

    apb_usb_host_hid_init(&h, NULL);
    apb_usb_host_hid_identify(&h, &dev_mouse);
    apb_usb_host_hid_decode(&h, (const uint8_t[]) { 0x01u, 0x05u, 0xFDu }, 3u);
    apb_usb_host_hid_decode(&h, (const uint8_t[]) { 0x01u, 0xFEu, 0xFDu, 0x01u }, 4u);
    apb_usb_host_hid_decode(&h, (const uint8_t[]) { 0x01u, 0x64u, 0x32u, 0xFFu, 0x00u }, 5u);
    CHECK(apb_usb_host_hid_mouse_buttons(&h) == APB_USB_HOST_HID_MOUSE_LEFT);
    apb_usb_host_hid_mouse_take(&h, &dx, &dy, &dw);
    CHECK(dx == 103 && dy == 44 && dw == 0);
    apb_usb_host_hid_mouse_take(&h, &dx, &dy, &dw);
    CHECK(dx == 0 && dy == 0 && dw == 0);
    for (unsigned i = 0u; i < 300u; i++)
        apb_usb_host_hid_decode(&h, (const uint8_t[]) { 0x02u, 0x7Fu, 0x80u, 0x01u }, 4u);
    apb_usb_host_hid_mouse_take(&h, &dx, &dy, &dw);
    CHECK(dx == 300 * 127 && dy == 300 * -128 && dw == 300);
    apb_usb_host_hid_decode(&h, (const uint8_t[]) { 0x02u, 0x01u, 0x02u }, 3u);
    apb_usb_host_hid_mouse_take(&h, NULL, NULL, NULL);                       /* discards */
    apb_usb_host_hid_mouse_take(&h, &dx, &dy, &dw);
    CHECK(dx == 0 && dy == 0 && dw == 0);
    CHECK(apb_usb_host_hid_mouse_buttons(&h) == APB_USB_HOST_HID_MOUSE_RIGHT);
    apb_usb_host_hid_decode(&h, (const uint8_t[]) { 0x07u, 0x01u }, 2u);             /* too short */
    CHECK(apb_usb_host_hid_mouse_buttons(&h) == APB_USB_HOST_HID_MOUSE_RIGHT);
    apb_usb_host_hid_forget(&h);
    CHECK(apb_usb_host_hid_mouse_buttons(&h) == 0u);
}

/* Random reports of every length to every kind: no crash, no write out of bounds */
static void test_fuzz(void)
{
    apb_usb_host_hid_t h;
    const apb_usb_host_device_t *devs[] = { &dev_kbd, &dev_mouse, &dev_pad, &dev_other };
    uint8_t r[APB_USB_HOST_REPORT_MAX + 8u];
    srand(1u);
    apb_usb_host_hid_init(&h, NULL);
    for (unsigned d = 0u; d < 4u; d++) {
        apb_usb_host_hid_identify(&h, devs[d]);
        for (unsigned i = 0u; i < 20000u; i++) {
            size_t len = (size_t) rand() % (APB_USB_HOST_REPORT_MAX + 1u);
            for (size_t j = 0u; j < sizeof(r); j++)
                r[j] = (uint8_t) rand();
            apb_usb_host_hid_decode(&h, r, len);
            apb_usb_host_hid_key_t ev;
            if (rand() & 1)
                while (apb_usb_host_hid_key_pop(&h, &ev))
                    CHECK(ev.key > 0x03u);
        }
        CHECK(apb_usb_host_hid_pad_buttons(&h) < (1u << 12));
    }
}

/*---------------------------------------------------------------------------
 * The service entry on a register window in memory (IRQ_PEND is plain
 * memory here: the test clears it itself)
 *---------------------------------------------------------------------------*/
static APB_USB_HOST_TypeDef win;

static void set_ro(volatile const uint32_t *reg, uint32_t v) { *(volatile uint32_t *) reg = v; }

static void set_report(uint8_t seq, const uint8_t *r, unsigned len)
{
    set_ro(&win.REPORT[0], (uint32_t) r[0] | (uint32_t) r[1] << 8 | (uint32_t) r[2] << 16 | (uint32_t) r[3] << 24);
    set_ro(&win.REPORT[1], (uint32_t) r[4] | (uint32_t) r[5] << 8 | (uint32_t) r[6] << 16 | (uint32_t) r[7] << 24);
    set_ro(&win.REPORT_INFO, (uint32_t) len | ((uint32_t) seq << 8));
}

static uint32_t service(apb_usb_host_hid_t *h, uint32_t pend)
{
    win.IRQ_PEND = pend;
    uint32_t got = apb_usb_host_hid_service(h);
    win.IRQ_PEND = 0u;
    return got;
}

static void test_service(void)
{
    apb_usb_host_t         host;
    apb_usb_host_hid_t     h;
    apb_usb_host_hid_key_t ev;
    apb_usb_host_report_t  rpt;
    uint8_t                last = 0u;

    memset(&win, 0, sizeof(win));
    set_ro(&win.INFO, 0x10000000u);
    const apb_usb_host_config_t cfg = { (uintptr_t) &win };
    CHECK(apb_usb_host_init(&host, &cfg) == APB_USB_HOST_OK && !host.ctrl_en);
    win.CTRL = APB_USB_HOST_CTRL_RESET;
    apb_usb_host_enable(&host, APB_USB_HOST_OPT_DEFAULT);
    CHECK(win.CTRL == 0x7u);
    apb_usb_host_set_poll_ms(&host, 4u);
    apb_usb_host_enable(&host, APB_USB_HOST_OPT_BOOT);
    CHECK(win.CTRL == 0x403u);
    CHECK(apb_usb_host_xfer_start(&host, &(apb_usb_host_setup_t) { 0x80u, 6u, 0x0100u, 0u, 18u }) == APB_USB_HOST_E_ABSENT);
    CHECK(strcmp(apb_usb_host_state_name(APB_USB_HOST_STATE_RUN), "RUN") == 0);
    CHECK(strcmp(apb_usb_host_err_name(APB_USB_HOST_ERR_MPS), "MPS") == 0);
    CHECK(strcmp(apb_usb_host_state_name(11u), "?") == 0);

    apb_usb_host_hid_init(&h, &host);
    set_ro(&win.STATUS, APB_USB_HOST_STATE_ENUM);
    service(&h, 0u);
    CHECK(apb_usb_host_hid_kind(&h) == APB_USB_HOST_HID_NONE);

    /* READY: the pad of port 1 */
    set_ro(&win.STATUS, APB_USB_HOST_STATE_RUN);
    set_ro(&win.DEV_ID, 0x00110079u);
    set_ro(&win.DEV_IF, 0x00000000u);
    CHECK(service(&h, APB_USB_HOST_IRQ_READY | APB_USB_HOST_IRQ_STATE) == (APB_USB_HOST_IRQ_READY | APB_USB_HOST_IRQ_STATE));
    CHECK(apb_usb_host_hid_kind(&h) == APB_USB_HOST_HID_GAMEPAD);
    CHECK(apb_usb_host_hid_device(&h)->vid == 0x0079u && apb_usb_host_hid_device(&h)->pid == 0x0011u);
    set_report(1u, R8(0xFF, 0x7F, 0x00, 0x80, 0x80, 0x2F, 0x00, 0x00), 8u);
    service(&h, APB_USB_HOST_IRQ_REPORT);
    CHECK(apb_usb_host_hid_pad_buttons(&h) == (APB_USB_HOST_HID_PAD_RIGHT | APB_USB_HOST_HID_PAD_A));
    CHECK(h.reports == 1u);
    service(&h, 0u);                                    /* same SEQ: not decoded again */
    CHECK(h.reports == 1u);
    set_report(2u, R8(0x7F, 0x7F, 0x00, 0x80, 0x80, 0x0F, 0x00, 0x00), 8u);
    service(&h, APB_USB_HOST_IRQ_REPORT);
    CHECK(apb_usb_host_hid_pad_buttons(&h) == 0u && h.reports == 2u);

    /* the report read alone */
    CHECK(apb_usb_host_report_read(&host, &rpt, 1u) == 8 && rpt.seq == 2u && rpt.data[5] == 0x0Fu);
    CHECK(apb_usb_host_report_fetch(&host, &rpt, &last) && last == 2u);
    CHECK(!apb_usb_host_report_fetch(&host, &rpt, &last));

    /* detach: kind NONE, REPORT_INFO cleared */
    set_ro(&win.STATUS, APB_USB_HOST_STATE_DETACHED);
    set_ro(&win.REPORT_INFO, 0u);
    service(&h, APB_USB_HOST_IRQ_DETACH | APB_USB_HOST_IRQ_STATE);
    CHECK(apb_usb_host_hid_kind(&h) == APB_USB_HOST_HID_NONE);
    CHECK(!apb_usb_host_report_fetch(&host, &rpt, &last) && last == 0u);

    /* a keyboard: READY, then a report with SEQ 1 again */
    set_ro(&win.STATUS, APB_USB_HOST_STATE_RUN);
    set_ro(&win.DEV_ID, 0x00011209u);
    set_ro(&win.DEV_IF, 0x01010100u);
    service(&h, APB_USB_HOST_IRQ_READY);
    CHECK(apb_usb_host_hid_kind(&h) == APB_USB_HOST_HID_KEYBOARD);
    set_report(1u, R8(0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00), 8u);
    service(&h, APB_USB_HOST_IRQ_REPORT);
    CHECK(pop(&h, 0x04u, 0x02u, true));
    CHECK(!apb_usb_host_hid_key_pop(&h, &ev));

    /* a READY with the first report already in (a late service): decoded with events */
    set_report(1u, R8(0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00), 8u);
    service(&h, APB_USB_HOST_IRQ_READY | APB_USB_HOST_IRQ_REPORT);
    CHECK(pop(&h, 0x04u, 0x00u, false));               /* the first device's key released */
    CHECK(pop(&h, 0x05u, 0x00u, true));
    CHECK(!apb_usb_host_hid_key_pop(&h, &ev));

    /* a port found in RUN by a new program (no READY): the current report is
     * the starting state, no events */
    apb_usb_host_hid_init(&h, &host);
    set_report(7u, R8(0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00), 8u);
    service(&h, 0u);
    CHECK(apb_usb_host_hid_kind(&h) == APB_USB_HOST_HID_KEYBOARD);
    CHECK(!apb_usb_host_hid_key_pop(&h, &ev));
    CHECK(apb_usb_host_hid_key_held(&h, 0x28u));
    set_report(8u, R8(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00), 8u);
    service(&h, APB_USB_HOST_IRQ_REPORT);
    CHECK(pop(&h, 0x28u, 0x00u, false));

    /* FAIL out of RUN: device ended */
    set_ro(&win.STATUS, APB_USB_HOST_STATE_BACKOFF | (APB_USB_HOST_ERR_TIMEOUT << 8));
    service(&h, APB_USB_HOST_IRQ_FAIL | APB_USB_HOST_IRQ_STATE);
    CHECK(apb_usb_host_hid_kind(&h) == APB_USB_HOST_HID_NONE);
    CHECK(apb_usb_host_err(&host) == APB_USB_HOST_ERR_TIMEOUT);

    /* the privilege gates */
    apb_usb_host_access_t acc = { APB_USB_HOST_PRIV_U, APB_USB_HOST_PRIV_S, true }, back;
    CHECK(apb_usb_host_set_access(&host, &acc) == APB_USB_HOST_OK && win.MDELEG == 0x104u);
    apb_usb_host_get_access(&host, &back);
    CHECK(back.wr_priv == APB_USB_HOST_PRIV_U && back.rd_priv == APB_USB_HOST_PRIV_S && back.error_resp);
    acc.wr_priv = (apb_usb_host_priv_t) 2;
    CHECK(apb_usb_host_set_access(&host, &acc) == APB_USB_HOST_E_PARAM);

    /* control-transfer primitives (the window is plain memory: no packet flow) */
    host.ctrl_en = true;
    const apb_usb_host_setup_t rd = { 0x81u, 0x06u, 0x2200u, 0x0001u, 0x0012u };
    CHECK(apb_usb_host_xfer_start(&host, &rd) == APB_USB_HOST_OK);
    CHECK(win.SETUP0 == 0x22000681u && win.SETUP1 == 0x00120001u && win.CMD == APB_USB_HOST_CMD_XFER_START);
    CHECK(apb_usb_host_xfer_write(&host, (const uint8_t[]) { 1u, 2u, 3u, 4u, 5u }, 5u) == APB_USB_HOST_OK);
    CHECK(win.XDATA[0] == 0x04030201u && win.XDATA[1] == 0x00000005u && win.XFER == 5u);
    CHECK(apb_usb_host_xfer_write(&host, rpt.data, APB_USB_HOST_PKT_MAX + 1u) == APB_USB_HOST_E_PARAM);
    uint8_t pkt[8] = { 0 };
    win.XDATA[0] = 0x44332211u;
    win.XDATA[1] = 0x88776655u;
    win.XFER     = 6u | APB_USB_HOST_XFER_PKT_Msk;
    CHECK(apb_usb_host_xfer_pkt(&host));
    CHECK(apb_usb_host_xfer_read(&host, pkt, 3u) == 6u && pkt[0] == 0x11u && pkt[2] == 0x33u && pkt[3] == 0u);
    CHECK(apb_usb_host_xfer_read(&host, pkt, 8u) == 6u && pkt[5] == 0x66u && pkt[6] == 0u);
    /* a transfer whose end is already flagged: REFUSED comes back as E_XFER */
    size_t   got = 99u;
    unsigned res = 99u;
    win.XFER = (uint32_t) APB_USB_HOST_RESULT_REFUSED << APB_USB_HOST_XFER_RESULT_Pos;
    CHECK(apb_usb_host_control(&host, &rd, pkt, sizeof(pkt), &got, &res, 10u) == APB_USB_HOST_E_XFER);
    CHECK(got == 0u && res == APB_USB_HOST_RESULT_REFUSED);
    CHECK(strcmp(apb_usb_host_result_name(res), "REFUSED") == 0);
    CHECK(apb_usb_host_control(&host, &rd, pkt, sizeof(pkt), NULL, NULL, 0u) == APB_USB_HOST_E_PARAM);
    const apb_usb_host_setup_t wr = { 0x21u, 0x09u, 0x0200u, 0x0000u, 0x0010u };
    CHECK(apb_usb_host_control(&host, &wr, pkt, sizeof(pkt), NULL, NULL, 10u) == APB_USB_HOST_E_PARAM);

    /* version check */
    set_ro(&win.INFO, 0x20000000u);
    CHECK(apb_usb_host_init(&host, &cfg) == APB_USB_HOST_E_ABSENT);
}

int main(void)
{
    test_identify();
    test_user_pad();
    test_generic_pad();
    test_keyboard();
    test_mouse();
    test_fuzz();
    test_service();
    printf("%s: %u checks, %u failures\n", fails ? "FAIL" : "PASS", checks, fails);
    return fails ? 1 : 0;
}
