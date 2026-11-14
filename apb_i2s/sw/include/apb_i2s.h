/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_i2s.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * I2S driver API.
 *
 *   apb_i2s_init                      bind a handle, read and check INFO
 *   apb_i2s_rate                      choose MDIV / RATIO for a sample rate
 *   apb_i2s_configure                 clocks, format, MCLK, RX_DLY (engine stopped)
 *   apb_i2s_start / apb_i2s_stop      run / stop the engine and the streams
 *   apb_i2s_write / apb_i2s_read      move words to / from the FIFOs (non-blocking)
 *   apb_i2s_tx_level / _rx_level      FIFO levels (inline)
 *   apb_i2s_flush                     empty a FIFO
 *   apb_i2s_set_thresholds            TX_THR / RX_THR
 *   apb_i2s_irq_enable / _pending / _clear   interrupts (inline)
 *   apb_i2s_set_access / _get_access  MDELEG privilege gates (Machine mode only)
 *
 * The driver keeps no global state: every call takes the device handle filled
 * by apb_i2s_init() and only touches the IP's registers.
 *
 * Words. Stereo: [15:0] left, [31:16] right. Mono (APB_I2S_MONO_*): [15:0]
 * sample n, [31:16] sample n+1, so an int16_t buffer streams with word
 * accesses. TXDATA takes whole words only.
 *
 * Starting and stopping. apb_i2s_configure() needs the engine stopped
 * (apb_i2s_running() false): CLKDIV and FORMAT writes are ignored otherwise.
 * apb_i2s_stop() clears the streams, waits for both to go inactive (the
 * frames in progress complete, the last one is silence), clears EN and waits
 * for STATUS.RUNNING to fall. Devices want some frames of zeros before a stop
 * or a rate change: call apb_i2s_stop() with an empty transmit FIFO, or clear
 * the stream first. apb_i2s_configure() rejects an rx_dly beyond the capture
 * window (rx_dly + 2 > 2 * MDIV * RATIO / (2 * S), S the slot width). A stopped BCLK or a static MCLK puts most devices in standby.
 *
 * Privilege. As apb_gpio: with the default MDELEG_RST only Machine mode may
 * access the window; MDELEG itself is Machine mode only.
 *----------------------------------------------------------------------------*/
#ifndef APB_I2S_H
#define APB_I2S_H

#include <stdbool.h>
#include <stdint.h>
#include "apb_i2s_regs.h"

typedef enum {
    APB_I2S_OK = 0,
    APB_I2S_ERR_PARAM,                      /* bad argument                      */
    APB_I2S_ERR_ABSENT,                     /* INFO does not describe an apb_i2s */
    APB_I2S_ERR_BUSY,                       /* the engine is running             */
    APB_I2S_ERR_RATE                        /* no divider reaches the rate       */
} apb_i2s_status_t;

typedef enum {                              /* FORMAT presets */
    APB_I2S_FMT_I2S      = APB_I2S_FORMAT_DELAY,
    APB_I2S_FMT_I2S_16   = APB_I2S_FORMAT_DELAY | APB_I2S_FORMAT_SLOT16,
    APB_I2S_FMT_LJ       = APB_I2S_FORMAT_LRCK_INV,
    APB_I2S_FMT_RJ16     = APB_I2S_FORMAT_LRCK_INV | APB_I2S_FORMAT_RJUST,
    APB_I2S_FMT_DSP_A    = APB_I2S_FORMAT_FSYNC | APB_I2S_FORMAT_DELAY,
    APB_I2S_FMT_DSP_B    = APB_I2S_FORMAT_FSYNC
} apb_i2s_format_t;

typedef enum {                              /* stream sample packing */
    APB_I2S_STEREO       = 0,
    APB_I2S_MONO_LEFT    = 1,               /* mono; receive keeps the left slot  */
    APB_I2S_MONO_RIGHT   = 2,               /* mono; receive keeps the right slot */
    APB_I2S_MONO_AVERAGE = 3                /* mono; receive keeps (L + R) / 2    */
} apb_i2s_packing_t;

typedef struct {                            /* apb_i2s_rate() result, apb_i2s_configure() input */
    uint16_t mdiv;                          /* MCLK half-period in pclk cycles, 1 .. 256 */
    uint16_t ratio;                         /* MCLK / LRCK: 256, 384, 512, 768, 1024     */
} apb_i2s_clocks_t;

typedef struct {                            /* apb_i2s_configure() arguments */
    apb_i2s_clocks_t  clocks;
    uint32_t          format;               /* apb_i2s_format_t, optionally | APB_I2S_FORMAT_BCLK_INV ... */
    bool              mclk;                 /* drive i2s_mclk_o                          */
    uint8_t           rx_dly;               /* receive sampling point, 0 .. min(15, 2H - 2) */
    apb_i2s_packing_t tx_packing;
    apb_i2s_packing_t rx_packing;
} apb_i2s_config_t;

typedef enum {                              /* MDELEG WR_PRIV / RD_PRIV: lowest admitted privilege */
    APB_I2S_PRIV_USER       = 0u,
    APB_I2S_PRIV_SUPERVISOR = 1u,
    APB_I2S_PRIV_MACHINE    = 3u
} apb_i2s_priv_t;

typedef struct {                            /* MDELEG content */
    apb_i2s_priv_t wr_priv;
    apb_i2s_priv_t rd_priv;
    bool           error_response;          /* RESP: PSLVERR (true) or silent drop */
} apb_i2s_access_t;

typedef struct {                            /* device handle */
    APB_I2S_TypeDef *regs;
    uint16_t         tx_depth;              /* 0: no transmit path */
    uint16_t         rx_depth;              /* 0: no receive path  */
} apb_i2s_t;

apb_i2s_status_t apb_i2s_init(apb_i2s_t *dev, uintptr_t base);

/* Closest MDIV / RATIO to fs_hz from pclk_hz, among the ratios in
 * ratio_mask (bit 0: 256, 1: 384, 2: 512, 3: 768, 4: 1024; 0 = all);
 * *actual_hz (optional) receives the rate obtained. */
apb_i2s_status_t apb_i2s_rate(uint32_t pclk_hz, uint32_t fs_hz, uint32_t ratio_mask,
                              apb_i2s_clocks_t *clocks, uint32_t *actual_hz);

apb_i2s_status_t apb_i2s_configure(apb_i2s_t *dev, const apb_i2s_config_t *cfg);
apb_i2s_status_t apb_i2s_start(apb_i2s_t *dev, bool tx, bool rx);
void             apb_i2s_stop(apb_i2s_t *dev);

/* Push up to n words (returns the number pushed) / pop up to n words. */
unsigned         apb_i2s_write(apb_i2s_t *dev, const uint32_t *words, unsigned n);
unsigned         apb_i2s_read(apb_i2s_t *dev, uint32_t *words, unsigned n);
void             apb_i2s_flush(apb_i2s_t *dev, bool tx, bool rx);
apb_i2s_status_t apb_i2s_set_thresholds(apb_i2s_t *dev, unsigned tx_thr, unsigned rx_thr);

apb_i2s_status_t apb_i2s_set_access(apb_i2s_t *dev, const apb_i2s_access_t *access);
void             apb_i2s_get_access(const apb_i2s_t *dev, apb_i2s_access_t *access);

static inline bool apb_i2s_running(const apb_i2s_t *dev)
{
    return (dev->regs->STATUS & APB_I2S_STATUS_RUNNING_Msk) != 0u;
}

static inline unsigned apb_i2s_tx_level(const apb_i2s_t *dev)
{
    return (dev->regs->STATUS & APB_I2S_STATUS_TX_LEVEL_Msk) >> APB_I2S_STATUS_TX_LEVEL_Pos;
}

static inline unsigned apb_i2s_rx_level(const apb_i2s_t *dev)
{
    return (dev->regs->STATUS & APB_I2S_STATUS_RX_LEVEL_Msk) >> APB_I2S_STATUS_RX_LEVEL_Pos;
}

static inline void apb_i2s_irq_enable(apb_i2s_t *dev, uint32_t mask)
{
    dev->regs->IRQ_EN = mask;
}

static inline uint32_t apb_i2s_irq_pending(const apb_i2s_t *dev)
{
    return dev->regs->IRQ_PEND;
}

static inline void apb_i2s_irq_clear(apb_i2s_t *dev, uint32_t mask)
{
    dev->regs->IRQ_PEND = mask & APB_I2S_IRQ_STICKY;
}

#endif /* APB_I2S_H */
