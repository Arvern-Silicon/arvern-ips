/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_usb_host_regs.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Low-speed USB host register map: a structure overlaying the register window
 * and the field position / mask macros (CMSIS naming:
 * APB_USB_HOST_<REG>_<FIELD>_Pos and _Msk). Reference: doc/apb_usb_host.md.
 *----------------------------------------------------------------------------*/
#ifndef APB_USB_HOST_REGS_H
#define APB_USB_HOST_REGS_H

#include <stddef.h>
#include <stdint.h>

#define APB_USB_HOST_IO  volatile           /* read-write register */
#define APB_USB_HOST_I   volatile const     /* read-only register  */
#define APB_USB_HOST_O   volatile           /* write-only register, reads 0 */

/*---------------------------------------------------------------------------
 * Register structure
 *---------------------------------------------------------------------------*/

/* The register window: 256 bytes at the minimum ADDRW = 8; a wider window
 * only adds unmapped space above 0xFC. */
typedef struct {
    APB_USB_HOST_I   uint32_t INFO;         /* 0x000: build parameters, VERSION                    */
    APB_USB_HOST_IO  uint32_t CTRL;         /* 0x004: EN, BOOT, IDLE0, POLL_MS                      */
    APB_USB_HOST_O   uint32_t CMD;          /* 0x008: RESTART, XFER_START, XFER_NEXT, XFER_ABORT    */
    APB_USB_HOST_I   uint32_t STATUS;       /* 0x00C: STATE, LINE, FS_DEV, XFER_BUSY, ERR, ...      */
    APB_USB_HOST_IO  uint32_t IRQ_EN;       /* 0x010: interrupt enables                             */
    APB_USB_HOST_IO  uint32_t IRQ_PEND;     /* 0x014: causes, write 1 clears                        */
    APB_USB_HOST_I   uint32_t DEV_ID;       /* 0x018: idVendor, idProduct                           */
    APB_USB_HOST_I   uint32_t DEV_IF;       /* 0x01C: interface number, subclass, protocol, BOOT    */
    APB_USB_HOST_I   uint32_t DEV_EP;       /* 0x020: endpoint, wMaxPacketSize, bInterval, MPS0     */
    APB_USB_HOST_I   uint32_t REPORT_INFO;  /* 0x024: LEN, SEQ                                      */
    APB_USB_HOST_IO  uint32_t XFER;         /* 0x028: LEN, PKT, RESULT (CTRL_EN = 1)                */
    APB_USB_HOST_IO  uint32_t SETUP0;       /* 0x02C: setup bytes 0-3 (CTRL_EN = 1)                 */
    APB_USB_HOST_IO  uint32_t SETUP1;       /* 0x030: setup bytes 4-7 (CTRL_EN = 1)                 */
    APB_USB_HOST_IO  uint32_t DIAG0;        /* 0x034: error counters, a write clears (DIAG_EN = 1)  */
    APB_USB_HOST_I   uint32_t DIAG1;        /* 0x038: bus resets, toggle discards (DIAG_EN = 1)     */
             uint32_t RESERVED0;        /* 0x03C: unmapped, reads 0                             */
    APB_USB_HOST_I   uint32_t REPORT[16];   /* 0x040 .. 0x07C: the report window                    */
    APB_USB_HOST_IO  uint32_t XDATA[16];    /* 0x080 .. 0x0BC: the data-stage window (CTRL_EN = 1)  */
    APB_USB_HOST_IO  uint32_t MDELEG;       /* 0x0C0: privilege gates, Machine mode only            */
             uint32_t RESERVED1[15];    /* 0x0C4 .. 0x0FC: unmapped, read 0                     */
} APB_USB_HOST_TypeDef;

_Static_assert(offsetof(APB_USB_HOST_TypeDef, INFO)        == 0x000, "USB INFO offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, CTRL)        == 0x004, "USB CTRL offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, CMD)         == 0x008, "USB CMD offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, STATUS)      == 0x00C, "USB STATUS offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, IRQ_EN)      == 0x010, "USB IRQ_EN offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, IRQ_PEND)    == 0x014, "USB IRQ_PEND offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, DEV_ID)      == 0x018, "USB DEV_ID offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, DEV_IF)      == 0x01C, "USB DEV_IF offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, DEV_EP)      == 0x020, "USB DEV_EP offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, REPORT_INFO) == 0x024, "USB REPORT_INFO offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, XFER)        == 0x028, "USB XFER offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, SETUP0)      == 0x02C, "USB SETUP0 offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, SETUP1)      == 0x030, "USB SETUP1 offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, DIAG0)       == 0x034, "USB DIAG0 offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, DIAG1)       == 0x038, "USB DIAG1 offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, REPORT)      == 0x040, "USB REPORT offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, XDATA)       == 0x080, "USB XDATA offset");
_Static_assert(offsetof(APB_USB_HOST_TypeDef, MDELEG)      == 0x0C0, "USB MDELEG offset");
_Static_assert(sizeof(APB_USB_HOST_TypeDef)                == 0x100, "USB register window size");

/*---------------------------------------------------------------------------
 * Field definitions
 *---------------------------------------------------------------------------*/
#define APB_USB_HOST_FIELD(pos, width)      (((1u << (width)) - 1u) << (pos))

/* INFO */
#define APB_USB_HOST_INFO_FS_EN_Msk         (1u << 0)
#define APB_USB_HOST_INFO_CTRL_EN_Msk       (1u << 1)
#define APB_USB_HOST_INFO_DIAG_EN_Msk       (1u << 2)
#define APB_USB_HOST_INFO_VERSION_Pos       28u
#define APB_USB_HOST_INFO_VERSION_Msk       APB_USB_HOST_FIELD(28u, 4u)
#define APB_USB_HOST_INFO_VERSION_1         1u              /* the register map of this header */

/* CTRL */
#define APB_USB_HOST_CTRL_EN_Msk            (1u << 0)
#define APB_USB_HOST_CTRL_BOOT_Msk          (1u << 1)       /* SET_PROTOCOL(boot) for boot devices */
#define APB_USB_HOST_CTRL_IDLE0_Msk         (1u << 2)       /* SET_IDLE(0)                          */
#define APB_USB_HOST_CTRL_POLL_MS_Pos       8u
#define APB_USB_HOST_CTRL_POLL_MS_Msk       APB_USB_HOST_FIELD(8u, 8u)   /* 0: the endpoint's bInterval */
#define APB_USB_HOST_CTRL_RESET             0x00000006u

/* CMD */
#define APB_USB_HOST_CMD_RESTART            (1u << 0)
#define APB_USB_HOST_CMD_XFER_START         (1u << 1)
#define APB_USB_HOST_CMD_XFER_NEXT          (1u << 2)
#define APB_USB_HOST_CMD_XFER_ABORT         (1u << 3)

/* STATUS */
#define APB_USB_HOST_STATUS_STATE_Pos       0u
#define APB_USB_HOST_STATUS_STATE_Msk       APB_USB_HOST_FIELD(0u, 4u)
#define APB_USB_HOST_STATUS_LINE_Pos        4u
#define APB_USB_HOST_STATUS_LINE_Msk        APB_USB_HOST_FIELD(4u, 2u)   /* {D+, D-} */
#define APB_USB_HOST_STATUS_FS_DEV_Msk      (1u << 6)
#define APB_USB_HOST_STATUS_XFER_BUSY_Msk   (1u << 7)
#define APB_USB_HOST_STATUS_ERR_Pos         8u
#define APB_USB_HOST_STATUS_ERR_Msk         APB_USB_HOST_FIELD(8u, 4u)
#define APB_USB_HOST_STATUS_ATTEMPT_Pos     12u
#define APB_USB_HOST_STATUS_ATTEMPT_Msk     APB_USB_HOST_FIELD(12u, 2u)
#define APB_USB_HOST_STATUS_STEP_Pos        16u
#define APB_USB_HOST_STATUS_STEP_Msk        APB_USB_HOST_FIELD(16u, 4u)

/* STATUS.STATE */
#define APB_USB_HOST_STATE_OFF              0u
#define APB_USB_HOST_STATE_DETACHED         1u
#define APB_USB_HOST_STATE_DEBOUNCE         2u
#define APB_USB_HOST_STATE_RESET            3u
#define APB_USB_HOST_STATE_RECOVERY         4u
#define APB_USB_HOST_STATE_ENUM             5u
#define APB_USB_HOST_STATE_RUN              6u
#define APB_USB_HOST_STATE_BACKOFF          7u
#define APB_USB_HOST_STATE_FAILED           8u
#define APB_USB_HOST_STATE_UNSUPPORTED      9u
#define APB_USB_HOST_STATE_FS_DETECTED      10u

/* STATUS.ERR */
#define APB_USB_HOST_ERR_NONE               0u
#define APB_USB_HOST_ERR_TIMEOUT            1u              /* no response                           */
#define APB_USB_HOST_ERR_CRC                2u              /* CRC, bit stuffing, PID check          */
#define APB_USB_HOST_ERR_UNEXPECTED         3u              /* unexpected PID, too long, bus busy    */
#define APB_USB_HOST_ERR_STALL              4u
#define APB_USB_HOST_ERR_PROGRESS           5u              /* control-request progress timeout      */
#define APB_USB_HOST_ERR_MALFORMED          6u              /* malformed configuration descriptor    */
#define APB_USB_HOST_ERR_HUB                7u
#define APB_USB_HOST_ERR_NO_HID             8u              /* no usable HID interface               */
#define APB_USB_HOST_ERR_MPS                9u              /* bMaxPacketSize0 / wMaxPacketSize       */

/* IRQ_EN / IRQ_PEND */
#define APB_USB_HOST_IRQ_REPORT             (1u << 0)
#define APB_USB_HOST_IRQ_READY              (1u << 1)
#define APB_USB_HOST_IRQ_DETACH             (1u << 2)
#define APB_USB_HOST_IRQ_FAIL               (1u << 3)
#define APB_USB_HOST_IRQ_XFER_PKT           (1u << 4)
#define APB_USB_HOST_IRQ_XFER_DONE          (1u << 5)
#define APB_USB_HOST_IRQ_STATE              (1u << 6)
#define APB_USB_HOST_IRQ_ALL                0x7Fu

/* DEV_ID */
#define APB_USB_HOST_DEV_ID_VID_Pos         0u
#define APB_USB_HOST_DEV_ID_VID_Msk         APB_USB_HOST_FIELD(0u, 16u)
#define APB_USB_HOST_DEV_ID_PID_Pos         16u
#define APB_USB_HOST_DEV_ID_PID_Msk         (0xFFFFu << 16)

/* DEV_IF */
#define APB_USB_HOST_DEV_IF_NUM_Pos         0u
#define APB_USB_HOST_DEV_IF_NUM_Msk         APB_USB_HOST_FIELD(0u, 8u)
#define APB_USB_HOST_DEV_IF_SUBCLASS_Pos    8u
#define APB_USB_HOST_DEV_IF_SUBCLASS_Msk    APB_USB_HOST_FIELD(8u, 8u)
#define APB_USB_HOST_DEV_IF_PROTOCOL_Pos    16u
#define APB_USB_HOST_DEV_IF_PROTOCOL_Msk    APB_USB_HOST_FIELD(16u, 8u)  /* 1 keyboard, 2 mouse */
#define APB_USB_HOST_DEV_IF_BOOT_Msk        (1u << 24)      /* boot protocol set */

/* DEV_EP */
#define APB_USB_HOST_DEV_EP_NUM_Pos         0u
#define APB_USB_HOST_DEV_EP_NUM_Msk         APB_USB_HOST_FIELD(0u, 4u)
#define APB_USB_HOST_DEV_EP_MPS_Pos         4u
#define APB_USB_HOST_DEV_EP_MPS_Msk         APB_USB_HOST_FIELD(4u, 7u)
#define APB_USB_HOST_DEV_EP_INTERVAL_Pos    16u
#define APB_USB_HOST_DEV_EP_INTERVAL_Msk    APB_USB_HOST_FIELD(16u, 8u)
#define APB_USB_HOST_DEV_EP_MPS0_Pos        24u
#define APB_USB_HOST_DEV_EP_MPS0_Msk        APB_USB_HOST_FIELD(24u, 7u)

/* REPORT_INFO */
#define APB_USB_HOST_REPORT_INFO_LEN_Pos    0u
#define APB_USB_HOST_REPORT_INFO_LEN_Msk    APB_USB_HOST_FIELD(0u, 7u)
#define APB_USB_HOST_REPORT_INFO_SEQ_Pos    8u
#define APB_USB_HOST_REPORT_INFO_SEQ_Msk    APB_USB_HOST_FIELD(8u, 8u)

/* XFER */
#define APB_USB_HOST_XFER_LEN_Pos           0u
#define APB_USB_HOST_XFER_LEN_Msk           APB_USB_HOST_FIELD(0u, 7u)
#define APB_USB_HOST_XFER_PKT_Msk           (1u << 8)
#define APB_USB_HOST_XFER_RESULT_Pos        9u
#define APB_USB_HOST_XFER_RESULT_Msk        APB_USB_HOST_FIELD(9u, 3u)

/* XFER.RESULT */
#define APB_USB_HOST_RESULT_OK              0u
#define APB_USB_HOST_RESULT_STALL           1u
#define APB_USB_HOST_RESULT_ERROR           2u
#define APB_USB_HOST_RESULT_ABORTED         3u
#define APB_USB_HOST_RESULT_DETACHED        4u
#define APB_USB_HOST_RESULT_REFUSED         5u

/* DIAG0 / DIAG1 */
#define APB_USB_HOST_DIAG0_TIMEOUT_Pos      0u
#define APB_USB_HOST_DIAG0_TIMEOUT_Msk      APB_USB_HOST_FIELD(0u, 8u)
#define APB_USB_HOST_DIAG0_CRC_Pos          8u
#define APB_USB_HOST_DIAG0_CRC_Msk          APB_USB_HOST_FIELD(8u, 8u)
#define APB_USB_HOST_DIAG0_OTHER_Pos        16u
#define APB_USB_HOST_DIAG0_OTHER_Msk        APB_USB_HOST_FIELD(16u, 8u)
#define APB_USB_HOST_DIAG0_STALL_Pos        24u
#define APB_USB_HOST_DIAG0_STALL_Msk        (0xFFu << 24)
#define APB_USB_HOST_DIAG1_RESETS_Pos       0u
#define APB_USB_HOST_DIAG1_RESETS_Msk       APB_USB_HOST_FIELD(0u, 16u)
#define APB_USB_HOST_DIAG1_TOGGLE_Pos       16u
#define APB_USB_HOST_DIAG1_TOGGLE_Msk       (0xFFFFu << 16)

/* MDELEG */
#define APB_USB_HOST_MDELEG_WR_PRIV_Pos     0u
#define APB_USB_HOST_MDELEG_WR_PRIV_Msk     APB_USB_HOST_FIELD(0u, 2u)
#define APB_USB_HOST_MDELEG_RD_PRIV_Pos     2u
#define APB_USB_HOST_MDELEG_RD_PRIV_Msk     APB_USB_HOST_FIELD(2u, 2u)
#define APB_USB_HOST_MDELEG_RESP_Pos        8u
#define APB_USB_HOST_MDELEG_RESP_Msk        (1u << 8)
#define APB_USB_HOST_MDELEG_RESET           0x0000010Fu     /* default MDELEG_RST: Machine only, PSLVERR on denial */

/* Privilege codes of WR_PRIV / RD_PRIV (2 is reserved and stores 3) */
#define APB_USB_HOST_PRIV_CODE_U            0u
#define APB_USB_HOST_PRIV_CODE_S            1u
#define APB_USB_HOST_PRIV_CODE_M            3u

#endif /* APB_USB_HOST_REGS_H */
