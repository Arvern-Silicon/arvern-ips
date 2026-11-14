/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_spi_flash.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * SPI NOR flash over apb_spi. Reference: doc/apb_spi.md ("Integration
 * examples").
 *----------------------------------------------------------------------------*/
#include "apb_spi_flash.h"

#define FL_WIP_POLLS    256u            /* POLLs of 65536 status bytes for a program to end */

static void ent(apb_spi_entry_t *e, uint16_t xfer, uint32_t data, uint32_t *dst)
{
    e->xfer = xfer;
    e->data = data;
    e->dst  = dst;
}

apb_spi_status_t apb_spi_flash_status(apb_spi_flash_t *fl, uint8_t *sr1)
{
    uint32_t v = 0u;
    apb_spi_entry_t e[2];
    if (!fl || !sr1)
        return APB_SPI_ERR_PARAM;
    ent(&e[0], APB_SPI_XFER(APB_SPI_KIND_TX, 8u, 1u, APB_SPI_HOLD, fl->cs), 0x05u, 0);
    ent(&e[1], APB_SPI_XFER(APB_SPI_KIND_RX, 8u, 1u, 0u, fl->cs), 0u, &v);
    apb_spi_status_t st = apb_spi_run(fl->spi, e, 2u);
    *sr1 = (uint8_t) v;
    return st;
}

apb_spi_status_t apb_spi_flash_read(apb_spi_flash_t *fl, uint32_t addr, uint32_t *buf, uint32_t words)
{
    apb_spi_entry_t e[5];
    size_t n = 0u;
    if (!fl || !buf || words == 0u || words > 65536u)
        return APB_SPI_ERR_PARAM;
    uint8_t cs = fl->cs;
    if (fl->spi->lanes_max == 4u) {
        ent(&e[n++], APB_SPI_XFER(APB_SPI_KIND_TX,  8u, 1u, APB_SPI_HOLD, cs), 0xEBu, 0);
        ent(&e[n++], APB_SPI_XFER(APB_SPI_KIND_TX, 24u, 4u, APB_SPI_HOLD, cs), addr & 0xFFFFFFu, 0);
        ent(&e[n++], APB_SPI_XFER(APB_SPI_KIND_TX,  8u, 4u, APB_SPI_HOLD, cs), 0x00u, 0);   /* mode: not Axh */
        if (fl->dummy)
            ent(&e[n++], APB_SPI_XFER(APB_SPI_KIND_DUMMY, 4u, 4u, APB_SPI_HOLD, cs), fl->dummy - 1u, 0);
        ent(&e[n++], APB_SPI_XFER(APB_SPI_KIND_RX, 32u, 4u, 0u, cs), words - 1u, buf);
    } else {
        ent(&e[n++], APB_SPI_XFER(APB_SPI_KIND_TX,  8u, 1u, APB_SPI_HOLD, cs), 0x03u, 0);
        ent(&e[n++], APB_SPI_XFER(APB_SPI_KIND_TX, 24u, 1u, APB_SPI_HOLD, cs), addr & 0xFFFFFFu, 0);
        ent(&e[n++], APB_SPI_XFER(APB_SPI_KIND_RX, 32u, 1u, 0u, cs), words - 1u, buf);
    }
    return apb_spi_run(fl->spi, e, n);
}

apb_spi_status_t apb_spi_flash_program(apb_spi_flash_t *fl, uint32_t addr, const uint32_t *buf, uint32_t words)
{
    apb_spi_entry_t e[3];
    uint32_t sr = 0u;
    if (!fl || !buf || words == 0u || ((addr & 0xFFu) + 4u * words) > 256u)
        return APB_SPI_ERR_PARAM;
    apb_spi_t *spi = fl->spi;
    uint8_t    cs  = fl->cs;
    bool       q   = (spi->lanes_max == 4u);

    ent(&e[0], APB_SPI_XFER(APB_SPI_KIND_TX,  8u, 1u, 0u, cs), 0x06u, 0);                 /* WREN */
    ent(&e[1], APB_SPI_XFER(APB_SPI_KIND_TX,  8u, 1u, APB_SPI_HOLD, cs), q ? 0x32u : 0x02u, 0);
    ent(&e[2], APB_SPI_XFER(APB_SPI_KIND_TX, 24u, 1u, APB_SPI_HOLD, cs), addr & 0xFFFFFFu, 0);
    (void) apb_spi_run(spi, e, 3u);
    for (uint32_t i = 0u; i < words; i++) {
        apb_spi_status_t st = apb_spi_tx(spi, cs, q ? 4u : 1u, 32u, buf[i], (i + 1u < words) ? APB_SPI_HOLD : 0u);
        if (st != APB_SPI_OK)
            return st;
    }
    /* WIP: status byte bit 0 */
    for (uint32_t i = 0u; i < FL_WIP_POLLS; i++) {
        ent(&e[0], APB_SPI_XFER(APB_SPI_KIND_TX,   8u, 1u, APB_SPI_HOLD, cs), 0x05u, 0);
        ent(&e[1], APB_SPI_XFER(APB_SPI_KIND_POLL, 8u, 1u, 0u, cs), APB_SPI_POLL_ARG(65536u, 0x01u, 0x01u), &sr);
        if (apb_spi_run(spi, e, 2u) == APB_SPI_OK)
            return APB_SPI_OK;
    }
    return APB_SPI_ERR_TIMEOUT;
}
