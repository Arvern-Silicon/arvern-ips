<p align="center">
  <img src="../../arv_custom_csr/doc/img/aRVern_light.png" alt="aRVern" width="180">
</p>

# I2S driver library

*Bare-metal C driver for the aRVern serial-audio master: the register overlay, rate
selection, format and stream control, FIFO transfers, thresholds, interrupts and the
`MDELEG` gates.*

| File | Content |
|---|---|
| `include/apb_i2s_regs.h` | Register structure and field macros (`APB_I2S_<REG>_<FIELD>_Pos` / `_Msk`) |
| `include/apb_i2s.h` | Driver API, inline level and interrupt accessors |
| `src/apb_i2s.c` | Set-up, rate selection, stream control, FIFO transfers, `MDELEG` |

The driver keeps no global state and touches only the IP's registers; the PLIC and the
core's interrupt enables live elsewhere. Reference: [`doc/apb_i2s.md`](../doc/apb_i2s.md).

## Example: playing a mono buffer on an I2S amplifier

```c
#include "apb_i2s.h"

static apb_i2s_t i2s;

void audio_init(void)
{
    apb_i2s_config_t cfg = {
        .format     = APB_I2S_FMT_I2S,
        .mclk       = false,                 /* the amplifier needs no MCLK */
        .rx_dly     = 1,
        .tx_packing = APB_I2S_MONO_LEFT,     /* two samples per word, sent in both slots */
        .rx_packing = APB_I2S_STEREO,
    };
    uint32_t fs;

    apb_i2s_init(&i2s, I2S_BASE);
    apb_i2s_rate(PCLK_HZ, 44100u, 0u, &cfg.clocks, &fs);   /* 33.333 MHz: 43.40 kHz */
    apb_i2s_configure(&i2s, &cfg);
    apb_i2s_set_thresholds(&i2s, i2s.tx_depth / 2u, 1u);
}

void audio_play(const int16_t *pcm, unsigned samples)   /* samples even */
{
    const uint32_t *w = (const uint32_t *) pcm;
    unsigned n = samples / 2u;

    n -= apb_i2s_write(&i2s, w, n);          /* prefill */
    apb_i2s_start(&i2s, true, false);
    while (n)                                 /* or from the TX_LOW interrupt */
        n -= apb_i2s_write(&i2s, w + (samples / 2u - n), n);
    while (apb_i2s_tx_level(&i2s))
        ;
    apb_i2s_stop(&i2s);
}
```

## Notes

- `apb_i2s_rate()` searches the `MDIV` / `RATIO` pairs for the closest rate; pass a ratio
  mask to keep to the ratios a device accepts (bit 0: 256 … bit 4: 1024).
- `apb_i2s_configure()` returns `APB_I2S_ERR_BUSY` while the engine runs: `CLKDIV` and
  `FORMAT` writes would be ignored. It returns `APB_I2S_ERR_PARAM` for an `rx_dly` past
  the capture window (`rx_dly + 2 > 2H`, H the `BCLK` half-period in `pclk` cycles).
- `apb_i2s_stop()` clears the streams, waits for `STATUS.TX_ACTIVE` and `RX_ACTIVE` to
  fall (the frames in progress complete; the last one is silence), clears `EN` and waits
  for `STATUS.RUNNING` to fall.
- `TX_LOW` is a level: mask it in `IRQ_EN` once the last words are written, or a
  level-triggered PLIC re-pends after every completion.
