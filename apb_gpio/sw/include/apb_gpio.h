/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_gpio.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * GPIO driver API.
 *
 *   apb_gpio_init                         bind a handle, read and check INFO / CFG
 *   apb_gpio_input_enable / _disable      input enables (IN_EN)
 *   apb_gpio_wake_enable / _disable       wake enables (WAKE_EN)
 *   apb_gpio_set_dir                      output enables (OE)
 *   apb_gpio_write / _set / _clear / _toggle / apb_gpio_read / apb_gpio_read_output
 *                                     pin values (inline)
 *   apb_gpio_irq_config                   one pin's detection mode
 *   apb_gpio_irq_enable / _disable        IRQ_EN
 *   apb_gpio_irq_pending / _status / _clear  IRQ_PEND, IRQ_STAT (inline)
 *   apb_gpio_alt_select / _release        alternate functions (ALT_EN, ALT_SEL0/1)
 *   apb_gpio_set_access / _get_access     MDELEG privilege gates (Machine mode only)
 *
 * The driver keeps no global state: every call takes the device handle filled
 * by apb_gpio_init(), and only touches the IP's registers (the PLIC or the core's
 * interrupt enables live elsewhere).
 *
 * Pin sets are bit masks, bit n = pin n. Bits at or above the instance's pin
 * count are ignored by the hardware.
 *
 * Inputs. A pin is sampled, and raises interrupts or wake requests, only
 * while its IN_EN bit is set; all are clear after reset. After
 * apb_gpio_input_enable() the pin's input stage flushes for 1-3 pclk_aon_i cycles
 * (SYNC_EN): INPUT reads 0 and no event is reported until then.
 *
 * Privilege. With the default MDELEG_RST only Machine mode may access the
 * window after reset (APB_GPIO_MDELEG_RESET); a build may reset it open. An
 * access below the MDELEG gates is refused at every offset: with RESP = 1 it
 * gets PSLVERR, an AHB ERROR behind ahb_apb_bridge (a resumable NMI on
 * aRVern, taken in Machine mode); with RESP = 0 a write is dropped and a read
 * returns 0. MDELEG itself (apb_gpio_set_access, apb_gpio_get_access) is
 * Machine mode only. The driver does not read the privilege mode: calling a
 * function from a mode the gates refuse is the caller's error, including
 * Machine-mode code running with mstatus.MPRV = 1 and MPP below Machine.
 *
 * Atomicity. OUTPUT, OE and IRQ_EN have set / clear aliases, so
 * apb_gpio_set(), apb_gpio_clear(), apb_gpio_toggle(), apb_gpio_set_dir(),
 * apb_gpio_irq_enable() and apb_gpio_irq_disable() are single stores, safe
 * against an interrupt handler working on other pins. IN_EN, WAKE_EN and the
 * mode registers have no such aliases: apb_gpio_input_enable(),
 * apb_gpio_input_disable(), apb_gpio_wake_enable(), apb_gpio_wake_disable()
 * and apb_gpio_irq_config() read-modify-write them and are not atomic against
 * a handler or another manager updating the same register.
 *
 * Open drain. Keep the pin's OUTPUT bit at 0 and switch its direction:
 * APB_GPIO_DIR_OUT pulls the line low, APB_GPIO_DIR_IN releases it to the
 * external pull-up; apb_gpio_read() returns the line itself.
 *----------------------------------------------------------------------------*/
#ifndef APB_GPIO_H
#define APB_GPIO_H

#include <stdbool.h>
#include <stdint.h>
#include "apb_gpio_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

/*---------------------------------------------------------------------------
 * Types
 *---------------------------------------------------------------------------*/
typedef enum {
    APB_GPIO_OK          =  0,
    APB_GPIO_ERR_PARAM   = -1,      /* null pointer, misaligned base, pin out of range, pin count mismatch */
    APB_GPIO_ERR_ABSENT  = -2       /* INFO does not hold a valid pin mask at this base           */
} apb_gpio_status_t;

typedef enum {
    APB_GPIO_DIR_IN  = 0,           /* OE = 0: pin not driven */
    APB_GPIO_DIR_OUT = 1            /* OE = 1: pin driven from OUTPUT */
} apb_gpio_dir_t;

typedef enum {                  /* per-pin interrupt detection mode */
    APB_GPIO_IRQ_NONE = 0,
    APB_GPIO_IRQ_RISE,              /* rising edge, latched  */
    APB_GPIO_IRQ_FALL,              /* falling edge, latched */
    APB_GPIO_IRQ_BOTH,              /* either edge, latched  */
    APB_GPIO_IRQ_HIGH,              /* high level, live      */
    APB_GPIO_IRQ_LOW                /* low level, live       */
} apb_gpio_irq_mode_t;

typedef struct {                /* apb_gpio_init() arguments */
    uintptr_t base;             /* register window, word aligned                   */
    uint8_t   pin_nr;           /* expected GPIO_NR, 1-32; 0 accepts what INFO says */
    uint8_t   alt_nr;           /* expected ALT_NR, 1-4; 0 accepts what CFG says    */
} apb_gpio_config_t;

typedef enum {                  /* MDELEG WR_PRIV / RD_PRIV: lowest admitted privilege */
    APB_GPIO_PRIV_U = APB_GPIO_PRIV_CODE_U,
    APB_GPIO_PRIV_S = APB_GPIO_PRIV_CODE_S,
    APB_GPIO_PRIV_M = APB_GPIO_PRIV_CODE_M
} apb_gpio_priv_t;

typedef struct {                /* MDELEG content */
    apb_gpio_priv_t wr_priv;    /* lowest mode admitted to write           */
    apb_gpio_priv_t rd_priv;    /* lowest mode admitted to read            */
    bool            error_resp; /* true: PSLVERR on a refused access; false: silent drop */
} apb_gpio_access_t;

typedef struct {                /* device handle */
    APB_GPIO_TypeDef *regs;
    uint8_t       pin_nr;       /* GPIO_NR, the width of INFO's mask    */
    uint32_t      pin_mask;     /* INFO: bits 0 .. pin_nr-1 set         */
    uint8_t       alt_nr;       /* alternate functions per pin          */
} apb_gpio_t;

/*---------------------------------------------------------------------------
 * Set-up
 *---------------------------------------------------------------------------*/

/* Bind the handle to the instance at cfg->base. Reads INFO and CFG (two
 * loads, no store): APB_GPIO_ERR_ABSENT unless INFO is a mask of pins 0 .. n-1
 * (n = 1-32) and CFG holds version 1 and an ALT_NR of 0-4; APB_GPIO_ERR_PARAM
 * if cfg->pin_nr or cfg->alt_nr is non-zero and differs from the hardware. The
 * handle is filled on success only. Needs a mode the read gate admits. */
apb_gpio_status_t apb_gpio_init(apb_gpio_t *dev, const apb_gpio_config_t *cfg);

/*---------------------------------------------------------------------------
 * Input and wake enables. APB_GPIO_ERR_PARAM for a pin at or above pin_nr.
 * Read-modify-write of IN_EN / WAKE_EN.
 *---------------------------------------------------------------------------*/

/* Start / stop sampling the pins of mask. Enabling flushes each pin's input
 * stage first, so the step from the held 0 to the pin's level is never
 * reported; disabling stops the pin at once (INPUT 0, no event, no wake). */
apb_gpio_status_t apb_gpio_input_enable(apb_gpio_t *dev, uint32_t pins);
apb_gpio_status_t apb_gpio_input_disable(apb_gpio_t *dev, uint32_t pins);

/* Let a change on the pins of mask raise gpio_wake_o (needs IN_EN too). The
 * wake follows the pin's detection mode: a rising change wakes with RISE,
 * BOTH or HIGH, a falling one with FALL, BOTH or LOW, any change with NONE.
 * The SoC must hold the request (doc "Wake"). */
apb_gpio_status_t apb_gpio_wake_enable(apb_gpio_t *dev, uint32_t pins);
apb_gpio_status_t apb_gpio_wake_disable(apb_gpio_t *dev, uint32_t pins);

/*---------------------------------------------------------------------------
 * Direction
 *---------------------------------------------------------------------------*/

/* Set the pins of mask to dir, leave the others. APB_GPIO_ERR_PARAM for a pin at
 * or above pin_nr. One store to OE_SET or OE_CLR. */
apb_gpio_status_t apb_gpio_set_dir(apb_gpio_t *dev, uint32_t pins, apb_gpio_dir_t dir);

/*---------------------------------------------------------------------------
 * Pin values: one load or store each, not checked.
 *---------------------------------------------------------------------------*/

/* OUTPUT: value driven on every pin */
static inline void apb_gpio_write(apb_gpio_t *dev, uint32_t value)
{
    dev->regs->OUTPUT = value;
}

/* Drive the pins of mask high / low / inverted; the other pins are untouched */
static inline void apb_gpio_set(apb_gpio_t *dev, uint32_t pins)
{
    dev->regs->OUT_SET = pins;
}

static inline void apb_gpio_clear(apb_gpio_t *dev, uint32_t pins)
{
    dev->regs->OUT_CLR = pins;
}

static inline void apb_gpio_toggle(apb_gpio_t *dev, uint32_t pins)
{
    dev->regs->OUT_TGL = pins;
}

/* INPUT: the enabled pins after the input stage (three pclk_aon_i edges
 * behind gpio_i with SYNC_EN=1, one with SYNC_EN=0), whatever their
 * direction; a pin with IN_EN clear, or still flushing, reads 0 */
static inline uint32_t apb_gpio_read(const apb_gpio_t *dev)
{
    return dev->regs->INPUT;
}

/* OUTPUT as last written */
static inline uint32_t apb_gpio_read_output(const apb_gpio_t *dev)
{
    return dev->regs->OUTPUT;
}

/*---------------------------------------------------------------------------
 * Interrupts
 *---------------------------------------------------------------------------*/

/* Set the detection mode of one pin (0 .. pin_nr-1, else APB_GPIO_ERR_PARAM).
 * The pin's old mode bits are cleared first, then its latched edge, then the
 * new mode bits are set: an edge latched under the old mode is discarded and
 * no edge of the new mode is lost. IRQ_EN is left as it is; a level mode whose
 * condition already holds is pending at once. Events need the pin's IN_EN. */
apb_gpio_status_t apb_gpio_irq_config(apb_gpio_t *dev, unsigned pin, apb_gpio_irq_mode_t mode);

/* Gate the pins of mask onto irq_o / irq_any_o, or remove them. An enabled
 * pin that is already pending raises its line at once. APB_GPIO_ERR_PARAM for a
 * pin at or above pin_nr. One store to IRQ_EN_SET or IRQ_EN_CLR. */
apb_gpio_status_t apb_gpio_irq_enable(apb_gpio_t *dev, uint32_t pins);
apb_gpio_status_t apb_gpio_irq_disable(apb_gpio_t *dev, uint32_t pins);

/* IRQ_PEND: latched edges OR live levels, whether enabled or not */
static inline uint32_t apb_gpio_irq_pending(const apb_gpio_t *dev)
{
    return dev->regs->IRQ_PEND;
}

/* IRQ_STAT: the pending pins whose interrupt is enabled, what drives irq_o.
 * A handler reads this, not IRQ_PEND, so it never clears the latched edges of
 * pins software polls. */
static inline uint32_t apb_gpio_irq_status(const apb_gpio_t *dev)
{
    return dev->regs->IRQ_STAT;
}

/* Clear the latched edges of mask (write 1 to clear). A level pending bit is
 * not cleared: remove its cause (the pin, or the mode). An edge arriving in
 * the same cycle stays pending. irq_o drops at the end of the store. */
static inline void apb_gpio_irq_clear(apb_gpio_t *dev, uint32_t pins)
{
    dev->regs->IRQ_PEND = pins;
}

/*---------------------------------------------------------------------------
 * Alternate functions (ALT_NR > 0). Which peripheral signal sits in which
 * function slot of which pin is fixed by the SoC wiring (board support).
 *---------------------------------------------------------------------------*/

/* Hand the pins of mask to alternate function func (0 .. alt_nr-1). The pins
 * are released first, their function number is set while they are under
 * software control, then they are handed over with one ALT_EN write, so they
 * never pass through another function. APB_GPIO_ERR_PARAM for a pin at or above
 * pin_nr or func at or above alt_nr. Read-modify-write of ALT_EN, ALT_SEL0/1. */
apb_gpio_status_t apb_gpio_alt_select(apb_gpio_t *dev, uint32_t pins, unsigned func);

/* Return the pins of mask to OUTPUT / OE. APB_GPIO_ERR_PARAM for a pin at or above
 * pin_nr, or with alt_nr 0. Read-modify-write of ALT_EN. */
apb_gpio_status_t apb_gpio_alt_release(apb_gpio_t *dev, uint32_t pins);

/*---------------------------------------------------------------------------
 * Privilege gates (MDELEG). Machine mode only: from S or U mode the access
 * is refused whatever the gates say.
 *---------------------------------------------------------------------------*/

/* Program both gates and the refusal response in one transfer.
 * APB_GPIO_ERR_PARAM for a null pointer or a privilege code other than U/S/M. */
apb_gpio_status_t apb_gpio_set_access(apb_gpio_t *dev, const apb_gpio_access_t *access);
void              apb_gpio_get_access(const apb_gpio_t *dev, apb_gpio_access_t *access);

#ifdef __cplusplus
}
#endif

#endif /* APB_GPIO_H */
