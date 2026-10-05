/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      ahb_periph_example_regs.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * AHB peripheral example register map: a structure overlaying the register
 * window and the field position / mask macros (CMSIS naming:
 * PERIPH_<REG>_<FIELD>_Pos and _Msk). Reference: doc/ahb_periph_example.md.
 *----------------------------------------------------------------------------*/
#ifndef AHB_PERIPH_EXAMPLE_REGS_H
#define AHB_PERIPH_EXAMPLE_REGS_H

#include <stddef.h>
#include <stdint.h>

#define PERIPH_IO  volatile             /* read-write register */
#define PERIPH_I   volatile const       /* read-only register  */

#define PERIPH_OUT_NR  8u               /* REGOUT_00 .. REGOUT_07 */
#define PERIPH_IN_NR   8u               /* REGIN_08  .. REGIN_15  */

/*---------------------------------------------------------------------------
 * Register structure
 *---------------------------------------------------------------------------*/

/* The register window: 128 bytes at the minimum ADDRW = 7; a wider window
 * only adds unmapped space above 0x7C. */
typedef struct {
    PERIPH_IO uint32_t REGOUT[8];       /* 0x000 .. 0x01C: drive register_00_o .. register_07_o */
    PERIPH_I  uint32_t REGIN[8];        /* 0x020 .. 0x03C: read register_08_i .. register_15_i  */
    PERIPH_IO uint32_t MDELEG;          /* 0x040: Machine mode only                            */
              uint32_t RESERVED[15];    /* 0x044 .. 0x07C: unmapped, read 0                    */
} PERIPH_TypeDef;

_Static_assert(offsetof(PERIPH_TypeDef, REGOUT) == 0x000, "PERIPH REGOUT offset");
_Static_assert(offsetof(PERIPH_TypeDef, REGIN)  == 0x020, "PERIPH REGIN offset");
_Static_assert(offsetof(PERIPH_TypeDef, MDELEG) == 0x040, "PERIPH MDELEG offset");
_Static_assert(sizeof(PERIPH_TypeDef)           == 0x080, "PERIPH register window size");

/*---------------------------------------------------------------------------
 * Field definitions
 *---------------------------------------------------------------------------*/
#define PERIPH_FIELD(pos, width)        (((1u << (width)) - 1u) << (pos))

/* MDELEG */
#define PERIPH_MDELEG_WR_PRIV_Pos       0u
#define PERIPH_MDELEG_WR_PRIV_Msk       PERIPH_FIELD(0u, 2u)
#define PERIPH_MDELEG_RD_PRIV_Pos       2u
#define PERIPH_MDELEG_RD_PRIV_Msk       PERIPH_FIELD(2u, 2u)
#define PERIPH_MDELEG_RESP_Pos          8u
#define PERIPH_MDELEG_RESP_Msk          (1u << 8)
#define PERIPH_MDELEG_RESET             0x0000010Fu     /* Machine only, ERROR on denial */

/* Privilege codes of WR_PRIV / RD_PRIV (2 is reserved and stores 3) */
#define PERIPH_PRIV_CODE_U              0u
#define PERIPH_PRIV_CODE_S              1u
#define PERIPH_PRIV_CODE_M              3u

#endif /* AHB_PERIPH_EXAMPLE_REGS_H */
