/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      ahb_plic.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * PLIC driver: configuration, priorities, enables, thresholds, pending
 * query and claim / complete dispatch.
 *----------------------------------------------------------------------------*/
#include "ahb_plic.h"

static inline bool src_ok(const plic_t *dev, unsigned src)
{
    return src != 0u && src <= dev->num_sources;
}

plic_status_t plic_init(plic_t *dev, const plic_config_t *cfg)
{
    if (!dev || !cfg || !cfg->base)
        return PLIC_ERR_PARAM;
    if (cfg->num_sources == 0u || cfg->num_sources > PLIC_SOURCES_MAX ||
        cfg->num_harts   == 0u || cfg->num_harts   > PLIC_HARTS_MAX   ||
        cfg->prio_bits   == 0u || cfg->prio_bits   > PLIC_PRIO_BITS_MAX)
        return PLIC_ERR_PARAM;

    dev->regs         = (PLIC_TypeDef *) cfg->base;
    dev->num_sources  = cfg->num_sources;
    dev->num_harts    = cfg->num_harts;
    dev->su_mode      = cfg->su_mode;
    dev->num_contexts = (uint8_t) (cfg->su_mode ? 2u * cfg->num_harts : cfg->num_harts);
    dev->prio_max     = (uint8_t) ((1u << cfg->prio_bits) - 1u);
    return PLIC_OK;
}

plic_status_t plic_context(const plic_t *dev, unsigned hart, bool s_mode, unsigned *ctx)
{
    if (!ctx || hart >= dev->num_harts)
        return PLIC_ERR_PARAM;
    if (s_mode && !dev->su_mode)
        return PLIC_ERR_ABSENT;
    *ctx = dev->su_mode ? 2u * hart + (s_mode ? 1u : 0u) : hart;
    return PLIC_OK;
}

plic_status_t plic_context_clear(plic_t *dev, unsigned ctx)
{
    if (ctx >= dev->num_contexts)
        return PLIC_ERR_PARAM;
    unsigned words = PLIC_SRC_WORD(dev->num_sources) + 1u;
    for (unsigned w = 0u; w < words; w++)
        dev->regs->ENABLE[ctx][w] = 0u;
    dev->regs->TARGET[ctx].THRESHOLD = 0u;
    return PLIC_OK;
}

/*---------------------------------------------------------------------------
 * Sources
 *---------------------------------------------------------------------------*/
plic_status_t plic_set_priority(plic_t *dev, unsigned src, unsigned prio)
{
    if (!src_ok(dev, src) || prio > dev->prio_max)
        return PLIC_ERR_PARAM;
    dev->regs->PRIORITY[src] = prio;
    return PLIC_OK;
}

unsigned plic_get_priority(const plic_t *dev, unsigned src)
{
    if (!src_ok(dev, src))
        return 0u;
    return dev->regs->PRIORITY[src] & dev->prio_max;
}

bool plic_is_pending(const plic_t *dev, unsigned src)
{
    if (!src_ok(dev, src))
        return false;
    return (dev->regs->PENDING[PLIC_SRC_WORD(src)] & PLIC_SRC_BIT(src)) != 0u;
}

uint32_t plic_pending_word(const plic_t *dev, unsigned w)
{
    if (w > PLIC_SRC_WORD(dev->num_sources))
        return 0u;
    return dev->regs->PENDING[w];
}

/*---------------------------------------------------------------------------
 * Contexts
 *---------------------------------------------------------------------------*/
plic_status_t plic_enable(plic_t *dev, unsigned ctx, unsigned src)
{
    if (ctx >= dev->num_contexts || !src_ok(dev, src))
        return PLIC_ERR_PARAM;
    volatile uint32_t *en = &dev->regs->ENABLE[ctx][PLIC_SRC_WORD(src)];
    *en = *en | PLIC_SRC_BIT(src);
    return PLIC_OK;
}

plic_status_t plic_disable(plic_t *dev, unsigned ctx, unsigned src)
{
    if (ctx >= dev->num_contexts || !src_ok(dev, src))
        return PLIC_ERR_PARAM;
    volatile uint32_t *en = &dev->regs->ENABLE[ctx][PLIC_SRC_WORD(src)];
    *en = *en & ~PLIC_SRC_BIT(src);
    return PLIC_OK;
}

bool plic_is_enabled(const plic_t *dev, unsigned ctx, unsigned src)
{
    if (ctx >= dev->num_contexts || !src_ok(dev, src))
        return false;
    return (dev->regs->ENABLE[ctx][PLIC_SRC_WORD(src)] & PLIC_SRC_BIT(src)) != 0u;
}

plic_status_t plic_set_threshold(plic_t *dev, unsigned ctx, unsigned threshold)
{
    if (ctx >= dev->num_contexts || threshold > dev->prio_max)
        return PLIC_ERR_PARAM;
    dev->regs->TARGET[ctx].THRESHOLD = threshold;
    return PLIC_OK;
}

unsigned plic_get_threshold(const plic_t *dev, unsigned ctx)
{
    if (ctx >= dev->num_contexts)
        return 0u;
    return dev->regs->TARGET[ctx].THRESHOLD & dev->prio_max;
}

/*---------------------------------------------------------------------------
 * Claim / complete
 *---------------------------------------------------------------------------*/
int32_t plic_dispatch(plic_t *dev, unsigned ctx, plic_handler_t handler, void *arg)
{
    if (ctx >= dev->num_contexts || !handler)
        return PLIC_ERR_PARAM;
    uint32_t id = plic_claim(dev, ctx);
    if (id == 0u)
        return 0;                       /* nothing claimed: nothing to complete */
    handler(id, arg);
    /* Complete after the handler: the device request is down, otherwise the
     * level-triggered gateway re-pends the source on the next edge. */
    (void) plic_complete(dev, ctx, id);
    return (int32_t) id;
}
