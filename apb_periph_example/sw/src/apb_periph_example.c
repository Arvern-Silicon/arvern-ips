/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_periph_example.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Set-up and MDELEG privilege gates. Register bank accesses are the inline
 * functions of apb_periph_example.h.
 *----------------------------------------------------------------------------*/
#include "apb_periph_example.h"

#define FIELD_GET(v, f)  (((v) & f##_Msk) >> f##_Pos)

static bool priv_valid(apb_periph_priv_t p)
{
    return p == APB_PERIPH_PRIV_U || p == APB_PERIPH_PRIV_S || p == APB_PERIPH_PRIV_M;
}

apb_periph_status_t apb_periph_init(apb_periph_t *dev, const apb_periph_config_t *cfg)
{
    if (!dev || !cfg || !cfg->base || (cfg->base & 3u))
        return APB_PERIPH_ERR_PARAM;
    dev->regs = (APB_PERIPH_TypeDef *) cfg->base;
    return APB_PERIPH_OK;
}

apb_periph_status_t apb_periph_set_access(apb_periph_t *dev, const apb_periph_access_t *access)
{
    if (!dev || !access || !priv_valid(access->wr_priv) || !priv_valid(access->rd_priv))
        return APB_PERIPH_ERR_PARAM;

    /* One word store: gates (byte 0) and RESP (byte 1) switch together, no access sees a mix */
    dev->regs->MDELEG = ((uint32_t) access->wr_priv << APB_PERIPH_MDELEG_WR_PRIV_Pos) |
                        ((uint32_t) access->rd_priv << APB_PERIPH_MDELEG_RD_PRIV_Pos) |
                        (access->error_resp ? APB_PERIPH_MDELEG_RESP_Msk : 0u);
    return APB_PERIPH_OK;
}

void apb_periph_get_access(const apb_periph_t *dev, apb_periph_access_t *access)
{
    uint32_t v = dev->regs->MDELEG;
    access->wr_priv    = (apb_periph_priv_t) FIELD_GET(v, APB_PERIPH_MDELEG_WR_PRIV);
    access->rd_priv    = (apb_periph_priv_t) FIELD_GET(v, APB_PERIPH_MDELEG_RD_PRIV);
    access->error_resp = (v & APB_PERIPH_MDELEG_RESP_Msk) != 0u;
}
