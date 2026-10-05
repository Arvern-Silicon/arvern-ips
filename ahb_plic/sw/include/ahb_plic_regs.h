/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      ahb_plic_regs.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * PLIC register map: a structure overlaying the implemented part of the 4 MB
 * window (32 contexts) and the field position / mask macros (CMSIS naming:
 * PLIC_<REG>_<FIELD>_Pos and _Msk). Every register is a 32-bit word and must
 * be accessed as one: a byte or halfword access is answered with ERROR.
 * Reference: doc/ahb_plic.md.
 *----------------------------------------------------------------------------*/
#ifndef AHB_PLIC_REGS_H
#define AHB_PLIC_REGS_H

#include <stddef.h>
#include <stdint.h>

#define PLIC_IO  volatile               /* read-write register */
#define PLIC_I   volatile const         /* read-only register  */

/*---------------------------------------------------------------------------
 * Architectural limits (the build parameters stay within these)
 *---------------------------------------------------------------------------*/
#define PLIC_SOURCES_MAX        1023u   /* NUM_SOURCES 1..1023, source 0 reserved */
#define PLIC_HARTS_MAX          16u     /* NUM_HARTS 1..16                        */
#define PLIC_CONTEXTS_MAX       32u     /* 2 * NUM_HARTS with SU_MODE_EN=1        */
#define PLIC_PRIO_BITS_MAX      7u      /* PRIO_BITS 1..7                         */

/*---------------------------------------------------------------------------
 * Register structures
 *---------------------------------------------------------------------------*/

/* Target of context ctx, at 0x200000 + 0x1000 * ctx */
typedef struct {
    PLIC_IO uint32_t THRESHOLD;         /* +0x000 */
    PLIC_IO uint32_t CLAIM;             /* +0x004: read = claim, write = complete */
            uint32_t RESERVED[1022];    /* +0x008 .. +0xFFC: read 0 */
} PLIC_Target_TypeDef;

/* The window up to the last implementable context */
typedef struct {
    PLIC_IO uint32_t PRIORITY[1024];    /* 0x000000: [src], [0] reserved          */
    PLIC_I  uint32_t PENDING[32];       /* 0x001000: bit b of [w] = source 32w+b  */
            uint32_t RESERVED0[992];    /* 0x001080 .. 0x001FFC */
    PLIC_IO uint32_t ENABLE[32][32];    /* 0x002000: [ctx][w], same packing       */
            uint32_t RESERVED1[521216]; /* 0x003000 .. 0x1FFFFC */
    PLIC_Target_TypeDef TARGET[32];     /* 0x200000 .. 0x21FFFC */
} PLIC_TypeDef;

_Static_assert(offsetof(PLIC_Target_TypeDef, THRESHOLD) == 0x000, "PLIC THRESHOLD offset");
_Static_assert(offsetof(PLIC_Target_TypeDef, CLAIM)     == 0x004, "PLIC CLAIM offset");
_Static_assert(sizeof(PLIC_Target_TypeDef)              == 0x1000, "PLIC target stride");
_Static_assert(offsetof(PLIC_TypeDef, PRIORITY)         == 0x000000, "PLIC PRIORITY offset");
_Static_assert(offsetof(PLIC_TypeDef, PENDING)          == 0x001000, "PLIC PENDING offset");
_Static_assert(offsetof(PLIC_TypeDef, ENABLE)           == 0x002000, "PLIC ENABLE offset");
_Static_assert(offsetof(PLIC_TypeDef, ENABLE[1])        == 0x002080, "PLIC ENABLE context stride");
_Static_assert(offsetof(PLIC_TypeDef, TARGET)           == 0x200000, "PLIC TARGET offset");
_Static_assert(offsetof(PLIC_TypeDef, TARGET[1])        == 0x201000, "PLIC TARGET context stride");
_Static_assert(sizeof(PLIC_TypeDef)                     == 0x220000, "PLIC implemented window size");

/*---------------------------------------------------------------------------
 * Field definitions
 *---------------------------------------------------------------------------*/
#define PLIC_FIELD(pos, width)          (((1u << (width)) - 1u) << (pos))

/* PRIORITY[src] and THRESHOLD: PRIO_BITS wide, upper bits RAZ/WI */
#define PLIC_PRIORITY_PRIO_Pos          0u
#define PLIC_PRIORITY_PRIO_Msk          PLIC_FIELD(0u, PLIC_PRIO_BITS_MAX)
#define PLIC_THRESHOLD_PRIO_Pos         0u
#define PLIC_THRESHOLD_PRIO_Msk         PLIC_FIELD(0u, PLIC_PRIO_BITS_MAX)

/* CLAIM: source ID, 0 = none; a completion must be the whole word */
#define PLIC_CLAIM_ID_Pos               0u
#define PLIC_CLAIM_ID_Msk               PLIC_FIELD(0u, 11u)

/* PENDING / ENABLE packing: source s is bit (s % 32) of word (s / 32) */
#define PLIC_SRC_WORD(s)                ((s) >> 5)
#define PLIC_SRC_BIT(s)                 (1u << ((s) & 31u))

#endif /* AHB_PLIC_REGS_H */
