/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_usb_host_hid.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * HID report decoder for apb_usb_host. Reference: HID 1.11 Appendix B (boot
 * reports), HID Usage Tables (Keyboard page), doc/apb_usb_host.md "Software".
 *----------------------------------------------------------------------------*/
#include "apb_usb_host_hid.h"

#define NB  APB_USB_HOST_HID_NO_BYTE
#define NO_BIT      { NB, 0u }
#define NO_CHECK    { NB, 0u, 0u }

/*---------------------------------------------------------------------------
 * Gamepad layouts
 *---------------------------------------------------------------------------*/
const apb_usb_host_hid_pad_layout_t apb_usb_host_hid_pad_generic = {
    .vid = 0u, .pid = 0u, .name = "generic", .min_len = 7u,
    .x = 0u, .y = 1u, .x2 = 3u, .y2 = 4u, .hat = NB,
    .need = NO_CHECK,
    .skip = { 0u, 0x03u, 0x02u },
    .a = { 5u, 0x20u }, .b = { 5u, 0x40u }, .x_btn = { 5u, 0x10u }, .y_btn = { 5u, 0x80u },
    .select = { 6u, 0x10u }, .start = { 6u, 0x20u }, .l = { 6u, 0x01u }, .r = { 6u, 0x02u },
};

const apb_usb_host_hid_pad_layout_t apb_usb_host_hid_pads[] = {
    /* DragonRise-style SNES pad: 8 bytes, idle 7F 7F 00 80 80 0F 00 00; bytes
     * 3 and 4 are constant, the low nibble of byte 5 is always F */
    { .vid = 0x0079u, .pid = 0x0011u, .name = "SNES pad 0079:0011", .min_len = 7u,
      .x = 0u, .y = 1u, .x2 = NB, .y2 = NB, .hat = NB,
      .need = { 5u, 0x0Fu, 0x0Fu },
      .skip = NO_CHECK,
      .a = { 5u, 0x20u }, .b = { 5u, 0x40u }, .x_btn = { 5u, 0x10u }, .y_btn = { 5u, 0x80u },
      .select = { 6u, 0x10u }, .start = { 6u, 0x20u }, .l = { 6u, 0x01u }, .r = { 6u, 0x02u } },
};
const size_t apb_usb_host_hid_pads_nr = sizeof(apb_usb_host_hid_pads) / sizeof(apb_usb_host_hid_pads[0]);

/*---------------------------------------------------------------------------
 * Set-up
 *---------------------------------------------------------------------------*/
static void state_clear(apb_usb_host_hid_t *hid)
{
    hid->kbd_gen++;
    hid->kbd_mods = 0u;
    for (unsigned i = 0u; i < APB_USB_HOST_HID_KEYS; i++)
        hid->kbd_keys[i] = 0u;
    hid->kbd_gen++;
    hid->mouse_btn = 0u;
    hid->pad_word  = 0u;
    hid->last_seq  = 0u;
}

void apb_usb_host_hid_init(apb_usb_host_hid_t *hid, apb_usb_host_t *host)
{
    hid->host        = host;
    hid->app_pads    = 0;
    hid->app_pads_nr = 0u;
    hid->pad         = 0;
    hid->kind        = APB_USB_HOST_HID_NONE;
    hid->kbd_gen     = 0u;
    hid->ev_head     = 0u;
    hid->ev_tail     = 0u;
    hid->mouse_sx    = 0u;
    hid->mouse_sy    = 0u;
    hid->mouse_sw    = 0u;
    hid->mouse_tx    = 0u;
    hid->mouse_ty    = 0u;
    hid->mouse_tw    = 0u;
    hid->reports     = 0u;
    hid->ignored     = 0u;
    hid->key_lost    = 0u;
    state_clear(hid);
}

void apb_usb_host_hid_set_pads(apb_usb_host_hid_t *hid, const apb_usb_host_hid_pad_layout_t *pads, size_t nr)
{
    hid->app_pads    = pads;
    hid->app_pads_nr = pads ? nr : 0u;
}

/*---------------------------------------------------------------------------
 * Device
 *---------------------------------------------------------------------------*/
static const apb_usb_host_hid_pad_layout_t *pad_find(const apb_usb_host_hid_pad_layout_t *tab, size_t nr,
                                                     uint16_t vid, uint16_t pid)
{
    for (size_t i = 0u; i < nr; i++)
        if (tab[i].vid == vid && tab[i].pid == pid)
            return &tab[i];
    return 0;
}

void apb_usb_host_hid_identify(apb_usb_host_hid_t *hid, const apb_usb_host_device_t *dev)
{
    apb_usb_host_hid_kind_t kind;
    const apb_usb_host_hid_pad_layout_t *pad = 0;

    hid->kind = APB_USB_HOST_HID_NONE;
    state_clear(hid);
    hid->dev = *dev;
    if (dev->subclass == 1u && dev->protocol == 1u) {
        kind = APB_USB_HOST_HID_KEYBOARD;
    } else if (dev->subclass == 1u && dev->protocol == 2u) {
        kind = APB_USB_HOST_HID_MOUSE;
    } else {
        pad = pad_find(hid->app_pads, hid->app_pads_nr, dev->vid, dev->pid);
        if (!pad)
            pad = pad_find(apb_usb_host_hid_pads, apb_usb_host_hid_pads_nr, dev->vid, dev->pid);
        kind = pad ? APB_USB_HOST_HID_GAMEPAD : APB_USB_HOST_HID_UNKNOWN;
        if (!pad)
            pad = &apb_usb_host_hid_pad_generic;
    }
    hid->pad  = pad;
    hid->kind = (uint8_t) kind;
}

static void key_push(apb_usb_host_hid_t *hid, uint8_t key, uint8_t mods, bool down)
{
    uint32_t h = hid->ev_head;
    if (h - hid->ev_tail >= APB_USB_HOST_HID_KEYQ) {
        hid->key_lost++;
        return;
    }
    uint32_t i = h & (APB_USB_HOST_HID_KEYQ - 1u);
    hid->ev_key[i]  = key;
    hid->ev_mods[i] = mods;
    hid->ev_down[i] = down ? 1u : 0u;
    hid->ev_head    = h + 1u;               /* volatile: published after the entry */
}

void apb_usb_host_hid_forget(apb_usb_host_hid_t *hid)
{
    if (hid->kind == APB_USB_HOST_HID_KEYBOARD)
        for (unsigned i = 0u; i < APB_USB_HOST_HID_KEYS; i++)
            if (hid->kbd_keys[i])
                key_push(hid, hid->kbd_keys[i], 0u, false);
    hid->kind = APB_USB_HOST_HID_NONE;
    state_clear(hid);
}

/*---------------------------------------------------------------------------
 * Decode
 *---------------------------------------------------------------------------*/
static bool has_key(const uint8_t *keys, unsigned n, uint8_t k)
{
    for (unsigned i = 0u; i < n; i++)
        if (keys[i] == k)
            return true;
    return false;
}

static bool decode_keyboard(apb_usb_host_hid_t *hid, const uint8_t *r, size_t len, bool quiet)
{
    uint8_t  now[APB_USB_HOST_HID_KEYS], old[APB_USB_HOST_HID_KEYS];
    unsigned n = 0u;

    if (len < 3u)
        return false;
    size_t end = (len < 2u + APB_USB_HOST_HID_KEYS) ? len : 2u + APB_USB_HOST_HID_KEYS;
    for (size_t i = 2u; i < end; i++) {
        uint8_t k = r[i];
        if (k >= 0x01u && k <= 0x03u)       /* rollover / POST / undefined: no key information */
            return false;
        if (k != 0u && !has_key(now, n, k))
            now[n++] = k;
    }
    const uint8_t mods = r[0];
    for (unsigned i = 0u; i < APB_USB_HOST_HID_KEYS; i++)
        old[i] = hid->kbd_keys[i];
    if (!quiet) {
        for (unsigned i = 0u; i < APB_USB_HOST_HID_KEYS; i++)
            if (old[i] && !has_key(now, n, old[i]))
                key_push(hid, old[i], mods, false);
        for (unsigned i = 0u; i < n; i++)
            if (!has_key(old, APB_USB_HOST_HID_KEYS, now[i]))
                key_push(hid, now[i], mods, true);
    }
    hid->kbd_gen++;
    hid->kbd_mods = mods;
    for (unsigned i = 0u; i < APB_USB_HOST_HID_KEYS; i++)
        hid->kbd_keys[i] = (i < n) ? now[i] : 0u;
    hid->kbd_gen++;
    return true;
}

static bool decode_mouse(apb_usb_host_hid_t *hid, const uint8_t *r, size_t len, bool quiet)
{
    if (len < 3u)
        return false;
    hid->mouse_btn = r[0];
    if (!quiet) {
        hid->mouse_sx += (uint32_t) (int32_t) (int8_t) r[1];
        hid->mouse_sy += (uint32_t) (int32_t) (int8_t) r[2];
        if (len >= 4u)
            hid->mouse_sw += (uint32_t) (int32_t) (int8_t) r[3];
    }
    return true;
}

static bool check(const apb_usb_host_hid_check_t *c, const uint8_t *r, size_t len)
{
    return c->byte < len && (r[c->byte] & c->mask) == c->value;
}

static uint32_t bit(const apb_usb_host_hid_bit_t *b, const uint8_t *r, size_t len, uint32_t btn)
{
    return (b->byte < len && (r[b->byte] & b->mask) != 0u) ? btn : 0u;
}

static uint32_t axis(uint8_t byte, const uint8_t *r, size_t len, uint32_t neg, uint32_t pos)
{
    if (byte >= len)
        return 0u;
    return (r[byte] < 0x40u) ? neg : (r[byte] >= 0xC0u) ? pos : 0u;
}

static bool decode_pad(apb_usb_host_hid_t *hid, const uint8_t *r, size_t len)
{
    static const uint8_t hat_dirs[8] = {
        APB_USB_HOST_HID_PAD_UP,   APB_USB_HOST_HID_PAD_UP   | APB_USB_HOST_HID_PAD_RIGHT,
        APB_USB_HOST_HID_PAD_RIGHT, APB_USB_HOST_HID_PAD_DOWN | APB_USB_HOST_HID_PAD_RIGHT,
        APB_USB_HOST_HID_PAD_DOWN, APB_USB_HOST_HID_PAD_DOWN | APB_USB_HOST_HID_PAD_LEFT,
        APB_USB_HOST_HID_PAD_LEFT, APB_USB_HOST_HID_PAD_UP   | APB_USB_HOST_HID_PAD_LEFT
    };
    const apb_usb_host_hid_pad_layout_t *p = hid->pad;

    if (!p || len < p->min_len)
        return false;
    if (p->need.mask && !check(&p->need, r, len))
        return false;
    if (p->skip.mask && check(&p->skip, r, len))
        return false;

    uint32_t b = axis(p->x,  r, len, APB_USB_HOST_HID_PAD_LEFT, APB_USB_HOST_HID_PAD_RIGHT) |
                 axis(p->y,  r, len, APB_USB_HOST_HID_PAD_UP,   APB_USB_HOST_HID_PAD_DOWN)  |
                 axis(p->x2, r, len, APB_USB_HOST_HID_PAD_LEFT, APB_USB_HOST_HID_PAD_RIGHT) |
                 axis(p->y2, r, len, APB_USB_HOST_HID_PAD_UP,   APB_USB_HOST_HID_PAD_DOWN);
    if (p->hat < len && (r[p->hat] & 0x0Fu) < 8u)
        b |= hat_dirs[r[p->hat] & 0x07u];
    b |= bit(&p->a,      r, len, APB_USB_HOST_HID_PAD_A)      | bit(&p->b,     r, len, APB_USB_HOST_HID_PAD_B) |
         bit(&p->x_btn,  r, len, APB_USB_HOST_HID_PAD_X)      | bit(&p->y_btn, r, len, APB_USB_HOST_HID_PAD_Y) |
         bit(&p->select, r, len, APB_USB_HOST_HID_PAD_SELECT) | bit(&p->start, r, len, APB_USB_HOST_HID_PAD_START) |
         bit(&p->l,      r, len, APB_USB_HOST_HID_PAD_L)      | bit(&p->r,     r, len, APB_USB_HOST_HID_PAD_R);
    uint32_t x = (p->x < len) ? (uint8_t) (r[p->x] - 0x80u) : 0u;
    uint32_t y = (p->y < len) ? (uint8_t) (r[p->y] - 0x80u) : 0u;
    hid->pad_word = b | (x << 16) | (y << 24);
    return true;
}

static void decode(apb_usb_host_hid_t *hid, const uint8_t *r, size_t len, bool quiet)
{
    bool used;
    switch (hid->kind) {
    case APB_USB_HOST_HID_KEYBOARD: used = decode_keyboard(hid, r, len, quiet); break;
    case APB_USB_HOST_HID_MOUSE:    used = decode_mouse(hid, r, len, quiet);    break;
    case APB_USB_HOST_HID_GAMEPAD:
    case APB_USB_HOST_HID_UNKNOWN:  used = decode_pad(hid, r, len);             break;
    default:                        return;
    }
    if (used)
        hid->reports++;
    else
        hid->ignored++;
}

void apb_usb_host_hid_decode(apb_usb_host_hid_t *hid, const uint8_t *report, size_t len)
{
    if (hid && (report || len == 0u))
        decode(hid, report, len, false);
}

/*---------------------------------------------------------------------------
 * The port's event entry
 *---------------------------------------------------------------------------*/
uint32_t apb_usb_host_hid_service(apb_usb_host_hid_t *hid)
{
    apb_usb_host_report_t rpt;
    apb_usb_host_t       *host = hid->host;

    if (!host)
        return 0u;
    const uint32_t pend = apb_usb_host_irq_pending(host);
    apb_usb_host_irq_clear(host, pend & APB_USB_HOST_HID_IRQ_MASK);

    if ((pend & (APB_USB_HOST_IRQ_READY | APB_USB_HOST_IRQ_DETACH)) && hid->kind != APB_USB_HOST_HID_NONE)
        apb_usb_host_hid_forget(hid);
    if (!apb_usb_host_running(host)) {
        if (hid->kind != APB_USB_HOST_HID_NONE)
            apb_usb_host_hid_forget(hid);
        return pend;
    }
    if (hid->kind == APB_USB_HOST_HID_NONE) {
        apb_usb_host_device_t dev;
        if (apb_usb_host_device(host, &dev) != APB_USB_HOST_OK)
            return pend;
        apb_usb_host_hid_identify(hid, &dev);
        /* Found in RUN without a READY: the session of a previous program;
         * its current report is the starting state, without events */
        if (!(pend & APB_USB_HOST_IRQ_READY) && apb_usb_host_report_read(host, &rpt, 4u) > 0) {
            decode(hid, rpt.data, rpt.len, true);
            hid->last_seq = rpt.seq;
        }
    }
    if (apb_usb_host_report_fetch(host, &rpt, &hid->last_seq))
        decode(hid, rpt.data, rpt.len, false);
    return pend;
}

/*---------------------------------------------------------------------------
 * Getters
 *---------------------------------------------------------------------------*/
const char *apb_usb_host_hid_kind_name(apb_usb_host_hid_kind_t kind)
{
    static const char *const names[] = { "none", "keyboard", "mouse", "gamepad", "unknown" };
    return ((unsigned) kind < sizeof(names) / sizeof(names[0])) ? names[kind] : "?";
}

const char *apb_usb_host_hid_pad_name(const apb_usb_host_hid_t *hid)
{
    return (hid->kind == APB_USB_HOST_HID_GAMEPAD || hid->kind == APB_USB_HOST_HID_UNKNOWN) && hid->pad
           ? hid->pad->name : 0;
}

bool apb_usb_host_hid_key_pop(apb_usb_host_hid_t *hid, apb_usb_host_hid_key_t *ev)
{
    uint32_t t = hid->ev_tail;
    if (t == hid->ev_head)
        return false;
    uint32_t i = t & (APB_USB_HOST_HID_KEYQ - 1u);
    ev->key  = hid->ev_key[i];
    ev->mods = hid->ev_mods[i];
    ev->down = hid->ev_down[i] != 0u;
    hid->ev_tail = t + 1u;                  /* volatile: the slot is free after the reads */
    return true;
}

void apb_usb_host_hid_kbd_state(const apb_usb_host_hid_t *hid, uint8_t *mods, uint8_t keys[APB_USB_HOST_HID_KEYS])
{
    uint8_t  m = 0u, k[APB_USB_HOST_HID_KEYS];
    for (unsigned tries = 0u; tries < 8u; tries++) {
        uint32_t g = hid->kbd_gen;
        m = hid->kbd_mods;
        for (unsigned i = 0u; i < APB_USB_HOST_HID_KEYS; i++)
            k[i] = hid->kbd_keys[i];
        if (!(g & 1u) && g == hid->kbd_gen)
            break;
    }
    if (mods)
        *mods = m;
    if (keys)
        for (unsigned i = 0u; i < APB_USB_HOST_HID_KEYS; i++)
            keys[i] = k[i];
}

bool apb_usb_host_hid_key_held(const apb_usb_host_hid_t *hid, uint8_t key)
{
    uint8_t k[APB_USB_HOST_HID_KEYS];
    apb_usb_host_hid_kbd_state(hid, 0, k);
    return key != 0u && has_key(k, APB_USB_HOST_HID_KEYS, key);
}

char apb_usb_host_hid_key_ascii(uint8_t key, uint8_t mods)
{
    static const char plain[] = "1234567890\n\x1b\b\t -=[]\\#;'`,./";
    static const char shift[] = "!@#$%^&*()\n\x1b\b\t _+{}|~:\"~<>?";
    const bool up = (mods & APB_USB_HOST_HID_MOD_SHIFT) != 0u;

    if (key >= 0x04u && key <= 0x1Du)
        return (char) ((up ? 'A' : 'a') + (key - 0x04u));
    if (key >= 0x1Eu && key <= 0x38u)
        return (up ? shift : plain)[key - 0x1Eu];
    return 0;
}

void apb_usb_host_hid_mouse_take(apb_usb_host_hid_t *hid, int32_t *dx, int32_t *dy, int32_t *dwheel)
{
    uint32_t sx = hid->mouse_sx, sy = hid->mouse_sy, sw = hid->mouse_sw;
    if (dx)
        *dx = (int32_t) (sx - hid->mouse_tx);
    if (dy)
        *dy = (int32_t) (sy - hid->mouse_ty);
    if (dwheel)
        *dwheel = (int32_t) (sw - hid->mouse_tw);
    hid->mouse_tx = sx;
    hid->mouse_ty = sy;
    hid->mouse_tw = sw;
}
