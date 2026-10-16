# Files to add to the PDS design

Use `hdmi_fmc_pcie_top` as the top module. Add these RTL files from this
directory to the design:

- `source/hdmi_fmc_pcie_top.v`
- `source/hdmi_fmc_pcie_video_bridge.v`
- `source/video_rgb888_axis_fifo.v`
- `source/video_dma_stream_source.v`
- `source/ips2l_pcie_dma_mwr_tx_ctrl_video.v`
- `source/ips2l_pcie_dma_tx_top_video.v`
- `source/ips2l_pcie_dma_video.v`

The video DMA wrapper exposes `o_video_request` as the request start pulse and
`o_video_active` as the whole MWR transfer busy interval. Connect both to the
bridge: request starts the FIFO reader, active gates pixel capture.

The HDMI receiver RTL is already included under `source/`:

- `source/hdmi_fmc_rx_top.v`
- `source/hdmi_fmc_rx_top_diffclk.v`
- `source/video_timing_detector.v`
- `source/i2c_dri.v`
- `source/i2c_ms7200_cfg.v`
- `source/i2c_ms7210_cfg.v`
- `source/ms72xx_ctl_card.v`
- `source/PLL_CLK.v`

The complete vendor PCIe RTL tree and generated `pcie_test.v` and
`pcie_test.idf` are already included below
`deps/pcie_dma_test_100h/ipcore/pcie_test/`. The original DMA wrapper files may
remain in that tree, but the top level must instantiate
`ips2l_pcie_dma_video`; do not instantiate the original `ips2l_pcie_dma`
wrapper or the original DMA TX top for the video path.

Add `constraints/hdmi_fmc_pcie_video_merged.fdc` and the FMC constraints that
match the actual carrier schematic. The short
`constraints/hdmi_fmc_pcie_video.fdc` only defines the FMC pixel clock and is
not a complete pin constraint file.

The `.tcl`, `.py`, and `.md` files are helper/documentation files. They are
not RTL design sources and should not be added as Verilog design units.

## Required PDS IP setting

Open the `pcie_test` IP configuration in PDS and enable BAR1. Regenerate the
IP before compiling. The checked-in example currently contains
`BAR1_ENABLED = 1'b0`, so copying that generated file unchanged will make
the BAR1 DMA command registers inaccessible. BAR2 is optional for this video
path.

## Host command format

For each transfer, write the endpoint BAR1 registers in this order:

1. `0x110`: destination physical address low 32 bits.
2. `0x120`: destination physical address high 32 bits when bit 16 is set.
3. `0x100`: command, with bit 24 set for FPGA-to-host, bit 16 selecting a
   64-bit address, and bits `[9:0]` equal to DWORD count minus one.

Use a 16-byte aligned address and a DWORD count divisible by four. Split at
4 KiB boundaries in the RK3568 driver. The current FPGA buffer is a small
proof-of-concept FIFO, not a full-frame DDR buffer.
