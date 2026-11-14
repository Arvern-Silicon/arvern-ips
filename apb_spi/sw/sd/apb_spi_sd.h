/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_spi_sd.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * An SD memory card in SPI mode on an apb_spi chip select, written only with
 * apb_spi entries (SD Physical Layer Simplified Specification, chapter 7).
 *
 *   apb_spi_sd_init     power-up clocks, CMD0, CMD8, ACMD41, CMD58 (CMD16 on a
 *                       standard-capacity card) at the identification rate,
 *                       then the data rate
 *   apb_spi_sd_read     CMD17, or CMD18 ... CMD12 for several blocks
 *   apb_spi_sd_write    CMD24, or CMD25 ... stop-tran token for several blocks
 *
 * Blocks are 512 bytes, passed as 128 words in little-endian byte order (byte
 * 0 of the block in bits 7:0 of word 0): the session runs with CTRL.BSWAP, so
 * words stream to and from memory with plain stores and loads. Commands go out
 * as single bytes, which BSWAP leaves alone. The card stays in its default
 * CRC-off mode: CMD0 and CMD8 carry their constant CRCs, data is not
 * protected.
 *
 * The functions own the apb_spi instance while they run (mode, rate, select
 * timing, FIFOs); they block until the card answers or a bounded wait runs
 * out, and on an error abort the transaction, so the card is re-initialised
 * by the caller.
 *----------------------------------------------------------------------------*/
#ifndef APB_SPI_SD_H
#define APB_SPI_SD_H

#include <stdbool.h>
#include <stdint.h>
#include "apb_spi.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    APB_SPI_SD_OK          =  0,
    APB_SPI_SD_ERR_PARAM   = -1,    /* null pointer, unusable rate, count 0                */
    APB_SPI_SD_ERR_TIMEOUT = -2,    /* no response, or busy for longer than the bounds     */
    APB_SPI_SD_ERR_CARD    = -3,    /* an R1 with an error bit, or an unsupported card     */
    APB_SPI_SD_ERR_DATA    = -4     /* a data-error token, or a write the card refused     */
} apb_spi_sd_status_t;

typedef struct {
    apb_spi_t *spi;
    uint8_t    cs;                  /* chip select of the card                       */
    bool       block_addr;          /* SDHC / SDXC: commands address blocks, not bytes */
    uint32_t   data_hz;             /* data-rate SCK the session runs at             */
} apb_spi_sd_t;

/* Initialise the card on select cs: pclk_hz is the IP's clock, data_hz the
 * SCK wanted after identification (at most 25 MHz in default speed), rx_dly
 * the receive delay for the board (doc "Receive timing") */
apb_spi_sd_status_t apb_spi_sd_init(apb_spi_sd_t *sd, apb_spi_t *spi, uint8_t cs,
                                    uint32_t pclk_hz, uint32_t data_hz, uint8_t rx_dly);

/* count blocks from block `block`, 128 words each */
apb_spi_sd_status_t apb_spi_sd_read(apb_spi_sd_t *sd, uint32_t block, uint32_t *buf, uint32_t count);
apb_spi_sd_status_t apb_spi_sd_write(apb_spi_sd_t *sd, uint32_t block, const uint32_t *buf, uint32_t count);

#ifdef __cplusplus
}
#endif

#endif /* APB_SPI_SD_H */
