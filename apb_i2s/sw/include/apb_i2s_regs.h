/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_i2s_regs.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * I2S register map: a structure overlaying the register window and the field
 * position / mask macros (CMSIS naming: APB_I2S_<REG>_<FIELD>_Pos and _Msk).
 * Reference: doc/apb_i2s.md.
 *----------------------------------------------------------------------------*/
#ifndef APB_I2S_REGS_H
#define APB_I2S_REGS_H

#include <stddef.h>
#include <stdint.h>

#define APB_I2S_IO  volatile                /* read-write register */
#define APB_I2S_I   volatile const          /* read-only register  */
#define APB_I2S_O   volatile                /* write-only register, reads 0 */

/*---------------------------------------------------------------------------
 * Register structure
 *---------------------------------------------------------------------------*/

/* The register window: 128 bytes at the minimum ADDRW = 7; a wider window
 * only adds unmapped space above 0x7C. */
typedef struct {
    APB_I2S_I   uint32_t INFO;              /* 0x000: build parameters                    */
    APB_I2S_IO  uint32_t CTRL;              /* 0x004: control                             */
    APB_I2S_IO  uint32_t CLKDIV;            /* 0x008: MDIV-1, RATIO, RX_DLY               */
    APB_I2S_I   uint32_t STATUS;            /* 0x00C: FIFO levels, active, running        */
    APB_I2S_IO  uint32_t THRESH;            /* 0x010: TX_THR, RX_THR                      */
    APB_I2S_IO  uint32_t IRQ_EN;            /* 0x014: interrupt enables                   */
    APB_I2S_IO  uint32_t IRQ_PEND;          /* 0x018: causes: levels RO, sticky W1C       */
    APB_I2S_O   uint32_t TXDATA;            /* 0x01C: push (whole words only)             */
    APB_I2S_I   uint32_t RXDATA;            /* 0x020: pop (0 when empty)                  */
    APB_I2S_O   uint32_t CMD;               /* 0x024: write 1 flushes                     */
    APB_I2S_IO  uint32_t FORMAT;            /* 0x028: frame format                        */
             uint32_t RESERVED0[5];     /* 0x02C .. 0x03C: unmapped, read 0           */
    APB_I2S_IO  uint32_t MDELEG;            /* 0x040: privilege gates, Machine mode only  */
             uint32_t RESERVED1[15];    /* 0x044 .. 0x07C: unmapped, read 0           */
} APB_I2S_TypeDef;

_Static_assert(offsetof(APB_I2S_TypeDef, INFO)     == 0x000, "I2S INFO offset");
_Static_assert(offsetof(APB_I2S_TypeDef, CTRL)     == 0x004, "I2S CTRL offset");
_Static_assert(offsetof(APB_I2S_TypeDef, CLKDIV)   == 0x008, "I2S CLKDIV offset");
_Static_assert(offsetof(APB_I2S_TypeDef, STATUS)   == 0x00C, "I2S STATUS offset");
_Static_assert(offsetof(APB_I2S_TypeDef, THRESH)   == 0x010, "I2S THRESH offset");
_Static_assert(offsetof(APB_I2S_TypeDef, IRQ_EN)   == 0x014, "I2S IRQ_EN offset");
_Static_assert(offsetof(APB_I2S_TypeDef, IRQ_PEND) == 0x018, "I2S IRQ_PEND offset");
_Static_assert(offsetof(APB_I2S_TypeDef, TXDATA)   == 0x01C, "I2S TXDATA offset");
_Static_assert(offsetof(APB_I2S_TypeDef, RXDATA)   == 0x020, "I2S RXDATA offset");
_Static_assert(offsetof(APB_I2S_TypeDef, CMD)      == 0x024, "I2S CMD offset");
_Static_assert(offsetof(APB_I2S_TypeDef, FORMAT)   == 0x028, "I2S FORMAT offset");
_Static_assert(offsetof(APB_I2S_TypeDef, MDELEG)   == 0x040, "I2S MDELEG offset");
_Static_assert(sizeof(APB_I2S_TypeDef)             == 0x080, "I2S register window size");

/*---------------------------------------------------------------------------
 * Fields
 *---------------------------------------------------------------------------*/

/* INFO */
#define APB_I2S_INFO_TX_FIFO_AW_Pos   0u
#define APB_I2S_INFO_TX_FIFO_AW_Msk   (0xFu << APB_I2S_INFO_TX_FIFO_AW_Pos)
#define APB_I2S_INFO_RX_FIFO_AW_Pos   4u
#define APB_I2S_INFO_RX_FIFO_AW_Msk   (0xFu << APB_I2S_INFO_RX_FIFO_AW_Pos)
#define APB_I2S_INFO_TX_EN_Pos        8u
#define APB_I2S_INFO_TX_EN_Msk        (1u << APB_I2S_INFO_TX_EN_Pos)
#define APB_I2S_INFO_RX_EN_Pos        9u
#define APB_I2S_INFO_RX_EN_Msk        (1u << APB_I2S_INFO_RX_EN_Pos)
#define APB_I2S_INFO_DBG_Pos          10u
#define APB_I2S_INFO_DBG_Msk          (1u << APB_I2S_INFO_DBG_Pos)
#define APB_I2S_INFO_VERSION_Pos      28u
#define APB_I2S_INFO_VERSION_Msk      (0xFu << APB_I2S_INFO_VERSION_Pos)
#define APB_I2S_INFO_VERSION_1        1u

/* CTRL */
#define APB_I2S_CTRL_EN_Msk           (1u << 0)
#define APB_I2S_CTRL_TX_ON_Msk        (1u << 1)
#define APB_I2S_CTRL_RX_ON_Msk        (1u << 2)
#define APB_I2S_CTRL_MCLK_EN_Msk      (1u << 3)
#define APB_I2S_CTRL_TX_MONO_Msk      (1u << 5)
#define APB_I2S_CTRL_RX_MONO_Msk      (1u << 6)
#define APB_I2S_CTRL_RX_MONO_SEL_Pos  8u
#define APB_I2S_CTRL_RX_MONO_SEL_Msk  (3u << APB_I2S_CTRL_RX_MONO_SEL_Pos)
#define APB_I2S_CTRL_LOOPBACK_Msk     (1u << 12)
#define APB_I2S_CTRL_DBG_POP_Msk      (1u << 13)

/* CLKDIV */
#define APB_I2S_CLKDIV_MDIV_Pos       0u            /* MDIV - 1 */
#define APB_I2S_CLKDIV_MDIV_Msk       (0xFFu << APB_I2S_CLKDIV_MDIV_Pos)
#define APB_I2S_CLKDIV_RATIO_Pos      8u
#define APB_I2S_CLKDIV_RATIO_Msk      (7u << APB_I2S_CLKDIV_RATIO_Pos)
#define APB_I2S_CLKDIV_RX_DLY_Pos     12u
#define APB_I2S_CLKDIV_RX_DLY_Msk     (0xFu << APB_I2S_CLKDIV_RX_DLY_Pos)

/* STATUS */
#define APB_I2S_STATUS_TX_LEVEL_Pos   0u
#define APB_I2S_STATUS_TX_LEVEL_Msk   (0x1FFu << APB_I2S_STATUS_TX_LEVEL_Pos)
#define APB_I2S_STATUS_RX_LEVEL_Pos   16u
#define APB_I2S_STATUS_RX_LEVEL_Msk   (0x1FFu << APB_I2S_STATUS_RX_LEVEL_Pos)
#define APB_I2S_STATUS_RX_ACTIVE_Msk  (1u << 29)
#define APB_I2S_STATUS_TX_ACTIVE_Msk  (1u << 30)
#define APB_I2S_STATUS_RUNNING_Msk    (1u << 31)

/* THRESH */
#define APB_I2S_THRESH_TX_THR_Pos     0u
#define APB_I2S_THRESH_TX_THR_Msk     (0x1FFu << APB_I2S_THRESH_TX_THR_Pos)
#define APB_I2S_THRESH_RX_THR_Pos     16u
#define APB_I2S_THRESH_RX_THR_Msk     (0x1FFu << APB_I2S_THRESH_RX_THR_Pos)

/* IRQ_EN / IRQ_PEND */
#define APB_I2S_IRQ_TX_LOW            (1u << 0)     /* level: TX level <= TX_THR       */
#define APB_I2S_IRQ_RX_HIGH           (1u << 1)     /* level: RX level >= RX_THR > 0   */
#define APB_I2S_IRQ_TX_UNDER          (1u << 2)     /* sticky: a frame of zeros sent   */
#define APB_I2S_IRQ_RX_OVER           (1u << 3)     /* sticky: a received word dropped */
#define APB_I2S_IRQ_TX_OVF            (1u << 4)     /* sticky: TXDATA write when full  */
#define APB_I2S_IRQ_RX_UDF            (1u << 5)     /* sticky: RXDATA read when empty  */
#define APB_I2S_IRQ_STICKY            (0x3Cu)

/* CMD */
#define APB_I2S_CMD_TX_FLUSH          (1u << 0)
#define APB_I2S_CMD_RX_FLUSH          (1u << 1)

/* FORMAT */
#define APB_I2S_FORMAT_BCLK_INV       (1u << 0)
#define APB_I2S_FORMAT_DELAY          (1u << 1)
#define APB_I2S_FORMAT_RJUST          (1u << 2)
#define APB_I2S_FORMAT_LRCK_INV       (1u << 3)
#define APB_I2S_FORMAT_FSYNC          (1u << 4)
#define APB_I2S_FORMAT_SLOT16         (1u << 5)

/* MDELEG */
#define APB_I2S_MDELEG_WR_PRIV_Pos    0u
#define APB_I2S_MDELEG_WR_PRIV_Msk    (3u << APB_I2S_MDELEG_WR_PRIV_Pos)
#define APB_I2S_MDELEG_RD_PRIV_Pos    2u
#define APB_I2S_MDELEG_RD_PRIV_Msk    (3u << APB_I2S_MDELEG_RD_PRIV_Pos)
#define APB_I2S_MDELEG_RESP_Pos       8u
#define APB_I2S_MDELEG_RESP_Msk       (1u << APB_I2S_MDELEG_RESP_Pos)
#define APB_I2S_MDELEG_RESET          0x0000010Fu   /* default MDELEG_RST */

#endif /* APB_I2S_REGS_H */
