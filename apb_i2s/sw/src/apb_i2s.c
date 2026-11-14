/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_i2s.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Set-up, rate selection, stream control, FIFO transfers, thresholds and the
 * MDELEG gates. Levels and interrupt accesses are the inline functions of
 * apb_i2s.h.
 *----------------------------------------------------------------------------*/
#include "apb_i2s.h"

#define FIELD_GET(v, f)  (((v) & f##_Msk) >> f##_Pos)

static const uint16_t ratio_tab[5] = { 256u, 384u, 512u, 768u, 1024u };

apb_i2s_status_t apb_i2s_init(apb_i2s_t *dev, uintptr_t base)
{
    if (!dev || !base || (base & 3u))
        return APB_I2S_ERR_PARAM;

    APB_I2S_TypeDef *regs = (APB_I2S_TypeDef *) base;
    uint32_t info = regs->INFO;

    if (FIELD_GET(info, APB_I2S_INFO_VERSION) != APB_I2S_INFO_VERSION_1 ||
        !(info & (APB_I2S_INFO_TX_EN_Msk | APB_I2S_INFO_RX_EN_Msk)))
        return APB_I2S_ERR_ABSENT;

    dev->regs     = regs;
    dev->tx_depth = (info & APB_I2S_INFO_TX_EN_Msk) ? (uint16_t) (1u << FIELD_GET(info, APB_I2S_INFO_TX_FIFO_AW)) : 0u;
    dev->rx_depth = (info & APB_I2S_INFO_RX_EN_Msk) ? (uint16_t) (1u << FIELD_GET(info, APB_I2S_INFO_RX_FIFO_AW)) : 0u;
    return APB_I2S_OK;
}

apb_i2s_status_t apb_i2s_rate(uint32_t pclk_hz, uint32_t fs_hz, uint32_t ratio_mask,
                              apb_i2s_clocks_t *clocks, uint32_t *actual_hz)
{
    uint64_t best_err = UINT64_MAX;
    uint32_t best_fs  = 0u;

    if (!clocks || !pclk_hz || !fs_hz)
        return APB_I2S_ERR_PARAM;
    if (!ratio_mask)
        ratio_mask = 0x1Fu;

    for (unsigned r = 0; r < 5u; r++) {
        if (!(ratio_mask & (1u << r)))
            continue;
        /* Fs = pclk / (2 * MDIV * RATIO): the nearest MDIV, then its neighbour */
        uint64_t den  = 2ull * ratio_tab[r] * fs_hz;
        uint64_t mdiv = ((uint64_t) pclk_hz + den / 2u) / den;
        for (uint64_t m = (mdiv > 1u) ? mdiv - 1u : 1u; m <= mdiv + 1u; m++) {
            if (m < 1u || m > 256u)
                continue;
            uint32_t fs  = (uint32_t) (pclk_hz / (2ull * m * ratio_tab[r]));
            uint64_t err = (fs > fs_hz) ? (fs - fs_hz) : (fs_hz - fs);
            if (err < best_err) {
                best_err      = err;
                best_fs       = fs;
                clocks->mdiv  = (uint16_t) m;
                clocks->ratio = ratio_tab[r];
            }
        }
    }
    if (best_err == UINT64_MAX)
        return APB_I2S_ERR_RATE;
    if (actual_hz)
        *actual_hz = best_fs;
    return APB_I2S_OK;
}

static int ratio_code(uint16_t ratio)
{
    for (int r = 0; r < 5; r++)
        if (ratio_tab[r] == ratio)
            return r;
    return -1;
}

static uint32_t packing_bits(apb_i2s_packing_t tx, apb_i2s_packing_t rx)
{
    uint32_t v = 0u;
    if (tx != APB_I2S_STEREO)
        v |= APB_I2S_CTRL_TX_MONO_Msk;
    if (rx != APB_I2S_STEREO)
        v |= APB_I2S_CTRL_RX_MONO_Msk | ((uint32_t) (rx - 1) << APB_I2S_CTRL_RX_MONO_SEL_Pos);
    return v;
}

apb_i2s_status_t apb_i2s_configure(apb_i2s_t *dev, const apb_i2s_config_t *cfg)
{
    int rc;

    if (!dev || !cfg || cfg->clocks.mdiv < 1u || cfg->clocks.mdiv > 256u || cfg->rx_dly > 15u ||
        (cfg->format & ~0x3Fu) || (rc = ratio_code(cfg->clocks.ratio)) < 0)
        return APB_I2S_ERR_PARAM;
    /* the capture lands within a BCLK period of its sampling edge: RX_DLY + 2 <= 2H,
       H = MDIV * RATIO / (2 * S) pclk cycles (S = 16 with 16-bit slots, else 32) */
    if ((uint32_t) cfg->rx_dly + 2u > (uint32_t) cfg->clocks.mdiv * cfg->clocks.ratio /
                                      ((cfg->format & APB_I2S_FORMAT_SLOT16) ? 16u : 32u))
        return APB_I2S_ERR_PARAM;
    if ((dev->regs->CTRL & (APB_I2S_CTRL_EN_Msk | APB_I2S_CTRL_TX_ON_Msk | APB_I2S_CTRL_RX_ON_Msk)) ||
        apb_i2s_running(dev))
        return APB_I2S_ERR_BUSY;

    dev->regs->CLKDIV = ((uint32_t) (cfg->clocks.mdiv - 1u) << APB_I2S_CLKDIV_MDIV_Pos) |
                        ((uint32_t) rc << APB_I2S_CLKDIV_RATIO_Pos) |
                        ((uint32_t) cfg->rx_dly << APB_I2S_CLKDIV_RX_DLY_Pos);
    dev->regs->FORMAT = cfg->format;
    dev->regs->CTRL   = (cfg->mclk ? APB_I2S_CTRL_MCLK_EN_Msk : 0u) | packing_bits(cfg->tx_packing, cfg->rx_packing);
    return APB_I2S_OK;
}

apb_i2s_status_t apb_i2s_start(apb_i2s_t *dev, bool tx, bool rx)
{
    if ((tx && !dev->tx_depth) || (rx && !dev->rx_depth))
        return APB_I2S_ERR_PARAM;
    dev->regs->CTRL |= APB_I2S_CTRL_EN_Msk | (tx ? APB_I2S_CTRL_TX_ON_Msk : 0u) | (rx ? APB_I2S_CTRL_RX_ON_Msk : 0u);
    return APB_I2S_OK;
}

void apb_i2s_stop(apb_i2s_t *dev)
{
    /* streams off first: the frames in progress complete and the last one is
       silence; then the clocks, and the engine's tail */
    dev->regs->CTRL &= ~(APB_I2S_CTRL_TX_ON_Msk | APB_I2S_CTRL_RX_ON_Msk);
    while (dev->regs->STATUS & (APB_I2S_STATUS_TX_ACTIVE_Msk | APB_I2S_STATUS_RX_ACTIVE_Msk))
        ;
    dev->regs->CTRL &= ~APB_I2S_CTRL_EN_Msk;
    while (apb_i2s_running(dev))
        ;
}

unsigned apb_i2s_write(apb_i2s_t *dev, const uint32_t *words, unsigned n)
{
    unsigned room = dev->tx_depth - apb_i2s_tx_level(dev);
    unsigned k    = (n < room) ? n : room;
    for (unsigned i = 0; i < k; i++)
        dev->regs->TXDATA = words[i];
    return k;
}

unsigned apb_i2s_read(apb_i2s_t *dev, uint32_t *words, unsigned n)
{
    unsigned have = apb_i2s_rx_level(dev);
    unsigned k    = (n < have) ? n : have;
    for (unsigned i = 0; i < k; i++)
        words[i] = dev->regs->RXDATA;
    return k;
}

void apb_i2s_flush(apb_i2s_t *dev, bool tx, bool rx)
{
    dev->regs->CMD = (tx ? APB_I2S_CMD_TX_FLUSH : 0u) | (rx ? APB_I2S_CMD_RX_FLUSH : 0u);
}

apb_i2s_status_t apb_i2s_set_thresholds(apb_i2s_t *dev, unsigned tx_thr, unsigned rx_thr)
{
    if ((dev->tx_depth && tx_thr >= dev->tx_depth) || (dev->rx_depth && (rx_thr < 1u || rx_thr > dev->rx_depth)))
        return APB_I2S_ERR_PARAM;
    dev->regs->THRESH = ((uint32_t) tx_thr << APB_I2S_THRESH_TX_THR_Pos) | ((uint32_t) rx_thr << APB_I2S_THRESH_RX_THR_Pos);
    return APB_I2S_OK;
}

apb_i2s_status_t apb_i2s_set_access(apb_i2s_t *dev, const apb_i2s_access_t *access)
{
    if (!access || access->wr_priv == 2u || access->rd_priv == 2u || access->wr_priv > 3u || access->rd_priv > 3u)
        return APB_I2S_ERR_PARAM;
    dev->regs->MDELEG = ((uint32_t) access->wr_priv << APB_I2S_MDELEG_WR_PRIV_Pos) |
                        ((uint32_t) access->rd_priv << APB_I2S_MDELEG_RD_PRIV_Pos) |
                        (access->error_response ? APB_I2S_MDELEG_RESP_Msk : 0u);
    return APB_I2S_OK;
}

void apb_i2s_get_access(const apb_i2s_t *dev, apb_i2s_access_t *access)
{
    uint32_t v = dev->regs->MDELEG;
    access->wr_priv        = (apb_i2s_priv_t) FIELD_GET(v, APB_I2S_MDELEG_WR_PRIV);
    access->rd_priv        = (apb_i2s_priv_t) FIELD_GET(v, APB_I2S_MDELEG_RD_PRIV);
    access->error_response = (v & APB_I2S_MDELEG_RESP_Msk) != 0u;
}
