# Standalone compile script for hdmi_fmc_pcie_top.
# It is intentionally self-contained so it can be run after closing PDS.

set design_root [file normalize [file dirname [info script]]]
set pcie_root "$design_root/deps/pcie_dma_test_100h"
set hdmi_root "$design_root"
set addon_root "$design_root"

# Existing HDMI/FMC receiver and video bridge sources.
add_design "$hdmi_root/source/PLL_CLK.v"
add_design "$hdmi_root/source/async_fifo_video.v"
add_design "$hdmi_root/source/video_timing_detector.v"
add_design "$hdmi_root/source/hdmi_fmc_rx_top.v"
add_design "$hdmi_root/source/hdmi_fmc_rx_top_diffclk.v"
add_design "$hdmi_root/source/i2c_dri.v"
add_design "$hdmi_root/source/i2c_ms7200_cfg.v"
add_design "$hdmi_root/source/i2c_ms7210_cfg.v"
add_design "$hdmi_root/source/ms72xx_ctl_card.v"
add_design "$addon_root/source/hdmi_fmc_pcie_top.v"
add_design "$addon_root/source/hdmi_fmc_pcie_video_bridge.v"
add_design "$addon_root/source/ips2l_pcie_dma_mwr_tx_ctrl_video.v"
add_design "$addon_root/source/ips2l_pcie_dma_tx_top_video.v"
add_design "$addon_root/source/ips2l_pcie_dma_video.v"
add_design "$addon_root/source/video_dma_stream_source.v"
add_design "$addon_root/source/video_rgb888_axis_fifo.v"
add_design "$addon_root/source/test_pattern_generator.v"

# Official DMA and UART support RTL used by the integrated top.
add_design "$pcie_root/hdl/pcie_dma_ctrl/fifo/ipm_distributed_sdpram_v1_2_distributed_fifo.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/fifo/pgs_pciex4_fifo_ctrl.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/fifo/pgs_pciex4_fifo_v1_2.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ipm_distributed_sdpram_v1_2.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_expd_apb_mux.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_controller.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_cpld_tx_ctrl.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_mrd_tx_ctrl.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_mwr_tx_ctrl.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_ram/ips2l_pcie_dma_ram.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_ram/rtl/ipm2l_sdpram_v1_1_ips2l_pcie_dma_ram.v"
# init_param.v is included inside the RAM module; it is not a standalone unit.
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_rd_ctrl.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_rx_cpld_wr_ctrl.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_rx_mwr_wr_ctrl.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_rx_top.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_tlp_rcv.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_tlp_tx_mux.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_tx_cpld_rd_ctrl.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_tx_mwr_rd_ctrl.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_tx_top.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma_wr_ctrl.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/ips2l_pcie_dma.v"
add_design "$pcie_root/hdl/pcie_dma_ctrl/pgs_pciex4_prefetch_fifo_v1_2.v"
add_design "$pcie_root/hdl/uart2apb_32bit/fifo/pgm_distributed_fifo_ctr_v1_0.v"
add_design "$pcie_root/hdl/uart2apb_32bit/fifo/pgm_distributed_fifo_v1_1.v"
add_design "$pcie_root/hdl/uart2apb_32bit/fifo/pgm_distributed_sdpram_v1_1.v"
add_design "$pcie_root/hdl/uart2apb_32bit/fifo/pgr_prefetch_fifo.v"
add_design "$pcie_root/hdl/uart2apb_32bit/pgr_apb_ctr_32bit.v"
add_design "$pcie_root/hdl/uart2apb_32bit/pgr_apb_mif_32bit.v"
add_design "$pcie_root/hdl/uart2apb_32bit/pgr_clk_gen_32bit.v"
add_design "$pcie_root/hdl/uart2apb_32bit/pgr_cmd_parser_32bit.v"
add_design "$pcie_root/hdl/uart2apb_32bit/pgr_fifo_top_32bit.v"
add_design "$pcie_root/hdl/uart2apb_32bit/pgr_uart_rx_32bit.v"
add_design "$pcie_root/hdl/uart2apb_32bit/pgr_uart_top_32bit.v"
add_design "$pcie_root/hdl/uart2apb_32bit/pgr_uart_tx_32bit.v"
add_design "$pcie_root/hdl/uart2apb_32bit/pgr_uart2apb_top_32bit.v"

# Generated PCIe wrapper plus the IDF that contains the HSST/PCIe core RTL.
add_design "$pcie_root/ipcore/pcie_test/pcie_test.v"
add_design "$pcie_root/ipcore/pcie_test/pcie_test.idf"

add_constraint "$addon_root/constraints/hdmi_fmc_pcie_video_merged.fdc"
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG484

# PDS 2022.2-SP4.2 uses normal Verilog; include-only parameter files are
# excluded from the standalone source list rather than using config_compile.

compile -top_module hdmi_fmc_pcie_top
synthesize -ads -selected_syn_tool_opt 2
dev_map
pnr
report_timing
gen_bit_stream
