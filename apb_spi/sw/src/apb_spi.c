/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_spi.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * SPI controller driver. Reference: doc/apb_spi.md.
 *----------------------------------------------------------------------------*/
#include "apb_spi.h"

#define FIELD_GET(v, f)     (((v) & f##_Msk) >> f##_Pos)

apb_spi_status_t apb_spi_init(apb_spi_t *dev, const apb_spi_config_t *cfg)
{
    if (!dev || !cfg || (cfg->base & 3u))
        return APB_SPI_ERR_PARAM;
    dev->regs = (APB_SPI_TypeDef *) cfg->base;
    uint32_t c = dev->regs->CFG;
    if (FIELD_GET(c, APB_SPI_CFG_VERSION) != APB_SPI_CFG_VERSION_1)
        return APB_SPI_ERR_ABSENT;
    uint32_t lanes  = FIELD_GET(c, APB_SPI_CFG_LANES);
    dev->tx_depth   = (uint16_t) (1u << FIELD_GET(c, APB_SPI_CFG_TX_FIFO_AW));
    dev->rx_depth   = (c & APB_SPI_CFG_RX_EN_Msk) ? (uint16_t) (1u << FIELD_GET(c, APB_SPI_CFG_RX_FIFO_AW)) : 0u;
    dev->cs_nr      = (uint8_t) (FIELD_GET(c, APB_SPI_CFG_CS_NR_M1) + 1u);
    dev->lanes_max  = (uint8_t) (lanes == 2u ? 4u : lanes == 1u ? 2u : 1u);
    dev->poll       = (c & APB_SPI_CFG_POLL_EN_Msk) != 0u;
    return APB_SPI_OK;
}

apb_spi_status_t apb_spi_set_clkdiv(apb_spi_t *dev, uint16_t half, uint8_t rx_dly)
{
    if (!dev || half < 1u || half > APB_SPI_HALF_MAX || rx_dly > APB_SPI_RX_DLY_MAX)
        return APB_SPI_ERR_PARAM;
    dev->regs->CLKDIV = ((uint32_t) (half - 1u) << APB_SPI_CLKDIV_DIV_Pos) |
                        ((uint32_t) rx_dly << APB_SPI_CLKDIV_RX_DLY_Pos);
    return APB_SPI_OK;
}

apb_spi_status_t apb_spi_set_rate(apb_spi_t *dev, uint32_t pclk_hz, uint32_t sck_hz, uint8_t rx_dly)
{
    if (!dev || pclk_hz == 0u || sck_hz == 0u)
        return APB_SPI_ERR_PARAM;
    /* HALF = ceil(pclk / (2 * sck)), at least 1 (32-bit: 2 * sck < pclk past the first test) */
    uint32_t half = 1u;
    if (sck_hz < pclk_hz - pclk_hz / 2u) {
        uint32_t two_sck = 2u * sck_hz;
        half = pclk_hz / two_sck + ((pclk_hz % two_sck) != 0u);
    }
    if (half > APB_SPI_HALF_MAX)
        return APB_SPI_ERR_PARAM;
    return apb_spi_set_clkdiv(dev, (uint16_t) half, rx_dly);
}

void apb_spi_set_mode(apb_spi_t *dev, uint32_t mode)
{
    uint32_t keep = dev->regs->CTRL & (APB_SPI_CTRL_EN_Msk | APB_SPI_CTRL_DBG_POP_Msk);
    dev->regs->CTRL = keep | (mode & ~(APB_SPI_CTRL_EN_Msk | APB_SPI_CTRL_DBG_POP_Msk));
}

apb_spi_status_t apb_spi_set_cs(apb_spi_t *dev, uint8_t cs_pol, uint8_t setup, uint8_t hold, uint8_t inact)
{
    if (!dev || setup < 1u || setup > 16u || hold < 1u || hold > 16u || inact < 1u || inact > 16u)
        return APB_SPI_ERR_PARAM;
    dev->regs->CSCFG = ((uint32_t) cs_pol << APB_SPI_CSCFG_CSPOL_Pos) |
                       ((uint32_t) (setup - 1u) << APB_SPI_CSCFG_SETUP_Pos) |
                       ((uint32_t) (hold - 1u)  << APB_SPI_CSCFG_HOLD_Pos)  |
                       ((uint32_t) (inact - 1u) << APB_SPI_CSCFG_INACT_Pos);
    return APB_SPI_OK;
}

/* Is an entry legal for this build (doc "Refused entries") */
static bool entry_ok(const apb_spi_t *dev, uint8_t sel, uint8_t lanes, uint8_t bits, uint32_t kind, uint32_t flags)
{
    if (lanes != 1u && lanes != 2u && lanes != 4u) return false;
    if (lanes > dev->lanes_max)                     return false;
    if (bits < 1u || bits > 32u || (bits % lanes))  return false;
    if (!(flags & APB_SPI_NO_CS) && sel >= dev->cs_nr) return false;
    if (dev->rx_depth == 0u && (kind == APB_SPI_KIND_RX || kind == APB_SPI_KIND_POLL || (flags & APB_SPI_CAPT)))
        return false;
    if (!dev->poll && kind == APB_SPI_KIND_POLL)    return false;
    return true;
}

static void push_saved(apb_spi_t *dev, uint16_t xfer, uint32_t data)
{
    /* XFER and the TXDATA write that uses it are one critical section: save
     * and restore XFER so an interrupted push sequence keeps its attributes */
    uint32_t saved = dev->regs->XFER;
    while (apb_spi_tx_level(dev) >= dev->tx_depth) { }
    dev->regs->XFER   = xfer;
    dev->regs->TXDATA = data;
    dev->regs->XFER   = saved;
}

apb_spi_status_t apb_spi_tx(apb_spi_t *dev, uint8_t sel, uint8_t lanes, uint8_t bits, uint32_t data, uint32_t flags)
{
    if (!dev || !entry_ok(dev, sel, lanes, bits, APB_SPI_KIND_TX, flags))
        return APB_SPI_ERR_PARAM;
    push_saved(dev, APB_SPI_XFER(APB_SPI_KIND_TX, bits, lanes, flags, sel), data);
    return APB_SPI_OK;
}

apb_spi_status_t apb_spi_rx(apb_spi_t *dev, uint8_t sel, uint8_t lanes, uint8_t bits, uint32_t frames, uint32_t flags)
{
    if (!dev || frames < 1u || frames > 65536u || !entry_ok(dev, sel, lanes, bits, APB_SPI_KIND_RX, flags))
        return APB_SPI_ERR_PARAM;
    push_saved(dev, APB_SPI_XFER(APB_SPI_KIND_RX, bits, lanes, flags, sel), frames - 1u);
    return APB_SPI_OK;
}

apb_spi_status_t apb_spi_dummy(apb_spi_t *dev, uint8_t sel, uint8_t lanes, uint32_t clocks, uint32_t flags)
{
    if (!dev || clocks < 1u || clocks > 65536u || !entry_ok(dev, sel, lanes, lanes, APB_SPI_KIND_DUMMY, flags))
        return APB_SPI_ERR_PARAM;
    push_saved(dev, APB_SPI_XFER(APB_SPI_KIND_DUMMY, lanes, lanes, flags, sel), clocks - 1u);
    return APB_SPI_OK;
}

apb_spi_status_t apb_spi_poll(apb_spi_t *dev, uint8_t sel, uint8_t lanes, uint8_t bits, uint32_t frames,
                              uint8_t mask, uint8_t value, uint32_t flags)
{
    if (!dev || frames < 1u || frames > 65536u || !entry_ok(dev, sel, lanes, bits, APB_SPI_KIND_POLL, flags))
        return APB_SPI_ERR_PARAM;
    push_saved(dev, APB_SPI_XFER(APB_SPI_KIND_POLL, bits, lanes, flags, sel), APB_SPI_POLL_ARG(frames, mask, value));
    return APB_SPI_OK;
}

/* Words an entry pushes into the receive FIFO */
static uint32_t entry_words(uint16_t xfer, uint32_t data)
{
    uint32_t kind = FIELD_GET((uint32_t) xfer, APB_SPI_XFER_KIND);
    if (kind == APB_SPI_KIND_RX)   return (data & 0xFFFFu) + 1u;
    if (kind == APB_SPI_KIND_POLL) return 1u;
    if (kind == APB_SPI_KIND_TX && (xfer & APB_SPI_XFER_CAPT_Msk) && !(xfer & APB_SPI_XFER_LANES_Msk)) return 1u;
    return 0u;
}

apb_spi_status_t apb_spi_run(apb_spi_t *dev, const apb_spi_entry_t *e, size_t n)
{
    if (!dev || (n && !e))
        return APB_SPI_ERR_PARAM;
    uint32_t saved = dev->regs->XFER;
    uint32_t xfer  = saved;
    size_t   ip = 0u, ir = 0u;                  /* next entry to push / to receive for */
    uint32_t got = 0u;                          /* words received for entry ir         */
    dev->regs->IRQ_PEND = APB_SPI_IRQ_POLL_TO;
    for (;;) {
        /* the entries that receive nothing complete without a word */
        while (ir < ip && entry_words(e[ir].xfer, e[ir].data) == got) { ir++; got = 0u; }
        if (ip == n && ir == n)
            break;
        uint32_t st = dev->regs->STATUS;
        if (ir < ip && FIELD_GET(st, APB_SPI_STATUS_RX_LEVEL) != 0u) {
            uint32_t w = dev->regs->RXDATA;
            if (e[ir].dst) e[ir].dst[got] = w;
            got++;
            continue;
        }
        if (ip < n && FIELD_GET(st, APB_SPI_STATUS_TX_LEVEL) < dev->tx_depth) {
            if (e[ip].xfer != xfer) { xfer = e[ip].xfer; dev->regs->XFER = xfer; }
            dev->regs->TXDATA = e[ip].data;
            ip++;
        }
    }
    dev->regs->XFER = saved;
    return (dev->regs->IRQ_PEND & APB_SPI_IRQ_POLL_TO) ? APB_SPI_ERR_TIMEOUT : APB_SPI_OK;
}

apb_spi_status_t apb_spi_wait_idle(apb_spi_t *dev, uint32_t max_polls)
{
    if (!dev)
        return APB_SPI_ERR_PARAM;
    for (uint32_t i = 0u; i < max_polls; i++)
        if (apb_spi_idle(dev))
            return APB_SPI_OK;
    return APB_SPI_ERR_TIMEOUT;
}

apb_spi_status_t apb_spi_set_thresholds(apb_spi_t *dev, uint16_t tx_thr, uint16_t rx_thr)
{
    if (!dev || tx_thr > 0x1FFu || rx_thr > 0x1FFu)
        return APB_SPI_ERR_PARAM;
    dev->regs->THRESH = ((uint32_t) tx_thr << APB_SPI_THRESH_TX_Pos) | ((uint32_t) rx_thr << APB_SPI_THRESH_RX_Pos);
    return APB_SPI_OK;
}

static bool priv_valid(apb_spi_priv_t p)
{
    return p == APB_SPI_PRIV_U || p == APB_SPI_PRIV_S || p == APB_SPI_PRIV_M;
}

apb_spi_status_t apb_spi_set_access(apb_spi_t *dev, const apb_spi_access_t *access)
{
    if (!dev || !access || !priv_valid(access->wr_priv) || !priv_valid(access->rd_priv))
        return APB_SPI_ERR_PARAM;

    /* One word store: gates (byte 0) and RESP (byte 1) switch together, no access sees a mix */
    dev->regs->MDELEG = ((uint32_t) access->wr_priv << APB_SPI_MDELEG_WR_PRIV_Pos) |
                        ((uint32_t) access->rd_priv << APB_SPI_MDELEG_RD_PRIV_Pos) |
                        (access->error_resp ? APB_SPI_MDELEG_RESP_Msk : 0u);
    return APB_SPI_OK;
}

void apb_spi_get_access(const apb_spi_t *dev, apb_spi_access_t *access)
{
    uint32_t v = dev->regs->MDELEG;
    access->wr_priv    = (apb_spi_priv_t) FIELD_GET(v, APB_SPI_MDELEG_WR_PRIV);
    access->rd_priv    = (apb_spi_priv_t) FIELD_GET(v, APB_SPI_MDELEG_RD_PRIV);
    access->error_resp = (v & APB_SPI_MDELEG_RESP_Msk) != 0u;
}
