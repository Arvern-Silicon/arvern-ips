/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      ahb_aclint.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * ACLINT: MTIME access, MTIMECMP programming and busy-wait delays.
 *----------------------------------------------------------------------------*/
#include "ahb_aclint.h"

/* Largest wait handled by one wrap-safe compare on the MTIME low word */
#define ACLINT_DELAY_CHUNK  0x7FFFFFFFu

aclint_status_t aclint_init(aclint_t *dev, const aclint_config_t *cfg)
{
    if (!dev || !cfg || !cfg->base ||
        cfg->num_harts == 0u || cfg->num_harts > ACLINT_HARTS_MAX)
        return ACLINT_ERR_PARAM;

    dev->regs      = (ACLINT_TypeDef *) cfg->base;
    dev->num_harts = cfg->num_harts;
    dev->sswi      = cfg->sswi;
    dev->mtime_hz  = cfg->mtime_hz;
    return ACLINT_OK;
}

/*---------------------------------------------------------------------------
 * MTIME
 *---------------------------------------------------------------------------*/

uint64_t aclint_mtime_read(const aclint_t *dev)
{
    ACLINT_TypeDef *r = dev->regs;
    uint32_t hi, lo, hi2;

    /* The LO read snapshots HI for the next HI read, and the snapshot is shared
     * by all readers: hi == hi2 proves no LO read in between moved it. */
    do {
        hi  = r->MTIME_HI;
        lo  = r->MTIME_LO;
        hi2 = r->MTIME_HI;
    } while (hi != hi2);

    return ((uint64_t) hi2 << 32) | lo;
}

void aclint_mtime_write(aclint_t *dev, uint64_t value)
{
    /* Both halves share one load request; the IP launches it on the first LF
     * tick with no write since the previous one, so back-to-back stores merge. */
    dev->regs->MTIME_HI = (uint32_t) (value >> 32);
    dev->regs->MTIME_LO = (uint32_t) value;
}

/*---------------------------------------------------------------------------
 * MTIMER compare
 *---------------------------------------------------------------------------*/

aclint_status_t aclint_timer_set(aclint_t *dev, unsigned hart, uint64_t deadline)
{
    if (hart >= dev->num_harts)
        return ACLINT_ERR_PARAM;
    ACLINT_Cmp_TypeDef *c = &dev->regs->MTIMECMP[hart];

    /* MTIP compares each half as stored: LO = -1 first keeps every intermediate
     * comparand no smaller than the lesser of the old and new deadlines. */
    c->LO = 0xFFFFFFFFu;
    c->HI = (uint32_t) (deadline >> 32);
    c->LO = (uint32_t) deadline;
    return ACLINT_OK;
}

aclint_status_t aclint_timer_set_rel(aclint_t *dev, unsigned hart, uint64_t ticks)
{
    if (hart >= dev->num_harts)
        return ACLINT_ERR_PARAM;
    uint64_t now      = aclint_mtime_read(dev);
    uint64_t deadline = now + ticks;
    if (deadline < now)
        deadline = ACLINT_MTIMECMP_DISARMED;
    return aclint_timer_set(dev, hart, deadline);
}

aclint_status_t aclint_timer_disable(aclint_t *dev, unsigned hart)
{
    if (hart >= dev->num_harts)
        return ACLINT_ERR_PARAM;
    ACLINT_Cmp_TypeDef *c = &dev->regs->MTIMECMP[hart];

    /* LO first: {old HI, all-ones} is no smaller than the old deadline */
    c->LO = 0xFFFFFFFFu;
    c->HI = 0xFFFFFFFFu;
    return ACLINT_OK;
}

aclint_status_t aclint_timer_get(const aclint_t *dev, unsigned hart, uint64_t *deadline)
{
    if (hart >= dev->num_harts || !deadline)
        return ACLINT_ERR_PARAM;
    const ACLINT_Cmp_TypeDef *c = &dev->regs->MTIMECMP[hart];
    uint32_t lo = c->LO;
    *deadline = ((uint64_t) c->HI << 32) | lo;
    return ACLINT_OK;
}

bool aclint_timer_expired(const aclint_t *dev, unsigned hart)
{
    uint64_t deadline;
    if (aclint_timer_get(dev, hart, &deadline) != ACLINT_OK)
        return false;
    return aclint_mtime_read(dev) >= deadline;
}

/*---------------------------------------------------------------------------
 * Delays
 *---------------------------------------------------------------------------*/

void aclint_delay_ticks(const aclint_t *dev, uint64_t ticks)
{
    if (ticks == 0u)
        return;

    /* One more tick: the wait starts anywhere inside the current period */
    uint64_t left = (ticks == UINT64_MAX) ? ticks : ticks + 1u;
    uint32_t t0   = aclint_mtime_lo(dev);

    while (left) {
        uint32_t chunk = (left > ACLINT_DELAY_CHUNK) ? ACLINT_DELAY_CHUNK : (uint32_t) left;
        while ((uint32_t) (aclint_mtime_lo(dev) - t0) < chunk)
            ;
        t0   += chunk;
        left -= chunk;
    }
}

/* (t * hz) / d rounded up, by shift-subtract: a 64-bit '/' would pull the
 * libgcc divide routine into every image that uses a delay */
static uint64_t ticks_ceil(uint32_t t, uint32_t hz, uint32_t d)
{
    uint64_t n = (uint64_t) t * hz + (d - 1u);
    uint64_t q = 0u;
    uint64_t r = 0u;
    for (int i = 63; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1u);
        if (r >= d) {
            r -= d;
            q |= (uint64_t) 1u << i;
        }
    }
    return q;
}

uint64_t aclint_us_to_ticks(const aclint_t *dev, uint32_t us)
{
    return ticks_ceil(us, dev->mtime_hz, 1000000u);
}

uint64_t aclint_ms_to_ticks(const aclint_t *dev, uint32_t ms)
{
    return ticks_ceil(ms, dev->mtime_hz, 1000u);
}

aclint_status_t aclint_delay_us(const aclint_t *dev, uint32_t us)
{
    if (dev->mtime_hz == 0u)
        return ACLINT_ERR_PARAM;
    aclint_delay_ticks(dev, aclint_us_to_ticks(dev, us));
    return ACLINT_OK;
}

aclint_status_t aclint_delay_ms(const aclint_t *dev, uint32_t ms)
{
    if (dev->mtime_hz == 0u)
        return ACLINT_ERR_PARAM;
    aclint_delay_ticks(dev, aclint_ms_to_ticks(dev, ms));
    return ACLINT_OK;
}
