/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      ahb_aclint_regs.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * ACLINT register map: a structure overlaying the 64 KB window (MSWI, MTIMER,
 * SSWI, CLINT-compatible layout) and the field position / mask macros (CMSIS
 * naming: ACLINT_<REG>_<FIELD>_Pos and _Msk). Reference: doc/ahb_aclint.md.
 *
 * Only the first NUM_HARTS entries of each per-hart array are mapped; the rest
 * of each window is RAZ/WI. Access every register with word loads and stores:
 * a sub-word access to an unaligned offset is RAZ/WI, and a sub-word store to
 * an aligned offset commits all 32 bits of the bus.
 *----------------------------------------------------------------------------*/
#ifndef AHB_ACLINT_REGS_H
#define AHB_ACLINT_REGS_H

#include <stddef.h>
#include <stdint.h>

#define ACLINT_IO  volatile             /* read-write register */
#define ACLINT_O   volatile             /* write-only register */

#define ACLINT_HARTS_MAX                16u

/*---------------------------------------------------------------------------
 * Register structures
 *---------------------------------------------------------------------------*/

/* MTIMECMP of one hart, at 0x4000 + 8 * hart */
typedef struct {
    ACLINT_IO uint32_t LO;              /* +0x0: reset 0xFFFFFFFF */
    ACLINT_IO uint32_t HI;              /* +0x4: reset 0xFFFFFFFF */
} ACLINT_Cmp_TypeDef;

/* The whole window */
typedef struct {
    ACLINT_IO uint32_t MSIP[4096];          /* 0x0000 .. 0x3FFC: MSWI, bit 0 = MSIP (level) */
    ACLINT_Cmp_TypeDef MTIMECMP[4095];      /* 0x4000 .. 0xBFF4: MTIMER compare registers   */
    ACLINT_IO uint32_t MTIME_LO;            /* 0xBFF8: a read also snapshots MTIME_HI       */
    ACLINT_IO uint32_t MTIME_HI;            /* 0xBFFC: reads the snapshot of the last MTIME_LO read */
    ACLINT_O  uint32_t SETSSIP[1024];       /* 0xC000 .. 0xCFFC: SSWI, write 1 to pulse; reads 0 */
              uint32_t RESERVED[3072];      /* 0xD000 .. 0xFFFC: RAZ/WI */
} ACLINT_TypeDef;

_Static_assert(offsetof(ACLINT_TypeDef, MSIP)     == 0x0000, "ACLINT MSIP offset");
_Static_assert(offsetof(ACLINT_TypeDef, MTIMECMP) == 0x4000, "ACLINT MTIMECMP offset");
_Static_assert(sizeof(ACLINT_Cmp_TypeDef)         == 0x8,    "ACLINT MTIMECMP stride");
_Static_assert(offsetof(ACLINT_TypeDef, MTIME_LO) == 0xBFF8, "ACLINT MTIME_LO offset");
_Static_assert(offsetof(ACLINT_TypeDef, MTIME_HI) == 0xBFFC, "ACLINT MTIME_HI offset");
_Static_assert(offsetof(ACLINT_TypeDef, SETSSIP)  == 0xC000, "ACLINT SETSSIP offset");
_Static_assert(sizeof(ACLINT_TypeDef)             == 0x10000, "ACLINT window size");

/*---------------------------------------------------------------------------
 * Field definitions
 *---------------------------------------------------------------------------*/

/* MSIP[hart] */
#define ACLINT_MSIP_MSIP_Pos            0u
#define ACLINT_MSIP_MSIP_Msk            (1u << 0)

/* SETSSIP[hart] */
#define ACLINT_SETSSIP_SSIP_Pos         0u
#define ACLINT_SETSSIP_SSIP_Msk         (1u << 0)

/* MTIMECMP disarmed value (reset value of both halves) */
#define ACLINT_MTIMECMP_DISARMED        0xFFFFFFFFFFFFFFFFull

#endif /* AHB_ACLINT_REGS_H */
