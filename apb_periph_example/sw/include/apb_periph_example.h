/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_periph_example.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * APB peripheral example driver API.
 *
 *   apb_periph_init                     bind a handle to one instance
 *   apb_periph_out_* / apb_periph_in_read   register bank accesses (inline)
 *   apb_periph_set_access / _get_access MDELEG privilege gates (Machine mode only)
 *
 * The driver keeps no global state: every call takes the device handle filled
 * by apb_periph_init(). The hardware has no identification register and no
 * parameter visible to software (ADDRW only sizes the window, ASYNC_RST_EN the
 * reset style, MDELEG_RST only the value MDELEG holds after reset), so the
 * configuration is the base address alone.
 *
 * Access rights: with the default MDELEG_RST, only Machine mode may access the
 * window after reset; a build may reset it open. An
 * access below the MDELEG gates is refused at every offset; with RESP = 1 it
 * gets PSLVERR, which ahb_apb_bridge turns into an AHB ERROR and an aRVern
 * hart takes as a resumable data-bus NMI; with RESP = 0 a write is dropped and a read returns 0.
 *----------------------------------------------------------------------------*/
#ifndef APB_PERIPH_EXAMPLE_H
#define APB_PERIPH_EXAMPLE_H

#include <stdbool.h>
#include <stdint.h>
#include "apb_periph_example_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

/*---------------------------------------------------------------------------
 * Types
 *---------------------------------------------------------------------------*/
typedef enum {
    APB_PERIPH_OK         =  0,
    APB_PERIPH_ERR_PARAM  = -1  /* null pointer, misaligned base or reserved privilege code */
} apb_periph_status_t;

typedef enum {                  /* MDELEG WR_PRIV / RD_PRIV: lowest admitted privilege */
    APB_PERIPH_PRIV_U = APB_PERIPH_PRIV_CODE_U,
    APB_PERIPH_PRIV_S = APB_PERIPH_PRIV_CODE_S,
    APB_PERIPH_PRIV_M = APB_PERIPH_PRIV_CODE_M
} apb_periph_priv_t;

typedef struct {                /* apb_periph_init() arguments */
    uintptr_t base;             /* register window, word aligned              */
} apb_periph_config_t;

typedef struct {                /* device handle */
    APB_PERIPH_TypeDef *regs;
} apb_periph_t;

typedef struct {                /* MDELEG content */
    apb_periph_priv_t wr_priv;     /* lowest privilege admitted for writes       */
    apb_periph_priv_t rd_priv;     /* lowest privilege admitted for reads        */
    bool              error_resp;  /* true: PSLVERR on a denied access; false: silent drop */
} apb_periph_access_t;

/*---------------------------------------------------------------------------
 * Set-up
 *---------------------------------------------------------------------------*/

/* Bind the handle to the instance at cfg->base. No register is accessed, so
 * the call is valid in any privilege mode. */
apb_periph_status_t apb_periph_init(apb_periph_t *dev, const apb_periph_config_t *cfg);

/*---------------------------------------------------------------------------
 * Privilege gates (MDELEG). Machine mode only: from S or U mode the access
 * is refused whatever the gates say.
 *---------------------------------------------------------------------------*/

/* Program both gates and the denial response in one transfer */
apb_periph_status_t apb_periph_set_access(apb_periph_t *dev, const apb_periph_access_t *access);
void                apb_periph_get_access(const apb_periph_t *dev, apb_periph_access_t *access);

/*---------------------------------------------------------------------------
 * Register bank: n = 0..7, not checked. Byte and half-word stores to REGOUT
 * update only the lanes they address; a store to REGIN is ignored.
 *---------------------------------------------------------------------------*/

/* REGOUT_0n: value driven on register_0n_o */
static inline void apb_periph_out_write(apb_periph_t *dev, unsigned n, uint32_t value)
{
    dev->regs->REGOUT[n] = value;
}

static inline uint32_t apb_periph_out_read(const apb_periph_t *dev, unsigned n)
{
    return dev->regs->REGOUT[n];
}

/* Replace the bits of mask in REGOUT_0n by those of value (read-modify-write,
 * not atomic against another manager or an interrupt handler) */
static inline void apb_periph_out_modify(apb_periph_t *dev, unsigned n, uint32_t mask, uint32_t value)
{
    APB_PERIPH_IO uint32_t *reg = &dev->regs->REGOUT[n];
    *reg = (*reg & ~mask) | (value & mask);
}

/* REGIN_(8+n): register_(8+n)_i as sampled in the ACCESS phase of the read */
static inline uint32_t apb_periph_in_read(const apb_periph_t *dev, unsigned n)
{
    return dev->regs->REGIN[n];
}

#ifdef __cplusplus
}
#endif

#endif /* APB_PERIPH_EXAMPLE_H */
