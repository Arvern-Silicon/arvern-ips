/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      ahb_periph_example.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * AHB peripheral example driver API.
 *
 *   periph_init                     bind a handle to one instance
 *   periph_out_* / periph_in_read   register bank accesses (inline)
 *   periph_set_access / _get_access MDELEG privilege gates (Machine mode only)
 *
 * The driver keeps no global state: every call takes the device handle filled
 * by periph_init(). The hardware has no identification register and no
 * parameter visible to software (ADDRW only sizes the window, ASYNC_RST_EN the
 * reset style), so the configuration is the base address alone.
 *
 * Access rights: after reset only Machine mode may access the window. An
 * access below the MDELEG gates is refused at every offset; with RESP = 1 it
 * gets an AHB ERROR, which an aRVern hart takes as a resumable data-bus NMI,
 * with RESP = 0 a write is dropped and a read returns 0.
 *----------------------------------------------------------------------------*/
#ifndef AHB_PERIPH_EXAMPLE_H
#define AHB_PERIPH_EXAMPLE_H

#include <stdbool.h>
#include <stdint.h>
#include "ahb_periph_example_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

/*---------------------------------------------------------------------------
 * Types
 *---------------------------------------------------------------------------*/
typedef enum {
    PERIPH_OK         =  0,
    PERIPH_ERR_PARAM  = -1      /* null pointer, misaligned base or reserved privilege code */
} periph_status_t;

typedef enum {                  /* MDELEG WR_PRIV / RD_PRIV: lowest admitted privilege */
    PERIPH_PRIV_U = PERIPH_PRIV_CODE_U,
    PERIPH_PRIV_S = PERIPH_PRIV_CODE_S,
    PERIPH_PRIV_M = PERIPH_PRIV_CODE_M
} periph_priv_t;

typedef struct {                /* periph_init() arguments */
    uintptr_t base;             /* register window, word aligned              */
} periph_config_t;

typedef struct {                /* device handle */
    PERIPH_TypeDef *regs;
} periph_t;

typedef struct {                /* MDELEG content */
    periph_priv_t wr_priv;      /* lowest privilege admitted for writes       */
    periph_priv_t rd_priv;      /* lowest privilege admitted for reads        */
    bool          error_resp;   /* true: ERROR on a denied access; false: silent drop */
} periph_access_t;

/*---------------------------------------------------------------------------
 * Set-up
 *---------------------------------------------------------------------------*/

/* Bind the handle to the instance at cfg->base. No register is accessed, so
 * the call is valid in any privilege mode. */
periph_status_t periph_init(periph_t *dev, const periph_config_t *cfg);

/*---------------------------------------------------------------------------
 * Privilege gates (MDELEG). Machine mode only: from S or U mode the access
 * is refused whatever the gates say.
 *---------------------------------------------------------------------------*/

/* Program both gates and the denial response in one transfer */
periph_status_t periph_set_access(periph_t *dev, const periph_access_t *access);
void            periph_get_access(const periph_t *dev, periph_access_t *access);

/*---------------------------------------------------------------------------
 * Register bank: n = 0..7, not checked. Byte and half-word stores to REGOUT
 * update only the lanes they address; a store to REGIN is ignored.
 *---------------------------------------------------------------------------*/

/* REGOUT_0n: value driven on register_0n_o */
static inline void periph_out_write(periph_t *dev, unsigned n, uint32_t value)
{
    dev->regs->REGOUT[n] = value;
}

static inline uint32_t periph_out_read(const periph_t *dev, unsigned n)
{
    return dev->regs->REGOUT[n];
}

/* Replace the bits of mask in REGOUT_0n by those of value (read-modify-write,
 * not atomic against another manager or an interrupt handler) */
static inline void periph_out_modify(periph_t *dev, unsigned n, uint32_t mask, uint32_t value)
{
    PERIPH_IO uint32_t *reg = &dev->regs->REGOUT[n];
    *reg = (*reg & ~mask) | (value & mask);
}

/* REGIN_(8+n): register_(8+n)_i as sampled in the data phase of the read */
static inline uint32_t periph_in_read(const periph_t *dev, unsigned n)
{
    return dev->regs->REGIN[n];
}

#ifdef __cplusplus
}
#endif

#endif /* AHB_PERIPH_EXAMPLE_H */
