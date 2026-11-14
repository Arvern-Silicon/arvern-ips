/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern System IPs
 *         / \__/ \          File:      apb_gpio.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Set-up, input / wake enables, direction, interrupt configuration and the
 * MDELEG gates. Pin value and pending
 * accesses are the inline functions of apb_gpio.h.
 *----------------------------------------------------------------------------*/
#include "apb_gpio.h"

static void reg_modify(APB_GPIO_IO uint32_t *reg, uint32_t mask, bool set)
{
    uint32_t v = *reg;
    *reg = set ? (v | mask) : (v & ~mask);
}

#define FIELD_GET(v, f)  (((v) & f##_Msk) >> f##_Pos)

apb_gpio_status_t apb_gpio_init(apb_gpio_t *dev, const apb_gpio_config_t *cfg)
{
    if (!dev || !cfg || !cfg->base || (cfg->base & 3u) || (cfg->pin_nr > APB_GPIO_PIN_NR_MAX) ||
        (cfg->alt_nr > APB_GPIO_ALT_NR_MAX))
        return APB_GPIO_ERR_PARAM;

    APB_GPIO_TypeDef *regs = (APB_GPIO_TypeDef *) cfg->base;
    uint32_t mask      = regs->INFO;
    uint32_t hw_cfg    = regs->CFG;
    uint32_t alt_nr    = FIELD_GET(hw_cfg, APB_GPIO_CFG_ALT_NR);
    uint32_t nr        = 0u;

    if (mask == 0u || (mask & (mask + 1u)) != 0u)   /* not a mask of pins 0 .. n-1 */
        return APB_GPIO_ERR_ABSENT;
    if (FIELD_GET(hw_cfg, APB_GPIO_CFG_VERSION) != APB_GPIO_CFG_VERSION_1 || alt_nr > APB_GPIO_ALT_NR_MAX)
        return APB_GPIO_ERR_ABSENT;
    for (uint32_t m = mask; m; m >>= 1)
        nr++;
    if ((cfg->pin_nr && cfg->pin_nr != nr) || (cfg->alt_nr && cfg->alt_nr != alt_nr))
        return APB_GPIO_ERR_PARAM;

    dev->regs     = regs;
    dev->pin_nr   = (uint8_t) nr;
    dev->pin_mask = mask;
    dev->alt_nr   = (uint8_t) alt_nr;
    return APB_GPIO_OK;
}

static apb_gpio_status_t pins_modify(apb_gpio_t *dev, APB_GPIO_IO uint32_t *reg, uint32_t pins, bool set)
{
    if (pins & ~dev->pin_mask)
        return APB_GPIO_ERR_PARAM;
    reg_modify(reg, pins, set);
    return APB_GPIO_OK;
}

apb_gpio_status_t apb_gpio_input_enable(apb_gpio_t *dev, uint32_t pins)
{
    return pins_modify(dev, &dev->regs->IN_EN, pins, true);
}

apb_gpio_status_t apb_gpio_input_disable(apb_gpio_t *dev, uint32_t pins)
{
    return pins_modify(dev, &dev->regs->IN_EN, pins, false);
}

apb_gpio_status_t apb_gpio_wake_enable(apb_gpio_t *dev, uint32_t pins)
{
    return pins_modify(dev, &dev->regs->WAKE_EN, pins, true);
}

apb_gpio_status_t apb_gpio_wake_disable(apb_gpio_t *dev, uint32_t pins)
{
    return pins_modify(dev, &dev->regs->WAKE_EN, pins, false);
}

apb_gpio_status_t apb_gpio_set_dir(apb_gpio_t *dev, uint32_t pins, apb_gpio_dir_t dir)
{
    if ((pins & ~dev->pin_mask) || (dir != APB_GPIO_DIR_IN && dir != APB_GPIO_DIR_OUT))
        return APB_GPIO_ERR_PARAM;
    if (dir == APB_GPIO_DIR_OUT)
        dev->regs->OE_SET = pins;
    else
        dev->regs->OE_CLR = pins;
    return APB_GPIO_OK;
}

apb_gpio_status_t apb_gpio_irq_config(apb_gpio_t *dev, unsigned pin, apb_gpio_irq_mode_t mode)
{
    if (pin >= dev->pin_nr)
        return APB_GPIO_ERR_PARAM;

    bool rise = (mode == APB_GPIO_IRQ_RISE) || (mode == APB_GPIO_IRQ_BOTH);
    bool fall = (mode == APB_GPIO_IRQ_FALL) || (mode == APB_GPIO_IRQ_BOTH);
    bool high = (mode == APB_GPIO_IRQ_HIGH);
    bool low  = (mode == APB_GPIO_IRQ_LOW);
    if (!rise && !fall && !high && !low && mode != APB_GPIO_IRQ_NONE)
        return APB_GPIO_ERR_PARAM;

    APB_GPIO_TypeDef *r = dev->regs;
    uint32_t      m = APB_GPIO_PIN_Msk(pin);

    /* Old mode off, then its latched edge cleared, then the new mode on: no
     * stale edge survives and no edge of the new mode is cleared. */
    reg_modify(&r->IRQ_RISE, m, false);
    reg_modify(&r->IRQ_FALL, m, false);
    reg_modify(&r->IRQ_HIGH, m, false);
    reg_modify(&r->IRQ_LOW,  m, false);
    r->IRQ_PEND = m;
    if (rise) reg_modify(&r->IRQ_RISE, m, true);
    if (fall) reg_modify(&r->IRQ_FALL, m, true);
    if (high) reg_modify(&r->IRQ_HIGH, m, true);
    if (low)  reg_modify(&r->IRQ_LOW,  m, true);
    return APB_GPIO_OK;
}

apb_gpio_status_t apb_gpio_irq_enable(apb_gpio_t *dev, uint32_t pins)
{
    if (pins & ~dev->pin_mask)
        return APB_GPIO_ERR_PARAM;
    dev->regs->IRQ_EN_SET = pins;
    return APB_GPIO_OK;
}

apb_gpio_status_t apb_gpio_irq_disable(apb_gpio_t *dev, uint32_t pins)
{
    if (pins & ~dev->pin_mask)
        return APB_GPIO_ERR_PARAM;
    dev->regs->IRQ_EN_CLR = pins;
    return APB_GPIO_OK;
}

apb_gpio_status_t apb_gpio_alt_select(apb_gpio_t *dev, uint32_t pins, unsigned func)
{
    if ((pins & ~dev->pin_mask) || (func >= dev->alt_nr))
        return APB_GPIO_ERR_PARAM;

    APB_GPIO_TypeDef *r = dev->regs;

    reg_modify(&r->ALT_EN, pins, false);
    if (dev->alt_nr > 1u)
        reg_modify(&r->ALT_SEL0, pins, (func & 1u) != 0u);
    if (dev->alt_nr > 2u)
        reg_modify(&r->ALT_SEL1, pins, (func & 2u) != 0u);
    reg_modify(&r->ALT_EN, pins, true);
    return APB_GPIO_OK;
}

apb_gpio_status_t apb_gpio_alt_release(apb_gpio_t *dev, uint32_t pins)
{
    if (dev->alt_nr == 0u)
        return APB_GPIO_ERR_PARAM;
    return pins_modify(dev, &dev->regs->ALT_EN, pins, false);
}

static bool priv_valid(apb_gpio_priv_t p)
{
    return p == APB_GPIO_PRIV_U || p == APB_GPIO_PRIV_S || p == APB_GPIO_PRIV_M;
}

apb_gpio_status_t apb_gpio_set_access(apb_gpio_t *dev, const apb_gpio_access_t *access)
{
    if (!dev || !access || !priv_valid(access->wr_priv) || !priv_valid(access->rd_priv))
        return APB_GPIO_ERR_PARAM;

    /* One word store: gates (byte 0) and RESP (byte 1) switch together, no access sees a mix */
    dev->regs->MDELEG = ((uint32_t) access->wr_priv << APB_GPIO_MDELEG_WR_PRIV_Pos) |
                        ((uint32_t) access->rd_priv << APB_GPIO_MDELEG_RD_PRIV_Pos) |
                        (access->error_resp ? APB_GPIO_MDELEG_RESP_Msk : 0u);
    return APB_GPIO_OK;
}

void apb_gpio_get_access(const apb_gpio_t *dev, apb_gpio_access_t *access)
{
    uint32_t v = dev->regs->MDELEG;
    access->wr_priv    = (apb_gpio_priv_t) FIELD_GET(v, APB_GPIO_MDELEG_WR_PRIV);
    access->rd_priv    = (apb_gpio_priv_t) FIELD_GET(v, APB_GPIO_MDELEG_RD_PRIV);
    access->error_resp = (v & APB_GPIO_MDELEG_RESP_Msk) != 0u;
}
