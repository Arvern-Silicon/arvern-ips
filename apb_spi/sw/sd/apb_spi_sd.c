/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_spi_sd.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * SD card in SPI mode over apb_spi. Reference: doc/apb_spi.md ("Software").
 *----------------------------------------------------------------------------*/
#include "apb_spi_sd.h"

#define SD_ID_HZ        400000u         /* identification clock, at most 400 kHz (fOD) */
#define SD_ACMD41_TRIES 2000u           /* ACMD41 until ready: about a second at 400 kHz */
#define SD_BUSY_POLLS   64u             /* POLLs of 65536 bytes while the card is busy  */
#define SD_TOKEN_POLLS  16u

#define TX8(sel, f)     APB_SPI_XFER(APB_SPI_KIND_TX,    8u, 1u, (f), (sel))
#define RX8(sel, f)     APB_SPI_XFER(APB_SPI_KIND_RX,    8u, 1u, (f), (sel))
#define RX16(sel, f)    APB_SPI_XFER(APB_SPI_KIND_RX,   16u, 1u, (f), (sel))
#define RX32(sel, f)    APB_SPI_XFER(APB_SPI_KIND_RX,   32u, 1u, (f), (sel))
#define TX32(sel, f)    APB_SPI_XFER(APB_SPI_KIND_TX,   32u, 1u, (f), (sel))
#define POLL8(sel, f)   APB_SPI_XFER(APB_SPI_KIND_POLL,  8u, 1u, (f), (sel))
#define TRAIL           APB_SPI_XFER(APB_SPI_KIND_DUMMY, 1u, 1u, APB_SPI_NO_CS, 0u)

/* The six command bytes, under the select */
static void cmd_entries(apb_spi_entry_t *e, uint8_t sel, uint8_t idx, uint32_t arg, uint8_t crc)
{
    uint32_t b[6] = { 0x40u | idx, arg >> 24, (arg >> 16) & 0xFFu, (arg >> 8) & 0xFFu, arg & 0xFFu, crc };
    for (int i = 0; i < 6; i++) {
        e[i].xfer = TX8(sel, APB_SPI_HOLD);
        e[i].data = b[i];
        e[i].dst  = 0;
    }
}

static void ent(apb_spi_entry_t *e, uint16_t xfer, uint32_t data, uint32_t *dst)
{
    e->xfer = xfer;
    e->data = data;
    e->dst  = dst;
}

/* A command with its R1 (MSB 0 within 16 bytes); tail entries follow under the
 * select; hold keeps the select after them */
static apb_spi_sd_status_t command(apb_spi_sd_t *sd, uint8_t idx, uint32_t arg, uint8_t crc,
                                   uint32_t *r1, const apb_spi_entry_t *tail, int ntail, bool hold)
{
    apb_spi_entry_t e[12];
    int n = 0;
    cmd_entries(e, sd->cs, idx, arg, crc); n = 6;
    ent(&e[n++], POLL8(sd->cs, (ntail || hold) ? APB_SPI_HOLD : 0u), APB_SPI_POLL_ARG(16u, 0x80u, 0x80u), r1);
    for (int i = 0; i < ntail; i++) {
        e[n] = tail[i];
        if (i == ntail - 1 && !hold) e[n].xfer &= (uint16_t) ~APB_SPI_HOLD;
        n++;
    }
    if (!hold) ent(&e[n++], TRAIL, 7u, 0);
    if (apb_spi_run(sd->spi, e, (size_t) n) != APB_SPI_OK)
        return APB_SPI_SD_ERR_TIMEOUT;
    return APB_SPI_SD_OK;
}

static apb_spi_sd_status_t fail(apb_spi_sd_t *sd, apb_spi_sd_status_t st)
{
    apb_spi_abort(sd->spi);
    (void) apb_spi_wait_idle(sd->spi, 100000u);
    apb_spi_flush(sd->spi, false, true);
    return st;
}

/* Poll for a byte with (b & mask) != value, repeating on POLL_TO up to polls times */
static apb_spi_sd_status_t poll_until(apb_spi_sd_t *sd, uint8_t mask, uint8_t value, uint32_t polls,
                                      uint32_t flags, uint32_t *b)
{
    apb_spi_entry_t e;
    for (uint32_t i = 0u; i < polls; i++) {
        ent(&e, POLL8(sd->cs, flags), APB_SPI_POLL_ARG(65536u, mask, value), b);
        if (apb_spi_run(sd->spi, &e, 1u) == APB_SPI_OK)
            return APB_SPI_SD_OK;
    }
    return APB_SPI_SD_ERR_TIMEOUT;
}

apb_spi_sd_status_t apb_spi_sd_init(apb_spi_sd_t *sd, apb_spi_t *spi, uint8_t cs,
                                    uint32_t pclk_hz, uint32_t data_hz, uint8_t rx_dly)
{
    uint32_t r1 = 0u, w = 0u;
    apb_spi_entry_t t[1];

    if (!sd || !spi || spi->rx_depth == 0u || !spi->poll || cs >= spi->cs_nr || data_hz == 0u)
        return APB_SPI_SD_ERR_PARAM;
    sd->spi        = spi;
    sd->cs         = cs;
    sd->block_addr = false;
    sd->data_hz    = data_hz;

    apb_spi_disable(spi);
    apb_spi_flush(spi, true, true);
    apb_spi_set_mode(spi, APB_SPI_MODE_0 | APB_SPI_IDLE_HIGH | APB_SPI_BSWAP);
    if (apb_spi_set_cs(spi, 0u, 1u, 1u, 1u) != APB_SPI_OK ||
        apb_spi_set_rate(spi, pclk_hz, SD_ID_HZ, rx_dly) != APB_SPI_OK)
        return APB_SPI_SD_ERR_PARAM;
    apb_spi_enable(spi);

    /* power-up: at least 74 clocks with the select high and data in high */
    if (apb_spi_dummy(spi, 0u, 1u, 80u, APB_SPI_NO_CS) != APB_SPI_OK)
        return APB_SPI_SD_ERR_PARAM;

    /* CMD0: idle state, SPI mode */
    if (command(sd, 0u, 0u, 0x95u, &r1, 0, 0, false) != APB_SPI_SD_OK || r1 != 0x01u)
        return fail(sd, APB_SPI_SD_ERR_TIMEOUT);

    /* CMD8: interface condition, 2.7-3.6 V, check pattern AAh */
    ent(&t[0], RX32(cs, APB_SPI_HOLD), 0u, &w);
    if (command(sd, 8u, 0x1AAu, 0x87u, &r1, t, 1, false) != APB_SPI_SD_OK)
        return fail(sd, APB_SPI_SD_ERR_TIMEOUT);
    bool v2 = !(r1 & 0x04u);                  /* illegal command: a version 1 card */
    if (v2 && (w >> 16) != 0xAA01u)           /* bytes 00 00 01 AA, byte-swapped   */
        return fail(sd, APB_SPI_SD_ERR_CARD);

    /* ACMD41 until ready, HCS set on a version 2 card */
    uint32_t tries = 0u;
    do {
        if (command(sd, 55u, 0u, 0xFFu, &r1, 0, 0, false) != APB_SPI_SD_OK ||
            command(sd, 41u, v2 ? 0x40000000u : 0u, 0xFFu, &r1, 0, 0, false) != APB_SPI_SD_OK)
            return fail(sd, APB_SPI_SD_ERR_TIMEOUT);
        if (r1 & 0xFEu)
            return fail(sd, APB_SPI_SD_ERR_CARD);
    } while (r1 != 0x00u && ++tries < SD_ACMD41_TRIES);
    if (r1 != 0x00u)
        return fail(sd, APB_SPI_SD_ERR_TIMEOUT);

    /* CMD58: OCR, CCS tells block addressing */
    if (v2) {
        ent(&t[0], RX32(cs, APB_SPI_HOLD), 0u, &w);
        if (command(sd, 58u, 0u, 0xFFu, &r1, t, 1, false) != APB_SPI_SD_OK || r1 != 0x00u)
            return fail(sd, APB_SPI_SD_ERR_CARD);
        uint32_t ocr = ((w & 0xFFu) << 24) | ((w & 0xFF00u) << 8) | ((w >> 8) & 0xFF00u) | (w >> 24);
        sd->block_addr = (ocr & (1u << 30)) != 0u;
    }
    if (!sd->block_addr)                      /* standard capacity: 512-byte blocks */
        if (command(sd, 16u, 512u, 0xFFu, &r1, 0, 0, false) != APB_SPI_SD_OK || r1 != 0x00u)
            return fail(sd, APB_SPI_SD_ERR_CARD);

    if (apb_spi_set_rate(spi, pclk_hz, data_hz, rx_dly) != APB_SPI_OK)
        return APB_SPI_SD_ERR_PARAM;
    return APB_SPI_SD_OK;
}

/* One data block received: start token, 128 words, CRC (the select held) */
static apb_spi_sd_status_t read_block(apb_spi_sd_t *sd, uint32_t *buf)
{
    uint32_t tok = 0u;
    apb_spi_entry_t e[2];
    if (poll_until(sd, 0xFFu, 0xFFu, SD_TOKEN_POLLS, APB_SPI_HOLD, &tok) != APB_SPI_SD_OK)
        return APB_SPI_SD_ERR_TIMEOUT;
    if (tok != 0xFEu)
        return APB_SPI_SD_ERR_DATA;
    ent(&e[0], RX32(sd->cs, APB_SPI_HOLD), 127u, buf);
    ent(&e[1], RX16(sd->cs, APB_SPI_HOLD), 0u, 0);
    (void) apb_spi_run(sd->spi, e, 2u);
    return APB_SPI_SD_OK;
}

apb_spi_sd_status_t apb_spi_sd_read(apb_spi_sd_t *sd, uint32_t block, uint32_t *buf, uint32_t count)
{
    uint32_t r1 = 0u, b = 0u;
    apb_spi_entry_t e[8];
    if (!sd || !buf || count == 0u)
        return APB_SPI_SD_ERR_PARAM;
    uint32_t arg = sd->block_addr ? block : block * 512u;

    if (command(sd, (count == 1u) ? 17u : 18u, arg, 0xFFu, &r1, 0, 0, true) != APB_SPI_SD_OK || r1 != 0x00u)
        return fail(sd, APB_SPI_SD_ERR_CARD);
    for (uint32_t i = 0u; i < count; i++) {
        apb_spi_sd_status_t st = read_block(sd, buf + 128u * i);
        if (st != APB_SPI_SD_OK)
            return fail(sd, st);
    }
    if (count > 1u) {
        /* CMD12; skip the byte the card may still be shifting, R1, busy */
        cmd_entries(e, sd->cs, 12u, 0u, 0xFFu);
        ent(&e[6], RX8(sd->cs, APB_SPI_HOLD), 0u, 0);
        ent(&e[7], POLL8(sd->cs, APB_SPI_HOLD), APB_SPI_POLL_ARG(16u, 0x80u, 0x80u), &r1);
        if (apb_spi_run(sd->spi, e, 8u) != APB_SPI_OK || r1 != 0x00u)
            return fail(sd, APB_SPI_SD_ERR_CARD);
        if (poll_until(sd, 0xFFu, 0x00u, SD_BUSY_POLLS, APB_SPI_HOLD, &b) != APB_SPI_SD_OK)
            return fail(sd, APB_SPI_SD_ERR_TIMEOUT);
    }
    ent(&e[0], TX8(sd->cs, 0u), 0xFFu, 0);       /* release the select */
    ent(&e[1], TRAIL, 7u, 0);
    (void) apb_spi_run(sd->spi, e, 2u);
    return APB_SPI_SD_OK;
}

/* One data block sent: token, 128 words, CRC, data response, busy (the select held) */
static apb_spi_sd_status_t write_block(apb_spi_sd_t *sd, uint8_t token, const uint32_t *buf)
{
    apb_spi_t *spi = sd->spi;
    uint32_t resp = 0u, b = 0u;
    apb_spi_entry_t e[2];

    if (apb_spi_tx(spi, sd->cs, 1u, 8u, token, APB_SPI_HOLD) != APB_SPI_OK)
        return APB_SPI_SD_ERR_PARAM;
    /* the data words: one XFER for all of them, saved and restored around */
    uint32_t saved = spi->regs->XFER;
    spi->regs->XFER = TX32(sd->cs, APB_SPI_HOLD);
    for (uint32_t i = 0u; i < 128u; i++) {
        while (apb_spi_tx_level(spi) >= spi->tx_depth) { }
        spi->regs->TXDATA = buf[i];
    }
    spi->regs->XFER = saved;
    ent(&e[0], APB_SPI_XFER(APB_SPI_KIND_TX, 16u, 1u, APB_SPI_HOLD, sd->cs), 0xFFFFu, 0);
    ent(&e[1], RX8(sd->cs, APB_SPI_HOLD), 0u, &resp);
    (void) apb_spi_run(spi, e, 2u);
    if ((resp & 0x1Fu) != 0x05u)
        return APB_SPI_SD_ERR_DATA;
    return poll_until(sd, 0xFFu, 0x00u, SD_BUSY_POLLS, APB_SPI_HOLD, &b);
}

apb_spi_sd_status_t apb_spi_sd_write(apb_spi_sd_t *sd, uint32_t block, const uint32_t *buf, uint32_t count)
{
    uint32_t r1 = 0u, b = 0u;
    apb_spi_entry_t e[2];
    if (!sd || !buf || count == 0u)
        return APB_SPI_SD_ERR_PARAM;
    uint32_t arg = sd->block_addr ? block : block * 512u;

    if (command(sd, (count == 1u) ? 24u : 25u, arg, 0xFFu, &r1, 0, 0, true) != APB_SPI_SD_OK || r1 != 0x00u)
        return fail(sd, APB_SPI_SD_ERR_CARD);
    for (uint32_t i = 0u; i < count; i++) {
        apb_spi_sd_status_t st = write_block(sd, (count == 1u) ? 0xFEu : 0xFCu, buf + 128u * i);
        if (st != APB_SPI_SD_OK)
            return fail(sd, st);
    }
    if (count > 1u) {
        /* stop-tran token; the busy may start one byte late */
        if (apb_spi_tx(sd->spi, sd->cs, 1u, 8u, 0xFDu, APB_SPI_HOLD) != APB_SPI_OK ||
            poll_until(sd, 0xFFu, 0xFFu, 1u, APB_SPI_HOLD, &b) != APB_SPI_SD_OK ||
            poll_until(sd, 0xFFu, 0x00u, SD_BUSY_POLLS, APB_SPI_HOLD, &b) != APB_SPI_SD_OK)
            return fail(sd, APB_SPI_SD_ERR_TIMEOUT);
    }
    ent(&e[0], TX8(sd->cs, 0u), 0xFFu, 0);       /* release the select */
    ent(&e[1], TRAIL, 7u, 0);
    (void) apb_spi_run(sd->spi, e, 2u);
    return APB_SPI_SD_OK;
}
