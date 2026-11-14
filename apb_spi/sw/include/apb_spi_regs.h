/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_spi_regs.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * SPI controller register map: a structure overlaying the register window and
 * the field position / mask macros (CMSIS naming: APB_SPI_<REG>_<FIELD>_Pos
 * and _Msk). Reference: doc/apb_spi.md.
 *----------------------------------------------------------------------------*/
#ifndef APB_SPI_REGS_H
#define APB_SPI_REGS_H

#include <stddef.h>
#include <stdint.h>

#define APB_SPI_IO  volatile                /* read-write register */
#define APB_SPI_I   volatile const          /* read-only register  */
#define APB_SPI_O   volatile                /* write-only register, reads 0 */

#define APB_SPI_CS_NR_MAX  8u

/*---------------------------------------------------------------------------
 * Register structure
 *---------------------------------------------------------------------------*/

/* The register window: 128 bytes at the minimum ADDRW = 7; a wider window
 * only adds unmapped space above 0x7C. */
typedef struct {
    APB_SPI_I    uint32_t CFG;              /* 0x000: build parameters                         */
    APB_SPI_IO   uint32_t CTRL;             /* 0x004: control                                  */
    APB_SPI_O    uint32_t CTRL_SET;         /* 0x008: write 1 sets the CTRL bit                */
    APB_SPI_O    uint32_t CTRL_CLR;         /* 0x00C: write 1 clears the CTRL bit              */
    APB_SPI_IO   uint32_t CLKDIV;           /* 0x010: DIV (HALF - 1), RX_DLY                   */
    APB_SPI_IO   uint32_t CSCFG;            /* 0x014: CSPOL, SETUP / HOLD / INACT - 1          */
    APB_SPI_IO   uint32_t XFER;             /* 0x018: attributes of the next pushed entry      */
    APB_SPI_I    uint32_t STATUS;           /* 0x01C: FIFO levels, CS_ACTIVE, STALL, IDLE, BUSY */
    APB_SPI_IO   uint32_t THRESH;           /* 0x020: TX_THR, RX_THR                           */
    APB_SPI_IO   uint32_t IRQ_EN;           /* 0x024: interrupt enables                        */
    APB_SPI_O    uint32_t IRQ_EN_SET;       /* 0x028: write 1 sets the IRQ_EN bit              */
    APB_SPI_O    uint32_t IRQ_EN_CLR;       /* 0x02C: write 1 clears the IRQ_EN bit            */
    APB_SPI_IO   uint32_t IRQ_PEND;         /* 0x030: causes, write 1 clears a sticky one      */
    APB_SPI_O    uint32_t TXDATA;           /* 0x034: whole-word write pushes {XFER, data}     */
    APB_SPI_I    uint32_t RXDATA;           /* 0x038: read pops the receive FIFO               */
    APB_SPI_O    uint32_t CMD;              /* 0x03C: TX_FLUSH, RX_FLUSH, ABORT                */
             uint32_t RESERVED0[8];     /* 0x040 .. 0x05C: unmapped, read 0                */
    APB_SPI_IO   uint32_t MDELEG;           /* 0x060: privilege gates, Machine mode only       */
             uint32_t RESERVED1[7];     /* 0x064 .. 0x07C: unmapped, read 0                */
} APB_SPI_TypeDef;

_Static_assert(offsetof(APB_SPI_TypeDef, CFG)        == 0x000, "SPI CFG offset");
_Static_assert(offsetof(APB_SPI_TypeDef, CTRL)       == 0x004, "SPI CTRL offset");
_Static_assert(offsetof(APB_SPI_TypeDef, CTRL_SET)   == 0x008, "SPI CTRL_SET offset");
_Static_assert(offsetof(APB_SPI_TypeDef, CTRL_CLR)   == 0x00C, "SPI CTRL_CLR offset");
_Static_assert(offsetof(APB_SPI_TypeDef, CLKDIV)     == 0x010, "SPI CLKDIV offset");
_Static_assert(offsetof(APB_SPI_TypeDef, CSCFG)      == 0x014, "SPI CSCFG offset");
_Static_assert(offsetof(APB_SPI_TypeDef, XFER)       == 0x018, "SPI XFER offset");
_Static_assert(offsetof(APB_SPI_TypeDef, STATUS)     == 0x01C, "SPI STATUS offset");
_Static_assert(offsetof(APB_SPI_TypeDef, THRESH)     == 0x020, "SPI THRESH offset");
_Static_assert(offsetof(APB_SPI_TypeDef, IRQ_EN)     == 0x024, "SPI IRQ_EN offset");
_Static_assert(offsetof(APB_SPI_TypeDef, IRQ_EN_SET) == 0x028, "SPI IRQ_EN_SET offset");
_Static_assert(offsetof(APB_SPI_TypeDef, IRQ_EN_CLR) == 0x02C, "SPI IRQ_EN_CLR offset");
_Static_assert(offsetof(APB_SPI_TypeDef, IRQ_PEND)   == 0x030, "SPI IRQ_PEND offset");
_Static_assert(offsetof(APB_SPI_TypeDef, TXDATA)     == 0x034, "SPI TXDATA offset");
_Static_assert(offsetof(APB_SPI_TypeDef, RXDATA)     == 0x038, "SPI RXDATA offset");
_Static_assert(offsetof(APB_SPI_TypeDef, CMD)        == 0x03C, "SPI CMD offset");
_Static_assert(offsetof(APB_SPI_TypeDef, MDELEG)     == 0x060, "SPI MDELEG offset");
_Static_assert(sizeof(APB_SPI_TypeDef)               == 0x080, "SPI register window size");

/*---------------------------------------------------------------------------
 * Field definitions
 *---------------------------------------------------------------------------*/
#define APB_SPI_FIELD(pos, width)           (((1u << (width)) - 1u) << (pos))

/* CFG */
#define APB_SPI_CFG_TX_FIFO_AW_Pos          0u
#define APB_SPI_CFG_TX_FIFO_AW_Msk          APB_SPI_FIELD(0u, 4u)
#define APB_SPI_CFG_RX_FIFO_AW_Pos          4u
#define APB_SPI_CFG_RX_FIFO_AW_Msk          APB_SPI_FIELD(4u, 4u)
#define APB_SPI_CFG_CS_NR_M1_Pos            8u
#define APB_SPI_CFG_CS_NR_M1_Msk            APB_SPI_FIELD(8u, 3u)
#define APB_SPI_CFG_LANES_Pos               12u
#define APB_SPI_CFG_LANES_Msk               APB_SPI_FIELD(12u, 2u)   /* 0 single, 1 dual, 2 quad */
#define APB_SPI_CFG_RX_EN_Pos               14u
#define APB_SPI_CFG_RX_EN_Msk               (1u << 14)
#define APB_SPI_CFG_POLL_EN_Pos             15u
#define APB_SPI_CFG_POLL_EN_Msk             (1u << 15)
#define APB_SPI_CFG_DBG_Pos                 16u
#define APB_SPI_CFG_DBG_Msk                 (1u << 16)
#define APB_SPI_CFG_VERSION_Pos             28u
#define APB_SPI_CFG_VERSION_Msk             APB_SPI_FIELD(28u, 4u)
#define APB_SPI_CFG_VERSION_1               1u              /* the register map of this header */

/* CTRL (and CTRL_SET / CTRL_CLR) */
#define APB_SPI_CTRL_EN_Msk                 (1u << 0)
#define APB_SPI_CTRL_CPOL_Msk               (1u << 1)
#define APB_SPI_CTRL_CPHA_Msk               (1u << 2)
#define APB_SPI_CTRL_LSB_FIRST_Msk          (1u << 3)
#define APB_SPI_CTRL_TX_IDLE_Pos            4u
#define APB_SPI_CTRL_TX_IDLE_Msk            APB_SPI_FIELD(4u, 2u)
#define APB_SPI_CTRL_TX_IDLE_LOW            0u              /* IO0 driven low with no transmit frame  */
#define APB_SPI_CTRL_TX_IDLE_HIGH           1u              /* ... driven high (the SD fill, 0xFF)     */
#define APB_SPI_CTRL_TX_IDLE_REL            2u              /* ... released (3-wire devices)           */
#define APB_SPI_CTRL_RX_IO0_Msk             (1u << 6)
#define APB_SPI_CTRL_IO23_REL_Msk           (1u << 7)
#define APB_SPI_CTRL_LOOPBACK_Msk           (1u << 8)
#define APB_SPI_CTRL_DBG_POP_Msk            (1u << 9)
#define APB_SPI_CTRL_BSWAP_Msk              (1u << 10)
#define APB_SPI_CTRL_RESET                  0x00000010u

/* CLKDIV */
#define APB_SPI_CLKDIV_DIV_Pos              0u
#define APB_SPI_CLKDIV_DIV_Msk              APB_SPI_FIELD(0u, 12u)   /* HALF - 1 */
#define APB_SPI_CLKDIV_RX_DLY_Pos           16u
#define APB_SPI_CLKDIV_RX_DLY_Msk           APB_SPI_FIELD(16u, 4u)
#define APB_SPI_HALF_MAX                    4096u
#define APB_SPI_RX_DLY_MAX                  15u

/* CSCFG */
#define APB_SPI_CSCFG_CSPOL_Pos             0u
#define APB_SPI_CSCFG_CSPOL_Msk             APB_SPI_FIELD(0u, 8u)
#define APB_SPI_CSCFG_SETUP_Pos             8u
#define APB_SPI_CSCFG_SETUP_Msk             APB_SPI_FIELD(8u, 4u)    /* SETUP - 1, half-periods */
#define APB_SPI_CSCFG_HOLD_Pos              12u
#define APB_SPI_CSCFG_HOLD_Msk              APB_SPI_FIELD(12u, 4u)
#define APB_SPI_CSCFG_INACT_Pos             16u
#define APB_SPI_CSCFG_INACT_Msk             APB_SPI_FIELD(16u, 4u)

/* XFER (the attribute word of an entry) */
#define APB_SPI_XFER_BITS_Pos               0u
#define APB_SPI_XFER_BITS_Msk               APB_SPI_FIELD(0u, 5u)    /* frame length - 1 */
#define APB_SPI_XFER_LANES_Pos              5u
#define APB_SPI_XFER_LANES_Msk              APB_SPI_FIELD(5u, 2u)    /* 0 single, 1 dual, 2 quad */
#define APB_SPI_XFER_KIND_Pos               8u
#define APB_SPI_XFER_KIND_Msk               APB_SPI_FIELD(8u, 2u)
#define APB_SPI_KIND_TX                     0u
#define APB_SPI_KIND_RX                     1u
#define APB_SPI_KIND_DUMMY                  2u
#define APB_SPI_KIND_POLL                   3u
#define APB_SPI_XFER_CAPT_Msk               (1u << 10)
#define APB_SPI_XFER_CS_HOLD_Msk            (1u << 11)
#define APB_SPI_XFER_CS_NONE_Msk            (1u << 12)
#define APB_SPI_XFER_CS_SEL_Pos             13u
#define APB_SPI_XFER_CS_SEL_Msk             APB_SPI_FIELD(13u, 3u)

/* POLL payload: frame count - 1, value, mask (compare on the frame's low byte) */
#define APB_SPI_POLL_COUNT_Pos              0u
#define APB_SPI_POLL_COUNT_Msk              APB_SPI_FIELD(0u, 16u)
#define APB_SPI_POLL_VALUE_Pos              16u
#define APB_SPI_POLL_VALUE_Msk              APB_SPI_FIELD(16u, 8u)
#define APB_SPI_POLL_MASK_Pos               24u
#define APB_SPI_POLL_MASK_Msk               APB_SPI_FIELD(24u, 8u)

/* STATUS */
#define APB_SPI_STATUS_TX_LEVEL_Pos         0u
#define APB_SPI_STATUS_TX_LEVEL_Msk         APB_SPI_FIELD(0u, 9u)
#define APB_SPI_STATUS_RX_LEVEL_Pos         16u
#define APB_SPI_STATUS_RX_LEVEL_Msk         APB_SPI_FIELD(16u, 9u)
#define APB_SPI_STATUS_CS_ACTIVE_Msk        (1u << 28)
#define APB_SPI_STATUS_STALL_Msk            (1u << 29)
#define APB_SPI_STATUS_IDLE_Msk             (1u << 30)
#define APB_SPI_STATUS_BUSY_Msk             (1u << 31)

/* THRESH */
#define APB_SPI_THRESH_TX_Pos               0u
#define APB_SPI_THRESH_TX_Msk               APB_SPI_FIELD(0u, 9u)
#define APB_SPI_THRESH_RX_Pos               16u
#define APB_SPI_THRESH_RX_Msk               APB_SPI_FIELD(16u, 9u)

/* IRQ_EN / IRQ_PEND */
#define APB_SPI_IRQ_TX_LOW                  (1u << 0)       /* level: transmit level <= TX_THR       */
#define APB_SPI_IRQ_RX_HIGH                 (1u << 1)       /* level: receive level >= RX_THR >= 1   */
#define APB_SPI_IRQ_DONE                    (1u << 2)       /* sticky: STATUS.IDLE rose              */
#define APB_SPI_IRQ_TX_OVF                  (1u << 3)       /* sticky: entry written to a full FIFO  */
#define APB_SPI_IRQ_RX_UDF                  (1u << 4)       /* sticky: RXDATA read while empty       */
#define APB_SPI_IRQ_XFER_ERR                (1u << 5)       /* sticky: entry refused (illegal XFER)  */
#define APB_SPI_IRQ_POLL_TO                 (1u << 6)       /* sticky: POLL ran out of frames        */
#define APB_SPI_IRQ_STICKY                  0x7Cu

/* CMD */
#define APB_SPI_CMD_TX_FLUSH                (1u << 0)
#define APB_SPI_CMD_RX_FLUSH                (1u << 1)
#define APB_SPI_CMD_ABORT                   (1u << 2)

/* MDELEG */
#define APB_SPI_MDELEG_WR_PRIV_Pos          0u
#define APB_SPI_MDELEG_WR_PRIV_Msk          APB_SPI_FIELD(0u, 2u)
#define APB_SPI_MDELEG_RD_PRIV_Pos          2u
#define APB_SPI_MDELEG_RD_PRIV_Msk          APB_SPI_FIELD(2u, 2u)
#define APB_SPI_MDELEG_RESP_Pos             8u
#define APB_SPI_MDELEG_RESP_Msk             (1u << 8)
#define APB_SPI_MDELEG_RESET                0x0000010Fu     /* default MDELEG_RST: Machine only, PSLVERR on denial */

/* Privilege codes of WR_PRIV / RD_PRIV (2 is reserved and stores 3) */
#define APB_SPI_PRIV_CODE_U                 0u
#define APB_SPI_PRIV_CODE_S                 1u
#define APB_SPI_PRIV_CODE_M                 3u

#endif /* APB_SPI_REGS_H */
