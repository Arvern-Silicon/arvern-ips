/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      ahb_plic.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * PLIC driver API: source priorities, per-context enables and thresholds,
 * pending query, claim / complete and a dispatch helper.
 *
 * The PLIC reports none of its build parameters: the configuration passed to
 * plic_init() carries them, and every call is bounds-checked against them.
 *
 * Context numbering (the platform assignment, doc/ahb_plic.md):
 *
 *   SU_MODE_EN=1   ctx = 2*hart + s_mode      NUM_CONTEXTS = 2*NUM_HARTS
 *                  even ctx = M-mode of hart ctx/2, odd ctx = its S-mode
 *                  (hart 0: ctx 0 = M, ctx 1 = S; hart 1: ctx 2 = M, ctx 3 = S)
 *   SU_MODE_EN=0   ctx = hart                 NUM_CONTEXTS = NUM_HARTS
 *                  every context is the M-mode context of its hart
 *
 * Context n drives irq_m_external_o / irq_s_external_o of its hart, i.e. that
 * hart's mip.MEIP / mip.SEIP. plic_context() computes the index.
 *
 * The driver keeps no global state and touches only PLIC registers. A call on
 * a register the current privilege may not access (an M-context from S-mode,
 * anything from U-mode) is answered by the bus with ERROR, which the core
 * reports as an NMI, not as a status code.
 *----------------------------------------------------------------------------*/
#ifndef AHB_PLIC_H
#define AHB_PLIC_H

#include <stdbool.h>
#include <stdint.h>
#include "ahb_plic_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

/*---------------------------------------------------------------------------
 * Types
 *---------------------------------------------------------------------------*/
typedef enum {
    PLIC_OK          =  0,
    PLIC_ERR_PARAM   = -1,      /* argument out of range for this build        */
    PLIC_ERR_ABSENT  = -2       /* S-mode context requested with SU_MODE_EN=0  */
} plic_status_t;

typedef struct {                /* plic_init() arguments: the RTL parameters   */
    uintptr_t base;             /* base of the 4 MB window                     */
    uint16_t  num_sources;      /* NUM_SOURCES, 1..1023                        */
    uint8_t   num_harts;        /* NUM_HARTS, 1..16                            */
    uint8_t   prio_bits;        /* PRIO_BITS, 1..7                             */
    bool      su_mode;          /* SU_MODE_EN                                  */
} plic_config_t;

typedef struct {                /* device handle */
    PLIC_TypeDef *regs;
    uint16_t      num_sources;
    uint8_t       num_harts;
    uint8_t       num_contexts; /* 2*num_harts with su_mode, else num_harts    */
    uint8_t       prio_max;     /* 2^PRIO_BITS - 1                             */
    bool          su_mode;
} plic_t;

/* Called by plic_dispatch() with the claimed source ID */
typedef void (*plic_handler_t)(uint32_t src, void *arg);

/*---------------------------------------------------------------------------
 * Set-up
 *---------------------------------------------------------------------------*/

/* Check the configuration and bind the handle. Touches no register: the
 * PLIC is shared by every hart and resets to all-zero (no source enabled,
 * every priority and threshold 0). */
plic_status_t plic_init(plic_t *dev, const plic_config_t *cfg);

/* Context index of (hart, mode); PLIC_ERR_ABSENT for an S-mode context in a
 * build without S-mode contexts. */
plic_status_t plic_context(const plic_t *dev, unsigned hart, bool s_mode, unsigned *ctx);

/* Disable every source for a context and set its threshold to 0. A source
 * claimed on this context and not yet completed stays in service until it is
 * re-enabled and completed. */
plic_status_t plic_context_clear(plic_t *dev, unsigned ctx);

/*---------------------------------------------------------------------------
 * Sources
 *---------------------------------------------------------------------------*/

/* Priority 0 = never interrupts, 1 = lowest, prio_max = highest */
plic_status_t plic_set_priority(plic_t *dev, unsigned src, unsigned prio);
/* 0 for a source out of range */
unsigned      plic_get_priority(const plic_t *dev, unsigned src);

/* Pending bit of a source (false for a source out of range) */
bool          plic_is_pending(const plic_t *dev, unsigned src);
/* Pending word w: bit b = source 32*w + b (0 for a word out of range) */
uint32_t      plic_pending_word(const plic_t *dev, unsigned w);

/*---------------------------------------------------------------------------
 * Contexts
 *---------------------------------------------------------------------------*/

/* Enable bits are read-modify-write on a word shared by 32 sources. Complete
 * a claimed source before disabling it (see plic_complete()). */
plic_status_t plic_enable(plic_t *dev, unsigned ctx, unsigned src);
plic_status_t plic_disable(plic_t *dev, unsigned ctx, unsigned src);
bool          plic_is_enabled(const plic_t *dev, unsigned ctx, unsigned src);

/* Only sources with priority strictly above the threshold notify the
 * context; prio_max masks all. The threshold does not affect a claim. */
plic_status_t plic_set_threshold(plic_t *dev, unsigned ctx, unsigned threshold);
/* 0 for a context out of range */
unsigned      plic_get_threshold(const plic_t *dev, unsigned ctx);

/*---------------------------------------------------------------------------
 * Claim / complete
 *---------------------------------------------------------------------------*/

/* Claim the highest-priority pending and enabled source of the context.
 * Returns its ID, or 0 when nothing qualifies (or ctx is out of range).
 * The read itself clears the pending bit and marks the source in service. */
static inline uint32_t plic_claim(plic_t *dev, unsigned ctx)
{
    if (ctx >= dev->num_contexts)
        return 0u;
    return dev->regs->TARGET[ctx].CLAIM;
}

/* Complete a source claimed on the same context. Give it exactly the ID the
 * claim returned, after the device has dropped its request and while the
 * source is still enabled for this context: the PLIC silently ignores a
 * completion of a source not enabled for the context, which leaves the
 * source in service for good. */
static inline plic_status_t plic_complete(plic_t *dev, unsigned ctx, uint32_t id)
{
    if (ctx >= dev->num_contexts || id == 0u || id > dev->num_sources)
        return PLIC_ERR_PARAM;
    dev->regs->TARGET[ctx].CLAIM = id;
    return PLIC_OK;
}

/* Claim one source, call handler(id, arg), complete the same ID. Returns the
 * ID serviced, 0 when nothing was pending, or PLIC_ERR_PARAM. The handler
 * must clear the device's request before it returns. */
int32_t       plic_dispatch(plic_t *dev, unsigned ctx, plic_handler_t handler, void *arg);

#ifdef __cplusplus
}
#endif

#endif /* AHB_PLIC_H */
