/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      ahb_periph_example.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Set-up and MDELEG privilege gates. Register bank accesses are the inline
 * functions of ahb_periph_example.h.
 *----------------------------------------------------------------------------*/
#include "ahb_periph_example.h"

#define FIELD_GET(v, f)  (((v) & f##_Msk) >> f##_Pos)

static bool priv_valid(periph_priv_t p)
{
    return p == PERIPH_PRIV_U || p == PERIPH_PRIV_S || p == PERIPH_PRIV_M;
}

periph_status_t periph_init(periph_t *dev, const periph_config_t *cfg)
{
    if (!dev || !cfg || !cfg->base || (cfg->base & 3u))
        return PERIPH_ERR_PARAM;
    dev->regs = (PERIPH_TypeDef *) cfg->base;
    return PERIPH_OK;
}

periph_status_t periph_set_access(periph_t *dev, const periph_access_t *access)
{
    if (!access || !priv_valid(access->wr_priv) || !priv_valid(access->rd_priv))
        return PERIPH_ERR_PARAM;

    /* One word store: gates (byte 0) and RESP (byte 1) switch together, no access sees a mix */
    dev->regs->MDELEG = ((uint32_t) access->wr_priv << PERIPH_MDELEG_WR_PRIV_Pos) |
                        ((uint32_t) access->rd_priv << PERIPH_MDELEG_RD_PRIV_Pos) |
                        (access->error_resp ? PERIPH_MDELEG_RESP_Msk : 0u);
    return PERIPH_OK;
}

void periph_get_access(const periph_t *dev, periph_access_t *access)
{
    uint32_t v = dev->regs->MDELEG;
    access->wr_priv    = (periph_priv_t) FIELD_GET(v, PERIPH_MDELEG_WR_PRIV);
    access->rd_priv    = (periph_priv_t) FIELD_GET(v, PERIPH_MDELEG_RD_PRIV);
    access->error_resp = (v & PERIPH_MDELEG_RESP_Msk) != 0u;
}
