/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_gpio_regs.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * GPIO register map: a structure overlaying the register window and the field
 * position / mask macros (CMSIS naming: APB_GPIO_<REG>_<FIELD>_Pos and _Msk).
 * Bit n of every pin register is pin n; bits above GPIO_NR-1 read 0 and
 * ignore writes. Reference: doc/apb_gpio.md.
 *----------------------------------------------------------------------------*/
#ifndef APB_GPIO_REGS_H
#define APB_GPIO_REGS_H

#include <stddef.h>
#include <stdint.h>

#define APB_GPIO_IO  volatile               /* read-write register */
#define APB_GPIO_I   volatile const         /* read-only register  */
#define APB_GPIO_O   volatile               /* write-only register, reads 0 */

#define APB_GPIO_PIN_NR_MAX  32u
#define APB_GPIO_ALT_NR_MAX  4u

/*---------------------------------------------------------------------------
 * Register structure
 *---------------------------------------------------------------------------*/

/* The register window: 128 bytes at the minimum ADDRW = 7; a wider window
 * only adds unmapped space above 0x7C. */
typedef struct {
    APB_GPIO_I   uint32_t INFO;             /* 0x000: pin mask, bits 0 .. GPIO_NR-1 set   */
    APB_GPIO_IO  uint32_t IN_EN;            /* 0x004: input enable, the pin is sampled    */
    APB_GPIO_IO  uint32_t OE;               /* 0x008: output enables, 1 = drive           */
    APB_GPIO_I   uint32_t INPUT;            /* 0x00C: pin values after the input stage    */
    APB_GPIO_IO  uint32_t OUTPUT;           /* 0x010: output values, driven on gpio_o     */
    APB_GPIO_O   uint32_t OUT_SET;          /* 0x014: write 1 sets the OUTPUT bit         */
    APB_GPIO_O   uint32_t OUT_CLR;          /* 0x018: write 1 clears the OUTPUT bit       */
    APB_GPIO_O   uint32_t OUT_TGL;          /* 0x01C: write 1 inverts the OUTPUT bit      */
    APB_GPIO_IO  uint32_t IRQ_EN;           /* 0x020: gates IRQ_PEND onto irq_o           */
    APB_GPIO_IO  uint32_t IRQ_PEND;         /* 0x024: pending, write 1 clears an edge     */
    APB_GPIO_IO  uint32_t WAKE_EN;          /* 0x028: a pin change raises gpio_wake_o     */
    APB_GPIO_I   uint32_t CFG;              /* 0x02C: build parameters                    */
    APB_GPIO_IO  uint32_t IRQ_RISE;         /* 0x030: latch a rising edge                 */
    APB_GPIO_IO  uint32_t IRQ_FALL;         /* 0x034: latch a falling edge                */
    APB_GPIO_IO  uint32_t IRQ_HIGH;         /* 0x038: report a high level                 */
    APB_GPIO_IO  uint32_t IRQ_LOW;          /* 0x03C: report a low level                  */
    APB_GPIO_IO  uint32_t ALT_EN;           /* 0x040: 1 = pin driven by its alt function    */
    APB_GPIO_IO  uint32_t ALT_SEL0;         /* 0x044: alternate function number, bit 0   */
    APB_GPIO_IO  uint32_t ALT_SEL1;         /* 0x048: alternate function number, bit 1   */
    APB_GPIO_I   uint32_t IRQ_STAT;         /* 0x04C: IRQ_PEND & IRQ_EN                   */
    APB_GPIO_O   uint32_t OE_SET;           /* 0x050: write 1 sets the OE bit             */
    APB_GPIO_O   uint32_t OE_CLR;           /* 0x054: write 1 clears the OE bit           */
    APB_GPIO_O   uint32_t IRQ_EN_SET;       /* 0x058: write 1 sets the IRQ_EN bit         */
    APB_GPIO_O   uint32_t IRQ_EN_CLR;       /* 0x05C: write 1 clears the IRQ_EN bit       */
    APB_GPIO_IO  uint32_t MDELEG;           /* 0x060: privilege gates, Machine mode only  */
             uint32_t RESERVED0[7];     /* 0x064 .. 0x07C: unmapped, read 0           */
} APB_GPIO_TypeDef;

_Static_assert(offsetof(APB_GPIO_TypeDef, INFO)     == 0x000, "GPIO INFO offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, IN_EN)    == 0x004, "GPIO IN_EN offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, OE)       == 0x008, "GPIO OE offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, INPUT)    == 0x00C, "GPIO INPUT offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, OUTPUT)   == 0x010, "GPIO OUTPUT offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, OUT_SET)  == 0x014, "GPIO OUT_SET offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, OUT_CLR)  == 0x018, "GPIO OUT_CLR offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, OUT_TGL)  == 0x01C, "GPIO OUT_TGL offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, IRQ_EN)   == 0x020, "GPIO IRQ_EN offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, IRQ_PEND) == 0x024, "GPIO IRQ_PEND offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, WAKE_EN)  == 0x028, "GPIO WAKE_EN offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, CFG)      == 0x02C, "GPIO CFG offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, IRQ_RISE) == 0x030, "GPIO IRQ_RISE offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, IRQ_FALL) == 0x034, "GPIO IRQ_FALL offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, IRQ_HIGH) == 0x038, "GPIO IRQ_HIGH offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, IRQ_LOW)  == 0x03C, "GPIO IRQ_LOW offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, ALT_EN)   == 0x040, "GPIO ALT_EN offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, ALT_SEL0) == 0x044, "GPIO ALT_SEL0 offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, ALT_SEL1) == 0x048, "GPIO ALT_SEL1 offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, IRQ_STAT) == 0x04C, "GPIO IRQ_STAT offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, OE_SET)   == 0x050, "GPIO OE_SET offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, OE_CLR)   == 0x054, "GPIO OE_CLR offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, IRQ_EN_SET) == 0x058, "GPIO IRQ_EN_SET offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, IRQ_EN_CLR) == 0x05C, "GPIO IRQ_EN_CLR offset");
_Static_assert(offsetof(APB_GPIO_TypeDef, MDELEG)   == 0x060, "GPIO MDELEG offset");
_Static_assert(sizeof(APB_GPIO_TypeDef)             == 0x080, "GPIO register window size");

/*---------------------------------------------------------------------------
 * Field definitions
 *---------------------------------------------------------------------------*/
#define APB_GPIO_FIELD(pos, width)          (((1u << (width)) - 1u) << (pos))

/* Pin registers: bit n = pin n */
#define APB_GPIO_PIN_Msk(n)                 (1u << (n))

/* CFG */
#define APB_GPIO_CFG_ALT_NR_Pos             0u
#define APB_GPIO_CFG_ALT_NR_Msk             APB_GPIO_FIELD(0u, 3u)
#define APB_GPIO_CFG_SYNC_EN_Pos            4u
#define APB_GPIO_CFG_SYNC_EN_Msk            (1u << 4)
#define APB_GPIO_CFG_INP_CGATE_EN_Pos       5u
#define APB_GPIO_CFG_INP_CGATE_EN_Msk       (1u << 5)
#define APB_GPIO_CFG_VERSION_Pos            28u
#define APB_GPIO_CFG_VERSION_Msk            APB_GPIO_FIELD(28u, 4u)
#define APB_GPIO_CFG_VERSION_1              1u              /* the register map of this header */

/* MDELEG */
#define APB_GPIO_MDELEG_WR_PRIV_Pos         0u
#define APB_GPIO_MDELEG_WR_PRIV_Msk         APB_GPIO_FIELD(0u, 2u)
#define APB_GPIO_MDELEG_RD_PRIV_Pos         2u
#define APB_GPIO_MDELEG_RD_PRIV_Msk         APB_GPIO_FIELD(2u, 2u)
#define APB_GPIO_MDELEG_RESP_Pos            8u
#define APB_GPIO_MDELEG_RESP_Msk            (1u << 8)
#define APB_GPIO_MDELEG_RESET               0x0000010Fu     /* default MDELEG_RST: Machine only, PSLVERR on denial */

/* Privilege codes of WR_PRIV / RD_PRIV (2 is reserved and stores 3) */
#define APB_GPIO_PRIV_CODE_U                0u
#define APB_GPIO_PRIV_CODE_S                1u
#define APB_GPIO_PRIV_CODE_M                3u

#endif /* APB_GPIO_REGS_H */
