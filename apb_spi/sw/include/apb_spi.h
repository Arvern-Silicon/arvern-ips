/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_spi.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * SPI controller driver API.
 *
 *   apb_spi_init                       bind a handle, read and check CFG
 *   apb_spi_set_rate / _set_clkdiv     serial clock (HALF) and receive delay
 *   apb_spi_set_mode                   clock mode, bit and byte order, lane idle states
 *   apb_spi_set_cs                     chip-select polarity and timing
 *   apb_spi_enable / _disable          CTRL.EN
 *   apb_spi_tx / _rx / _dummy / _poll  push one entry (save and restore XFER)
 *   apb_spi_run                        push a list of entries and collect what they receive
 *   apb_spi_push / _pop / _status / _tx_level / _rx_level / _idle  (inline)
 *   apb_spi_wait_idle                  wait for STATUS.IDLE
 *   apb_spi_set_thresholds, apb_spi_irq_enable / _disable / _pending / _clear
 *   apb_spi_flush / apb_spi_abort      CMD
 *   apb_spi_set_access / _get_access   MDELEG privilege gates (Machine mode only)
 *
 * The driver keeps no global state: every call takes the device handle filled
 * by apb_spi_init().
 *
 * Entries. A transaction is a sequence of entries under one chip select; an
 * entry with APB_SPI_HOLD keeps the select for the next one. The builders wait
 * for room in the transmit FIFO; an entry that receives needs the receive
 * FIFO drained, so a transaction that receives more words than the FIFO holds
 * either pops while it pushes or goes through apb_spi_run(), which does both.
 *
 * XFER. A push copies XFER into the entry; XFER and the TXDATA write that
 * uses it are one critical section between software contexts. The builders
 * and apb_spi_run() save XFER and restore it afterwards, so an interrupt
 * handler that uses them does not disturb an interrupted push sequence.
 *
 * Privilege. With the default MDELEG_RST only Machine mode may access the
 * window after reset (APB_SPI_MDELEG_RESET); a build may reset it open. MDELEG
 * itself (apb_spi_set_access, apb_spi_get_access) is Machine mode only. The
 * driver does not read the privilege mode: calling a function from a mode
 * the gates refuse is the caller's error.
 *----------------------------------------------------------------------------*/
#ifndef APB_SPI_H
#define APB_SPI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "apb_spi_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

/*---------------------------------------------------------------------------
 * Types
 *---------------------------------------------------------------------------*/
typedef enum {
    APB_SPI_OK          =  0,
    APB_SPI_ERR_PARAM   = -1,       /* null pointer, misaligned base, value out of range for this build */
    APB_SPI_ERR_ABSENT  = -2,       /* CFG does not hold the expected version at this base             */
    APB_SPI_ERR_TIMEOUT = -3        /* a POLL ran out of frames (POLL_TO), or a wait ran out           */
} apb_spi_status_t;

typedef struct {                    /* apb_spi_init() arguments */
    uintptr_t base;                 /* register window, word aligned */
} apb_spi_config_t;

typedef struct {                    /* device handle, filled from CFG */
    APB_SPI_TypeDef *regs;
    uint16_t     tx_depth;          /* transmit FIFO entries      */
    uint16_t     rx_depth;          /* receive FIFO words (0: no receive path) */
    uint8_t      cs_nr;             /* chip selects               */
    uint8_t      lanes_max;         /* 1, 2 or 4                  */
    bool         poll;              /* POLL entries supported     */
} apb_spi_t;

/* Mode flags of apb_spi_set_mode() (CTRL bits; EN is kept) */
#define APB_SPI_MODE_0          0u
#define APB_SPI_MODE_1          APB_SPI_CTRL_CPHA_Msk
#define APB_SPI_MODE_2          APB_SPI_CTRL_CPOL_Msk
#define APB_SPI_MODE_3          (APB_SPI_CTRL_CPOL_Msk | APB_SPI_CTRL_CPHA_Msk)
#define APB_SPI_LSB_FIRST       APB_SPI_CTRL_LSB_FIRST_Msk
#define APB_SPI_BSWAP           APB_SPI_CTRL_BSWAP_Msk
#define APB_SPI_IDLE_LOW        (APB_SPI_CTRL_TX_IDLE_LOW  << APB_SPI_CTRL_TX_IDLE_Pos)
#define APB_SPI_IDLE_HIGH       (APB_SPI_CTRL_TX_IDLE_HIGH << APB_SPI_CTRL_TX_IDLE_Pos)
#define APB_SPI_IDLE_RELEASE    (APB_SPI_CTRL_TX_IDLE_REL  << APB_SPI_CTRL_TX_IDLE_Pos)
#define APB_SPI_RX_IO0          APB_SPI_CTRL_RX_IO0_Msk     /* 3-wire: receive on IO0 */
#define APB_SPI_IO23_RELEASE    APB_SPI_CTRL_IO23_REL_Msk
#define APB_SPI_LOOPBACK        APB_SPI_CTRL_LOOPBACK_Msk

/* Entry flags */
#define APB_SPI_HOLD            APB_SPI_XFER_CS_HOLD_Msk    /* keep the select for the next entry */
#define APB_SPI_NO_CS           APB_SPI_XFER_CS_NONE_Msk    /* clock with every select inactive   */
#define APB_SPI_CAPT            APB_SPI_XFER_CAPT_Msk       /* TX, single lane: also receive      */

/* An XFER word: kind, frame length 1-32, lanes 1 / 2 / 4, flags, select */
#define APB_SPI_XFER(kind, bits, lanes, flags, sel) \
    ((uint16_t) (((uint32_t) (kind) << APB_SPI_XFER_KIND_Pos) | ((uint32_t) ((bits) - 1u) & APB_SPI_XFER_BITS_Msk) | \
     (((lanes) == 4u ? 2u : (lanes) == 2u ? 1u : 0u) << APB_SPI_XFER_LANES_Pos) | (uint32_t) (flags) | \
     (((uint32_t) (sel) << APB_SPI_XFER_CS_SEL_Pos) & APB_SPI_XFER_CS_SEL_Msk)))

/* A POLL payload: frames allowed (1-65536), mask, value */
#define APB_SPI_POLL_ARG(frames, mask, value) \
    (((uint32_t) (mask) << APB_SPI_POLL_MASK_Pos) | ((uint32_t) (value) << APB_SPI_POLL_VALUE_Pos) | \
     (((uint32_t) (frames) - 1u) & APB_SPI_POLL_COUNT_Msk))

typedef struct {                    /* one entry of apb_spi_run() */
    uint16_t  xfer;                 /* APB_SPI_XFER(...)                                   */
    uint32_t  data;                 /* TX payload; RX / DUMMY count - 1; POLL APB_SPI_POLL_ARG */
    uint32_t *dst;                  /* where the words it receives go (NULL: discard them) */
} apb_spi_entry_t;

typedef enum {                      /* MDELEG WR_PRIV / RD_PRIV: lowest admitted privilege */
    APB_SPI_PRIV_U = APB_SPI_PRIV_CODE_U,
    APB_SPI_PRIV_S = APB_SPI_PRIV_CODE_S,
    APB_SPI_PRIV_M = APB_SPI_PRIV_CODE_M
} apb_spi_priv_t;

typedef struct {                    /* MDELEG content */
    apb_spi_priv_t wr_priv;
    apb_spi_priv_t rd_priv;
    bool           error_resp;      /* true: PSLVERR on a refused access; false: silent drop */
} apb_spi_access_t;

/*---------------------------------------------------------------------------
 * Set-up
 *---------------------------------------------------------------------------*/
apb_spi_status_t apb_spi_init(apb_spi_t *dev, const apb_spi_config_t *cfg);

/* SCK = pclk / (2 * HALF), HALF the smallest that keeps SCK at or below sck_hz
 * (1-4096); rx_dly: receive sampling point, pclk cycles after the sampling edge */
apb_spi_status_t apb_spi_set_rate(apb_spi_t *dev, uint32_t pclk_hz, uint32_t sck_hz, uint8_t rx_dly);
apb_spi_status_t apb_spi_set_clkdiv(apb_spi_t *dev, uint16_t half, uint8_t rx_dly);

/* Clock mode, order and lane idle states (APB_SPI_MODE_x | APB_SPI_IDLE_x | ...);
 * latched at each transaction start */
void apb_spi_set_mode(apb_spi_t *dev, uint32_t mode);

/* Select polarity (bit n = 1: select n active high) and timing in half-periods (1-16) */
apb_spi_status_t apb_spi_set_cs(apb_spi_t *dev, uint8_t cs_pol, uint8_t setup, uint8_t hold, uint8_t inact);

static inline void apb_spi_enable(apb_spi_t *dev)  { dev->regs->CTRL_SET = APB_SPI_CTRL_EN_Msk; }
static inline void apb_spi_disable(apb_spi_t *dev) { dev->regs->CTRL_CLR = APB_SPI_CTRL_EN_Msk; }

/*---------------------------------------------------------------------------
 * Entries
 *---------------------------------------------------------------------------*/
static inline uint32_t apb_spi_status(const apb_spi_t *dev) { return dev->regs->STATUS; }
static inline uint32_t apb_spi_tx_level(const apb_spi_t *dev)
{ return (dev->regs->STATUS & APB_SPI_STATUS_TX_LEVEL_Msk) >> APB_SPI_STATUS_TX_LEVEL_Pos; }
static inline uint32_t apb_spi_rx_level(const apb_spi_t *dev)
{ return (dev->regs->STATUS & APB_SPI_STATUS_RX_LEVEL_Msk) >> APB_SPI_STATUS_RX_LEVEL_Pos; }
static inline bool     apb_spi_idle(const apb_spi_t *dev) { return (dev->regs->STATUS & APB_SPI_STATUS_IDLE_Msk) != 0u; }
static inline uint32_t apb_spi_pop(apb_spi_t *dev) { return dev->regs->RXDATA; }

/* Raw push: XFER and TXDATA, no check, no wait (the caller owns XFER) */
static inline void apb_spi_push(apb_spi_t *dev, uint16_t xfer, uint32_t data)
{
    dev->regs->XFER   = xfer;
    dev->regs->TXDATA = data;
}

/* One entry on select sel (lanes 1 / 2 / 4, frame length 1-32 bits); waits
 * for room in the transmit FIFO */
apb_spi_status_t apb_spi_tx(apb_spi_t *dev, uint8_t sel, uint8_t lanes, uint8_t bits, uint32_t data, uint32_t flags);
apb_spi_status_t apb_spi_rx(apb_spi_t *dev, uint8_t sel, uint8_t lanes, uint8_t bits, uint32_t frames, uint32_t flags);
apb_spi_status_t apb_spi_dummy(apb_spi_t *dev, uint8_t sel, uint8_t lanes, uint32_t clocks, uint32_t flags);
apb_spi_status_t apb_spi_poll(apb_spi_t *dev, uint8_t sel, uint8_t lanes, uint8_t bits, uint32_t frames,
                              uint8_t mask, uint8_t value, uint32_t flags);

/* Push n entries as room frees up and store the words each receives at its
 * dst, until all are pushed and received; APB_SPI_ERR_TIMEOUT if a POLL of
 * the list ran out of frames (its last frame is stored all the same). */
apb_spi_status_t apb_spi_run(apb_spi_t *dev, const apb_spi_entry_t *e, size_t n);

/* Wait for STATUS.IDLE (bus free, transmit FIFO empty), popping nothing */
apb_spi_status_t apb_spi_wait_idle(apb_spi_t *dev, uint32_t max_polls);

/*---------------------------------------------------------------------------
 * Interrupts and commands
 *---------------------------------------------------------------------------*/
apb_spi_status_t apb_spi_set_thresholds(apb_spi_t *dev, uint16_t tx_thr, uint16_t rx_thr);
static inline void     apb_spi_irq_enable(apb_spi_t *dev, uint32_t mask)  { dev->regs->IRQ_EN_SET = mask; }
static inline void     apb_spi_irq_disable(apb_spi_t *dev, uint32_t mask) { dev->regs->IRQ_EN_CLR = mask; }
static inline uint32_t apb_spi_irq_pending(const apb_spi_t *dev)          { return dev->regs->IRQ_PEND; }
static inline void     apb_spi_irq_clear(apb_spi_t *dev, uint32_t mask)   { dev->regs->IRQ_PEND = mask & APB_SPI_IRQ_STICKY; }

/* CMD: empty the transmit and / or receive FIFO; abort the transaction (the
 * frame in flight completes, the select is released, the transmit FIFO empties) */
static inline void apb_spi_flush(apb_spi_t *dev, bool tx, bool rx)
{ dev->regs->CMD = (tx ? APB_SPI_CMD_TX_FLUSH : 0u) | (rx ? APB_SPI_CMD_RX_FLUSH : 0u); }
static inline void apb_spi_abort(apb_spi_t *dev) { dev->regs->CMD = APB_SPI_CMD_ABORT; }

/*---------------------------------------------------------------------------
 * Privilege gates (Machine mode only)
 *---------------------------------------------------------------------------*/
apb_spi_status_t apb_spi_set_access(apb_spi_t *dev, const apb_spi_access_t *access);
void             apb_spi_get_access(const apb_spi_t *dev, apb_spi_access_t *access);

#ifdef __cplusplus
}
#endif

#endif /* APB_SPI_H */
