/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_spi_flash.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * A minimal SPI NOR flash reader and programmer (S25FL128S command set, 24-bit
 * addresses) over apb_spi, written only with entries:
 *
 *   apb_spi_flash_status    RDSR1 (05h)
 *   apb_spi_flash_read      Quad I/O Read (EBh: address and mode on four lanes,
 *                           dummy clocks, data on four lanes; mode byte 00h, so
 *                           the flash never enters continuous read mode) on a
 *                           quad build, READ (03h) otherwise
 *   apb_spi_flash_program   WREN (06h), then Quad Page Program (32h) on a quad
 *                           build, Page Program (02h) otherwise, then a POLL on
 *                           WIP; one page (256 bytes) at most, not crossing it
 *
 * Words carry the bytes in flash order, the lowest address in bits 31:24 (no
 * BSWAP). The quad commands need the flash's QUAD configuration bit set, which
 * is the board's set-up, not this file's. The functions run in the mode the
 * caller set (0 or 3) and own the instance while they run.
 *----------------------------------------------------------------------------*/
#ifndef APB_SPI_FLASH_H
#define APB_SPI_FLASH_H

#include <stdbool.h>
#include <stdint.h>
#include "apb_spi.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    apb_spi_t *spi;
    uint8_t    cs;                  /* chip select of the flash                 */
    uint8_t    dummy;               /* EBh dummy clocks for the latency code in use (Table 8.10) */
} apb_spi_flash_t;

apb_spi_status_t apb_spi_flash_status(apb_spi_flash_t *fl, uint8_t *sr1);
apb_spi_status_t apb_spi_flash_read(apb_spi_flash_t *fl, uint32_t addr, uint32_t *buf, uint32_t words);
apb_spi_status_t apb_spi_flash_program(apb_spi_flash_t *fl, uint32_t addr, const uint32_t *buf, uint32_t words);

#ifdef __cplusplus
}
#endif

#endif /* APB_SPI_FLASH_H */
