/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_usb_host.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Low-speed USB host driver API.
 *
 *   apb_usb_host_init                  bind a handle, read and check INFO
 *   apb_usb_host_enable / _disable     CTRL.EN with the enumeration options
 *   apb_usb_host_set_poll_ms           CTRL.POLL_MS
 *   apb_usb_host_restart               CMD.RESTART
 *   apb_usb_host_state / _err / _attempt / _step / _line / _fs_dev  (inline)
 *   apb_usb_host_state_name / _err_name / _result_name
 *   apb_usb_host_device                DEV_ID, DEV_IF, DEV_EP, qualified by STATE
 *   apb_usb_host_report_read           the report with the SEQ retry
 *   apb_usb_host_report_fetch          the same, telling a new report from the last one
 *   apb_usb_host_irq_enable / _disable / _pending / _clear  (inline)
 *   apb_usb_host_control               a whole software control transfer (CTRL_EN builds)
 *   apb_usb_host_xfer_*                its non-blocking primitives
 *   apb_usb_host_set_access / _get_access   MDELEG privilege gates (Machine mode only)
 *
 * The driver keeps no global state: every call takes the device handle filled
 * by apb_usb_host_init().
 *
 * Reports. The IP copies each valid report in one cycle to the buffer behind
 * the report window, so REPORT_INFO and the window always describe one
 * report; a copy can fall between two register reads, so the read takes
 * REPORT_INFO, the words, REPORT_INFO again, and repeats when SEQ moved (doc
 * "Report buffer").
 * SEQ counts reports and wraps at 256; REPORT_INFO clears when the port
 * leaves RUN, so LEN 0 means no report.
 *
 * Control transfers. apb_usb_host_control() owns IRQ_PEND.XFER_PKT and
 * XFER_DONE while it runs (it clears and polls them); an interrupt handler
 * must leave those two bits alone, and their enables off, during the call.
 *
 * Privilege. With the default MDELEG_RST only Machine mode may access the
 * window after reset (APB_USB_HOST_MDELEG_RESET). MDELEG itself
 * (apb_usb_host_set_access, apb_usb_host_get_access) is Machine mode only.
 * The driver does not read the privilege mode: calling a function from a
 * mode the gates refuse is the caller's error.
 *----------------------------------------------------------------------------*/
#ifndef APB_USB_HOST_H
#define APB_USB_HOST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "apb_usb_host_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

/*---------------------------------------------------------------------------
 * Types
 *---------------------------------------------------------------------------*/
typedef enum {
    APB_USB_HOST_OK          =  0,
    APB_USB_HOST_E_PARAM   = -1,  /* null pointer, misaligned base, value out of range            */
    APB_USB_HOST_E_ABSENT  = -2,  /* INFO does not hold version 1, or the build lacks the feature */
    APB_USB_HOST_E_TIMEOUT = -3,  /* a bounded wait ran out                                        */
    APB_USB_HOST_E_STATE   = -4,  /* the port is not in RUN                                        */
    APB_USB_HOST_E_XFER    = -5   /* a control transfer ended with a RESULT other than OK         */
} apb_usb_host_status_t;

typedef struct {                    /* apb_usb_host_init() arguments */
    uintptr_t base;                 /* register window, word aligned */
} apb_usb_host_config_t;

typedef struct {                    /* device handle, filled from INFO */
    APB_USB_HOST_TypeDef *regs;
    bool  fs_en;                    /* full-speed support built        */
    bool  ctrl_en;                  /* software control transfers      */
    bool  diag_en;                  /* diagnostic counters             */
} apb_usb_host_t;

/* Enumeration options of apb_usb_host_enable() (CTRL bits) */
#define APB_USB_HOST_OPT_BOOT       APB_USB_HOST_CTRL_BOOT_Msk    /* SET_PROTOCOL(boot) for boot interfaces */
#define APB_USB_HOST_OPT_IDLE0      APB_USB_HOST_CTRL_IDLE0_Msk   /* SET_IDLE(0)                            */
#define APB_USB_HOST_OPT_DEFAULT    (APB_USB_HOST_OPT_BOOT | APB_USB_HOST_OPT_IDLE0)

#define APB_USB_HOST_REPORT_MAX     64u     /* the report window; 8 bytes at low speed */
#define APB_USB_HOST_PKT_MAX        64u     /* the XDATA window                        */

typedef struct {                    /* the enumerated device (DEV_ID, DEV_IF, DEV_EP) */
    uint16_t vid;                   /* idVendor                                      */
    uint16_t pid;                   /* idProduct                                     */
    uint8_t  if_num;                /* bInterfaceNumber of the selected HID interface */
    uint8_t  subclass;              /* bInterfaceSubClass: 1 boot                     */
    uint8_t  protocol;              /* bInterfaceProtocol: 1 keyboard, 2 mouse        */
    bool     boot;                  /* boot protocol set (DEV_IF.BOOT)               */
    uint8_t  ep;                    /* interrupt IN endpoint number                   */
    uint8_t  ep_mps;                /* its wMaxPacketSize                             */
    uint8_t  interval;              /* its bInterval (ms)                             */
    uint8_t  mps0;                  /* bMaxPacketSize0                                */
} apb_usb_host_device_t;

typedef struct {                    /* one report */
    uint8_t len;                    /* bytes (0: no report)                          */
    uint8_t seq;                    /* REPORT_INFO.SEQ of this report                */
    uint8_t data[APB_USB_HOST_REPORT_MAX];
} apb_usb_host_report_t;

typedef struct {                    /* the 8 setup bytes of a control transfer */
    uint8_t  bmRequestType;         /* bit 7: 1 IN data stage, 0 OUT (ignored when wLength is 0) */
    uint8_t  bRequest;
    uint16_t wValue;
    uint16_t wIndex;
    uint16_t wLength;
} apb_usb_host_setup_t;

typedef enum {                      /* MDELEG WR_PRIV / RD_PRIV: lowest admitted privilege */
    APB_USB_HOST_PRIV_U = APB_USB_HOST_PRIV_CODE_U,
    APB_USB_HOST_PRIV_S = APB_USB_HOST_PRIV_CODE_S,
    APB_USB_HOST_PRIV_M = APB_USB_HOST_PRIV_CODE_M
} apb_usb_host_priv_t;

typedef struct {                    /* MDELEG content */
    apb_usb_host_priv_t wr_priv;
    apb_usb_host_priv_t rd_priv;
    bool                error_resp; /* true: PSLVERR on a refused access; false: silent drop */
} apb_usb_host_access_t;

/*---------------------------------------------------------------------------
 * Set-up
 *---------------------------------------------------------------------------*/
apb_usb_host_status_t apb_usb_host_init(apb_usb_host_t *dev, const apb_usb_host_config_t *cfg);

/* CTRL.EN = 1 with the options (APB_USB_HOST_OPT_*); POLL_MS is kept. A port
 * already enabled keeps running (no new enumeration); BOOT and IDLE0 then
 * apply from the next enumeration. */
void apb_usb_host_enable(apb_usb_host_t *dev, uint32_t opts);

/* CTRL.EN = 0: the port goes to OFF and releases the lines */
static inline void apb_usb_host_disable(apb_usb_host_t *dev)
{ dev->regs->CTRL &= ~APB_USB_HOST_CTRL_EN_Msk; }

static inline bool apb_usb_host_enabled(const apb_usb_host_t *dev)
{ return (dev->regs->CTRL & APB_USB_HOST_CTRL_EN_Msk) != 0u; }

/* Poll period in ms (1-255); 0: the endpoint's bInterval. Applies from the next poll. */
void apb_usb_host_set_poll_ms(apb_usb_host_t *dev, uint8_t ms);

/* RECOVERY .. UNSUPPORTED: a new bus reset and enumeration, ATTEMPT cleared */
static inline void apb_usb_host_restart(apb_usb_host_t *dev) { dev->regs->CMD = APB_USB_HOST_CMD_RESTART; }

/*---------------------------------------------------------------------------
 * State
 *---------------------------------------------------------------------------*/
#define APB_USB_HOST_FIELD_GET(v, f)    (((v) & APB_USB_HOST_##f##_Msk) >> APB_USB_HOST_##f##_Pos)

static inline uint32_t apb_usb_host_status(const apb_usb_host_t *dev) { return dev->regs->STATUS; }
static inline unsigned apb_usb_host_state(const apb_usb_host_t *dev)
{ return (unsigned) APB_USB_HOST_FIELD_GET(dev->regs->STATUS, STATUS_STATE); }
static inline bool     apb_usb_host_running(const apb_usb_host_t *dev)
{ return apb_usb_host_state(dev) == APB_USB_HOST_STATE_RUN; }
static inline unsigned apb_usb_host_err(const apb_usb_host_t *dev)       /* STATUS.ERR: APB_USB_HOST_ERR_* */
{ return (unsigned) APB_USB_HOST_FIELD_GET(dev->regs->STATUS, STATUS_ERR); }
static inline unsigned apb_usb_host_attempt(const apb_usb_host_t *dev)
{ return (unsigned) APB_USB_HOST_FIELD_GET(dev->regs->STATUS, STATUS_ATTEMPT); }
static inline unsigned apb_usb_host_step(const apb_usb_host_t *dev)      /* 1, 3-6; 0 poll or transfer */
{ return (unsigned) APB_USB_HOST_FIELD_GET(dev->regs->STATUS, STATUS_STEP); }
static inline unsigned apb_usb_host_line(const apb_usb_host_t *dev)      /* {D+, D-} */
{ return (unsigned) APB_USB_HOST_FIELD_GET(dev->regs->STATUS, STATUS_LINE); }
static inline bool     apb_usb_host_fs_dev(const apb_usb_host_t *dev)
{ return (dev->regs->STATUS & APB_USB_HOST_STATUS_FS_DEV_Msk) != 0u; }

/* Names for logs: "RUN", "STALL", ...; "?" for a value outside the map */
const char *apb_usb_host_state_name(unsigned state);
const char *apb_usb_host_err_name(unsigned err);
const char *apb_usb_host_result_name(unsigned result);

/* The enumerated device; APB_USB_HOST_E_STATE (info still filled) unless
 * the port is in RUN after the registers were read */
apb_usb_host_status_t apb_usb_host_device(const apb_usb_host_t *dev, apb_usb_host_device_t *info);

/*---------------------------------------------------------------------------
 * Reports
 *---------------------------------------------------------------------------*/

/* The current report, consistent (SEQ retry); returns its length (0: none),
 * or APB_USB_HOST_E_TIMEOUT if SEQ kept moving for max_tries reads */
int apb_usb_host_report_read(const apb_usb_host_t *dev, apb_usb_host_report_t *rpt, unsigned max_tries);

/* The same, then true only for a report whose SEQ differs from *last_seq
 * (updated). No report (LEN 0) resets *last_seq to 0, the SEQ the port
 * starts from in RUN, so the first report of the next session is new. */
bool apb_usb_host_report_fetch(const apb_usb_host_t *dev, apb_usb_host_report_t *rpt, uint8_t *last_seq);

/*---------------------------------------------------------------------------
 * Interrupts (IRQ_PEND causes latch whatever IRQ_EN holds)
 *---------------------------------------------------------------------------*/
static inline void     apb_usb_host_irq_enable(apb_usb_host_t *dev, uint32_t mask)
{ dev->regs->IRQ_EN |= mask & APB_USB_HOST_IRQ_ALL; }
static inline void     apb_usb_host_irq_disable(apb_usb_host_t *dev, uint32_t mask)
{ dev->regs->IRQ_EN &= ~mask; }
static inline uint32_t apb_usb_host_irq_pending(const apb_usb_host_t *dev) { return dev->regs->IRQ_PEND; }
static inline void     apb_usb_host_irq_clear(apb_usb_host_t *dev, uint32_t mask)
{ dev->regs->IRQ_PEND = mask & APB_USB_HOST_IRQ_ALL; }

/*---------------------------------------------------------------------------
 * Software control transfers (INFO.CTRL_EN = 1; APB_USB_HOST_E_ABSENT otherwise)
 *---------------------------------------------------------------------------*/

/* A whole transfer, blocking: the setup, the data stage through the XDATA
 * window packet by packet (IN: into data, at most max bytes kept, every
 * packet acknowledged; OUT: wLength bytes from data), the status stage.
 * *actual (may be NULL) gets the data-stage bytes moved; *result (may be
 * NULL) the XFER.RESULT code. APB_USB_HOST_E_XFER for a RESULT other than
 * OK, APB_USB_HOST_E_TIMEOUT after max_polls (at least 1) status reads
 * without progress (the transfer is then aborted). */
apb_usb_host_status_t apb_usb_host_control(apb_usb_host_t *dev, const apb_usb_host_setup_t *setup,
                                           void *data, size_t max, size_t *actual,
                                           unsigned *result, uint32_t max_polls);

/* Primitives. xfer_start writes SETUP0/1, clears IRQ_PEND.XFER_PKT and
 * XFER_DONE, and sets CMD.XFER_START. Then, until IRQ_PEND.XFER_DONE: when
 * xfer_pkt() is true, an IN stage reads the packet (xfer_read) and an OUT
 * stage writes one (xfer_write), and xfer_next() hands the buffer back. */
apb_usb_host_status_t apb_usb_host_xfer_start(apb_usb_host_t *dev, const apb_usb_host_setup_t *setup);
static inline bool     apb_usb_host_xfer_busy(const apb_usb_host_t *dev)
{ return (dev->regs->STATUS & APB_USB_HOST_STATUS_XFER_BUSY_Msk) != 0u; }
static inline bool     apb_usb_host_xfer_pkt(const apb_usb_host_t *dev)
{ return (dev->regs->XFER & APB_USB_HOST_XFER_PKT_Msk) != 0u; }
static inline bool     apb_usb_host_xfer_done(const apb_usb_host_t *dev)
{ return (dev->regs->IRQ_PEND & APB_USB_HOST_IRQ_XFER_DONE) != 0u; }
static inline unsigned apb_usb_host_xfer_result(const apb_usb_host_t *dev)     /* APB_USB_HOST_RESULT_* */
{ return (unsigned) APB_USB_HOST_FIELD_GET(dev->regs->XFER, XFER_RESULT); }
static inline void     apb_usb_host_xfer_next(apb_usb_host_t *dev)  { dev->regs->CMD = APB_USB_HOST_CMD_XFER_NEXT; }
static inline void     apb_usb_host_xfer_abort(apb_usb_host_t *dev) { dev->regs->CMD = APB_USB_HOST_CMD_XFER_ABORT; }

/* IN packet in the XDATA window: copies at most max bytes, returns its length (XFER.LEN) */
size_t apb_usb_host_xfer_read(const apb_usb_host_t *dev, void *buf, size_t max);
/* OUT packet: len bytes (at most APB_USB_HOST_PKT_MAX) into XDATA and XFER.LEN */
apb_usb_host_status_t apb_usb_host_xfer_write(apb_usb_host_t *dev, const void *buf, size_t len);

/*---------------------------------------------------------------------------
 * Privilege gates (Machine mode only)
 *---------------------------------------------------------------------------*/
apb_usb_host_status_t apb_usb_host_set_access(apb_usb_host_t *dev, const apb_usb_host_access_t *access);
void                  apb_usb_host_get_access(const apb_usb_host_t *dev, apb_usb_host_access_t *access);

#ifdef __cplusplus
}
#endif

#endif /* APB_USB_HOST_H */
