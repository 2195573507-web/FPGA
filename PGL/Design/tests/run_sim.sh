#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p tests/build
iverilog -g2012 -s tb_pcie_colorbar -o tests/build/colorbar.vvp tests/tb_pcie_colorbar.sv \
 source/test_pattern_generator.v source/video_rgb888_axis_fifo.v source/video_dma_stream_source.v \
 source/hdmi_fmc_pcie_video_bridge.v source/ips2l_pcie_dma_mwr_tx_ctrl_video.v \
 deps/pcie_dma_test_100h/hdl/pcie_dma_ctrl/ips2l_pcie_dma_controller.v
vvp tests/build/colorbar.vvp
