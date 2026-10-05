/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      ahb_aclint.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * ACLINT driver API.
 *
 *   aclint_mtime_*    MTIME: read, low word, write
 *   aclint_timer_*    MTIMECMP: absolute / relative deadline, disarm, read back
 *   aclint_delay_*    busy-wait delays on MTIME
 *   aclint_msip_*     MSWI: machine software interrupt per hart
 *   aclint_ssip_*     SSWI: supervisor software interrupt per hart (SU_MODE_EN=1)
 *
 * The driver keeps no global state: every call takes the device handle filled
 * by aclint_init(), and only touches the IP's registers (the interrupt enables
 * and trap handling live in the core's CSR layer).
 *
 * Privilege. With PRIV_CHECK_EN=1 the MSWI and MTIMER windows answer only
 * M-mode; any other access gets a bus ERROR (a resumable NMI on aRVern). Every
 * function is therefore M-mode only, except aclint_ssip_set(), which S-mode may
 * also call.
 *
 * Time base. MTIME counts clk_lf_i edges; its frequency is a platform property
 * passed in the configuration. clk_lf_i must be running: an MTIME_LO read
 * stalls the bus until the timer's view of MTIME is valid, which needs an LF
 * edge (out of reset and after an oscillator-off sleep).
 *----------------------------------------------------------------------------*/
#ifndef AHB_ACLINT_H
#define AHB_ACLINT_H

#include <stdbool.h>
#include <stdint.h>
#include "ahb_aclint_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

/*---------------------------------------------------------------------------
 * Types
 *---------------------------------------------------------------------------*/
typedef enum {
    ACLINT_OK          =  0,
    ACLINT_ERR_PARAM   = -1,    /* argument out of range for this build (hart index, config) */
    ACLINT_ERR_ABSENT  = -2     /* SSWI not built (SU_MODE_EN=0)                  */
} aclint_status_t;

typedef struct {                /* aclint_init() arguments: what the hardware does not report */
    uintptr_t base;             /* window base (0x0200_0000 for the CLINT layout) */
    uint8_t   num_harts;        /* NUM_HARTS parameter, 1-16                      */
    bool      sswi;             /* SU_MODE_EN parameter: SSWI bank built          */
    uint32_t  mtime_hz;         /* MTIME tick rate = clk_lf_i frequency           */
} aclint_config_t;

typedef struct {                /* device handle */
    ACLINT_TypeDef *regs;
    uint8_t         num_harts;
    bool            sswi;
    uint32_t        mtime_hz;
} aclint_t;

/*---------------------------------------------------------------------------
 * Set-up
 *---------------------------------------------------------------------------*/

/* Bind the handle and check the configuration. Touches no register, so it
 * leaves the other harts' deadlines and IPIs alone and is legal in any mode. */
aclint_status_t aclint_init(aclint_t *dev, const aclint_config_t *cfg);

/*---------------------------------------------------------------------------
 * MTIME
 *---------------------------------------------------------------------------*/

/* Low word of MTIME: one load. Enough for intervals below 2^31 ticks with a
 * wrap-safe difference, (uint32_t) (now - then). It also re-targets the HI
 * snapshot, which aclint_mtime_read() tolerates. */
static inline uint32_t aclint_mtime_lo(const aclint_t *dev)
{
    return dev->regs->MTIME_LO;
}

/* 64-bit MTIME, consistent from any context (main code, ISR, another hart):
 * the HI / LO / HI retry loop over the IP's LO-read snapshot of HI. Three loads
 * when nothing intervenes. */
uint64_t aclint_mtime_read(const aclint_t *dev);

/* Load MTIME (64 bits, one atomic load at the counter). Legal, with these
 * constraints:
 *  - The value reaches the counter two to three LF periods after the stores;
 *    MMIO reads return the written value meanwhile, and MTIP follows it at once
 *    (MTIP is not sticky: loading past MTIMECMP raises it, below clears it).
 *  - The two halves merge into one load only if no LF period passes between
 *    the two stores: call it with interrupts masked. Between the two stores
 *    MMIO reads and MTIP see {new HI, current LO}, so MTIP can pulse there.
 *  - csrr time is not ordered against the write. Read back through
 *    aclint_mtime_lo() (an MMIO load) before relying on the Zicntr view.
 *  - A write issued while the LF domain is held in reset (resetn_lf_i) is
 *    discarded after a few LF periods, although it reads back meanwhile. */
void aclint_mtime_write(aclint_t *dev, uint64_t value);

/*---------------------------------------------------------------------------
 * MTIMER compare (MTIP of one hart)
 *---------------------------------------------------------------------------*/

/* Arm the timer of a hart for an absolute MTIME value. Never raises MTIP
 * spuriously on the way (three-store sequence); MTIP follows within one hclk.
 * Calls for the same hart from main code and an ISR must not interleave. */
aclint_status_t aclint_timer_set(aclint_t *dev, unsigned hart, uint64_t deadline);
/* Arm it 'ticks' from now (now = aclint_mtime_read()) */
aclint_status_t aclint_timer_set_rel(aclint_t *dev, unsigned hart, uint64_t ticks);
/* Disarm: MTIMECMP = all-ones (the reset value), which clears MTIP */
aclint_status_t aclint_timer_disable(aclint_t *dev, unsigned hart);
/* Read MTIMECMP back, as last written */
aclint_status_t aclint_timer_get(const aclint_t *dev, unsigned hart, uint64_t *deadline);
/* True when MTIME >= MTIMECMP for the hart (the MTIP level the IP drives);
 * false for an out-of-range hart */
bool            aclint_timer_expired(const aclint_t *dev, unsigned hart);

/*---------------------------------------------------------------------------
 * Delays (busy wait on MTIME; resolution one MTIME tick)
 *---------------------------------------------------------------------------*/

/* Wait at least 'ticks' full MTIME periods */
void            aclint_delay_ticks(const aclint_t *dev, uint64_t ticks);
/* Wait at least 'us' / 'ms' (rounded up to whole ticks); PARAM if mtime_hz is 0 */
aclint_status_t aclint_delay_us(const aclint_t *dev, uint32_t us);
aclint_status_t aclint_delay_ms(const aclint_t *dev, uint32_t ms);
/* Duration to ticks, rounded up */
uint64_t        aclint_us_to_ticks(const aclint_t *dev, uint32_t us);
uint64_t        aclint_ms_to_ticks(const aclint_t *dev, uint32_t ms);

/*---------------------------------------------------------------------------
 * Software interrupts
 *---------------------------------------------------------------------------*/

/* MSWI: raise / clear the machine software interrupt of a hart (a level, held
 * until cleared), and read it */
static inline aclint_status_t aclint_msip_set(aclint_t *dev, unsigned hart)
{
    if (hart >= dev->num_harts)
        return ACLINT_ERR_PARAM;
    dev->regs->MSIP[hart] = ACLINT_MSIP_MSIP_Msk;
    return ACLINT_OK;
}

static inline aclint_status_t aclint_msip_clear(aclint_t *dev, unsigned hart)
{
    if (hart >= dev->num_harts)
        return ACLINT_ERR_PARAM;
    dev->regs->MSIP[hart] = 0u;
    return ACLINT_OK;
}

/* False for an out-of-range hart */
static inline bool aclint_msip_pending(const aclint_t *dev, unsigned hart)
{
    return hart < dev->num_harts && (dev->regs->MSIP[hart] & ACLINT_MSIP_MSIP_Msk) != 0u;
}

/* SSWI: set sip.SSIP of a hart (an edge; M or S mode). There is no clear and
 * no pending read here: the receiving hart clears its own sip.SSIP, and
 * SETSSIP reads 0. */
static inline aclint_status_t aclint_ssip_set(aclint_t *dev, unsigned hart)
{
    if (!dev->sswi)
        return ACLINT_ERR_ABSENT;
    if (hart >= dev->num_harts)
        return ACLINT_ERR_PARAM;
    dev->regs->SETSSIP[hart] = ACLINT_SETSSIP_SSIP_Msk;
    return ACLINT_OK;
}

#ifdef __cplusplus
}
#endif

#endif /* AHB_ACLINT_H */
