# Findings: FPGA IIC Audit

## Confirmed so far

- Active compiled source is under `PGL/Design/source`; the reference `PGL/Fmc`
  copy is not identical for `ms72xx_ctl_card.v`.
- Current `PLL_CLK.v` was modified to target 1 MHz (`STATIC_RATIO0=1200`),
  while `ms72xx_ctl_card.v` still instantiates `i2c_dri` with `CLK_FREQ=25 MHz`.
- The IIC master actively drives SDA high and SCL is a push-pull output; this is
  not an open-drain I2C implementation and has no clock-stretch/bus-stuck path.
- `i2c_ack` is generated but never consumed by the configuration controllers;
  transactions advance and initialization can complete after NACKs.
- The constraint comment says `fmc_la_p33=SCL, fmc_la_n33=SDA`, while RTL maps
  `iic_sda` to `fmc_la_p33` and `iic_scl` to `fmc_la_n33`.
- PDS logs contain timing warnings that both IIC ports are unconstrained and
  auto-create a 1 us period clock for the modified PLL output.
