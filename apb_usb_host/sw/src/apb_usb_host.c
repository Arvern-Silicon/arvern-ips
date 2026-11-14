/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_usb_host.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Low-speed USB host driver. Reference: doc/apb_usb_host.md.
 *----------------------------------------------------------------------------*/
#include "apb_usb_host.h"

#define FIELD_GET(v, f)     (((v) & f##_Msk) >> f##_Pos)

apb_usb_host_status_t apb_usb_host_init(apb_usb_host_t *dev, const apb_usb_host_config_t *cfg)
{
    if (!dev || !cfg || (cfg->base & 3u))
        return APB_USB_HOST_E_PARAM;
    dev->regs = (APB_USB_HOST_TypeDef *) cfg->base;
    uint32_t i = dev->regs->INFO;
    if (FIELD_GET(i, APB_USB_HOST_INFO_VERSION) != APB_USB_HOST_INFO_VERSION_1)
        return APB_USB_HOST_E_ABSENT;
    dev->fs_en   = (i & APB_USB_HOST_INFO_FS_EN_Msk)   != 0u;
    dev->ctrl_en = (i & APB_USB_HOST_INFO_CTRL_EN_Msk) != 0u;
    dev->diag_en = (i & APB_USB_HOST_INFO_DIAG_EN_Msk) != 0u;
    return APB_USB_HOST_OK;
}

void apb_usb_host_enable(apb_usb_host_t *dev, uint32_t opts)
{
    uint32_t c = dev->regs->CTRL & APB_USB_HOST_CTRL_POLL_MS_Msk;
    dev->regs->CTRL = c | (opts & (APB_USB_HOST_CTRL_BOOT_Msk | APB_USB_HOST_CTRL_IDLE0_Msk)) |
                      APB_USB_HOST_CTRL_EN_Msk;
}

void apb_usb_host_set_poll_ms(apb_usb_host_t *dev, uint8_t ms)
{
    uint32_t c = dev->regs->CTRL & ~APB_USB_HOST_CTRL_POLL_MS_Msk;
    dev->regs->CTRL = c | ((uint32_t) ms << APB_USB_HOST_CTRL_POLL_MS_Pos);
}

/*---------------------------------------------------------------------------
 * Names
 *---------------------------------------------------------------------------*/
static const char *const state_names[] = {
    "OFF", "DETACHED", "DEBOUNCE", "RESET", "RECOVERY", "ENUM", "RUN",
    "BACKOFF", "FAILED", "UNSUPPORTED", "FS_DETECTED"
};
static const char *const err_names[] = {
    "NONE", "TIMEOUT", "CRC", "UNEXPECTED", "STALL", "PROGRESS", "MALFORMED",
    "HUB", "NO_HID", "MPS"
};
static const char *const result_names[] = {
    "OK", "STALL", "ERROR", "ABORTED", "DETACHED", "REFUSED"
};

#define NAME_OF(tab, i)     (((i) < sizeof(tab) / sizeof((tab)[0])) ? (tab)[i] : "?")

const char *apb_usb_host_state_name(unsigned state)   { return NAME_OF(state_names, state); }
const char *apb_usb_host_err_name(unsigned err)       { return NAME_OF(err_names, err); }
const char *apb_usb_host_result_name(unsigned result) { return NAME_OF(result_names, result); }

/*---------------------------------------------------------------------------
 * Device information
 *---------------------------------------------------------------------------*/
apb_usb_host_status_t apb_usb_host_device(const apb_usb_host_t *dev, apb_usb_host_device_t *info)
{
    if (!dev || !info)
        return APB_USB_HOST_E_PARAM;
    uint32_t id = dev->regs->DEV_ID, itf = dev->regs->DEV_IF, ep = dev->regs->DEV_EP;
    info->vid      = (uint16_t) FIELD_GET(id,  APB_USB_HOST_DEV_ID_VID);
    info->pid      = (uint16_t) FIELD_GET(id,  APB_USB_HOST_DEV_ID_PID);
    info->if_num   = (uint8_t)  FIELD_GET(itf, APB_USB_HOST_DEV_IF_NUM);
    info->subclass = (uint8_t)  FIELD_GET(itf, APB_USB_HOST_DEV_IF_SUBCLASS);
    info->protocol = (uint8_t)  FIELD_GET(itf, APB_USB_HOST_DEV_IF_PROTOCOL);
    info->boot     = (itf & APB_USB_HOST_DEV_IF_BOOT_Msk) != 0u;
    info->ep       = (uint8_t)  FIELD_GET(ep,  APB_USB_HOST_DEV_EP_NUM);
    info->ep_mps   = (uint8_t)  FIELD_GET(ep,  APB_USB_HOST_DEV_EP_MPS);
    info->interval = (uint8_t)  FIELD_GET(ep,  APB_USB_HOST_DEV_EP_INTERVAL);
    info->mps0     = (uint8_t)  FIELD_GET(ep,  APB_USB_HOST_DEV_EP_MPS0);
    /* STATUS after the values: RUN now means they belong to the device in RUN */
    return apb_usb_host_running(dev) ? APB_USB_HOST_OK : APB_USB_HOST_E_STATE;
}

/*---------------------------------------------------------------------------
 * Reports
 *---------------------------------------------------------------------------*/
int apb_usb_host_report_read(const apb_usb_host_t *dev, apb_usb_host_report_t *rpt, unsigned max_tries)
{
    if (!dev || !rpt || max_tries == 0u)
        return APB_USB_HOST_E_PARAM;
    uint32_t info = dev->regs->REPORT_INFO;
    for (unsigned t = 0u; t < max_tries; t++) {
        uint32_t len = FIELD_GET(info, APB_USB_HOST_REPORT_INFO_LEN);
        if (len > APB_USB_HOST_REPORT_MAX)
            len = APB_USB_HOST_REPORT_MAX;
        for (uint32_t w = 0u; w < (len + 3u) / 4u; w++) {
            uint32_t v = dev->regs->REPORT[w];
            for (uint32_t b = 0u; b < 4u && 4u * w + b < len; b++)
                rpt->data[4u * w + b] = (uint8_t) (v >> (8u * b));
        }
        uint32_t again = dev->regs->REPORT_INFO;
        if (again == info) {
            rpt->len = (uint8_t) len;
            rpt->seq = (uint8_t) FIELD_GET(info, APB_USB_HOST_REPORT_INFO_SEQ);
            return (int) len;
        }
        info = again;
    }
    return APB_USB_HOST_E_TIMEOUT;
}

bool apb_usb_host_report_fetch(const apb_usb_host_t *dev, apb_usb_host_report_t *rpt, uint8_t *last_seq)
{
    if (!last_seq)
        return false;
    int n = apb_usb_host_report_read(dev, rpt, 4u);
    if (n == 0)
        *last_seq = 0u;
    if (n <= 0 || rpt->seq == *last_seq)
        return false;
    *last_seq = rpt->seq;
    return true;
}

/*---------------------------------------------------------------------------
 * Software control transfers
 *---------------------------------------------------------------------------*/
apb_usb_host_status_t apb_usb_host_xfer_start(apb_usb_host_t *dev, const apb_usb_host_setup_t *setup)
{
    if (!dev || !setup)
        return APB_USB_HOST_E_PARAM;
    if (!dev->ctrl_en)
        return APB_USB_HOST_E_ABSENT;
    dev->regs->SETUP0   = (uint32_t) setup->bmRequestType | ((uint32_t) setup->bRequest << 8) |
                          ((uint32_t) setup->wValue << 16);
    dev->regs->SETUP1   = (uint32_t) setup->wIndex | ((uint32_t) setup->wLength << 16);
    dev->regs->IRQ_PEND = APB_USB_HOST_IRQ_XFER_PKT | APB_USB_HOST_IRQ_XFER_DONE;
    dev->regs->CMD      = APB_USB_HOST_CMD_XFER_START;
    return APB_USB_HOST_OK;
}

size_t apb_usb_host_xfer_read(const apb_usb_host_t *dev, void *buf, size_t max)
{
    uint8_t *p   = (uint8_t *) buf;
    size_t   len = (size_t) FIELD_GET(dev->regs->XFER, APB_USB_HOST_XFER_LEN);
    if (len > APB_USB_HOST_PKT_MAX)
        len = APB_USB_HOST_PKT_MAX;
    size_t n = (len < max) ? len : max;
    for (size_t w = 0u; w < (n + 3u) / 4u; w++) {
        uint32_t v = dev->regs->XDATA[w];
        for (size_t b = 0u; b < 4u && 4u * w + b < n; b++)
            p[4u * w + b] = (uint8_t) (v >> (8u * b));
    }
    return len;
}

apb_usb_host_status_t apb_usb_host_xfer_write(apb_usb_host_t *dev, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *) buf;
    if (!dev || (len && !buf) || len > APB_USB_HOST_PKT_MAX)
        return APB_USB_HOST_E_PARAM;
    for (size_t w = 0u; w < (len + 3u) / 4u; w++) {
        uint32_t v = 0u;
        for (size_t b = 0u; b < 4u && 4u * w + b < len; b++)
            v |= (uint32_t) p[4u * w + b] << (8u * b);
        dev->regs->XDATA[w] = v;
    }
    dev->regs->XFER = (uint32_t) len & APB_USB_HOST_XFER_LEN_Msk;
    return APB_USB_HOST_OK;
}

apb_usb_host_status_t apb_usb_host_control(apb_usb_host_t *dev, const apb_usb_host_setup_t *setup,
                                           void *data, size_t max, size_t *actual,
                                           unsigned *result, uint32_t max_polls)
{
    if (!dev || !setup || (setup->wLength && !data) || max_polls == 0u)
        return APB_USB_HOST_E_PARAM;
    const bool in = (setup->bmRequestType & 0x80u) != 0u;
    if (!in && max < setup->wLength)
        return APB_USB_HOST_E_PARAM;

    uint32_t mps = FIELD_GET(dev->regs->DEV_EP, APB_USB_HOST_DEV_EP_MPS0);
    if (mps == 0u || mps > APB_USB_HOST_PKT_MAX)
        mps = 8u;

    apb_usb_host_status_t st = apb_usb_host_xfer_start(dev, setup);
    if (st != APB_USB_HOST_OK)
        return st;

    uint8_t *p     = (uint8_t *) data;
    size_t   moved = 0u;
    uint32_t n     = 0u;
    bool     done  = false;
    while (n < max_polls) {
        if (apb_usb_host_xfer_done(dev)) {
            done = true;
            break;
        }
        if (apb_usb_host_xfer_pkt(dev)) {
            if (in) {
                size_t room = (moved < max) ? max - moved : 0u;
                size_t len  = apb_usb_host_xfer_read(dev, p + moved, room);
                moved += (len < room) ? len : room;
            } else {
                size_t left  = (size_t) setup->wLength - moved;
                size_t chunk = (left < mps) ? left : mps;
                (void) apb_usb_host_xfer_write(dev, p + moved, chunk);
                moved += chunk;
            }
            apb_usb_host_xfer_next(dev);
            n = 0u;                             /* progress: the bound is per packet */
        } else {
            n++;
        }
    }
    if (!done) {
        apb_usb_host_xfer_abort(dev);
        for (n = 0u; n < max_polls && !apb_usb_host_xfer_done(dev); n++)
            ;
    }
    unsigned r = apb_usb_host_xfer_result(dev);
    dev->regs->IRQ_PEND = APB_USB_HOST_IRQ_XFER_PKT | APB_USB_HOST_IRQ_XFER_DONE;
    if (actual)
        *actual = moved;
    if (result)
        *result = r;
    if (!done)
        return APB_USB_HOST_E_TIMEOUT;
    return (r == APB_USB_HOST_RESULT_OK) ? APB_USB_HOST_OK : APB_USB_HOST_E_XFER;
}

/*---------------------------------------------------------------------------
 * Privilege gates
 *---------------------------------------------------------------------------*/
static bool priv_valid(apb_usb_host_priv_t p)
{
    return p == APB_USB_HOST_PRIV_U || p == APB_USB_HOST_PRIV_S || p == APB_USB_HOST_PRIV_M;
}

apb_usb_host_status_t apb_usb_host_set_access(apb_usb_host_t *dev, const apb_usb_host_access_t *access)
{
    if (!dev || !access || !priv_valid(access->wr_priv) || !priv_valid(access->rd_priv))
        return APB_USB_HOST_E_PARAM;

    /* One word store: gates (byte 0) and RESP (byte 1) switch together, no access sees a mix */
    dev->regs->MDELEG = ((uint32_t) access->wr_priv << APB_USB_HOST_MDELEG_WR_PRIV_Pos) |
                        ((uint32_t) access->rd_priv << APB_USB_HOST_MDELEG_RD_PRIV_Pos) |
                        (access->error_resp ? APB_USB_HOST_MDELEG_RESP_Msk : 0u);
    return APB_USB_HOST_OK;
}

void apb_usb_host_get_access(const apb_usb_host_t *dev, apb_usb_host_access_t *access)
{
    uint32_t v = dev->regs->MDELEG;
    access->wr_priv    = (apb_usb_host_priv_t) FIELD_GET(v, APB_USB_HOST_MDELEG_WR_PRIV);
    access->rd_priv    = (apb_usb_host_priv_t) FIELD_GET(v, APB_USB_HOST_MDELEG_RD_PRIV);
    access->error_resp = (v & APB_USB_HOST_MDELEG_RESP_Msk) != 0u;
}
