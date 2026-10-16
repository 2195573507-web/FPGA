# PG2L100H PCIe 彩条测试工程

当前默认顶层为 `hdmi_fmc_pcie_top`，`USE_TEST_PATTERN=1`。FPGA 在 PCIe
用户时钟域生成 1280x720 八色竖条，经 BAR1 命令驱动的 PCIe MWR 发送到 RK3568。
每个像素占一个 DWORD，值为 `00RRGGBB`；颜色顺序为白、黄、青、绿、品红、红、蓝、黑。
默认测试不需要 HDMI/FMC 输入。HDMI 接收代码通过 generate 分支保留，未在本次验证范围内。

目录：`source/` 是 RTL，`deps/` 是随项目提供的 Pango IP，`constraints/` 是现有板级约束，
`tests/` 是仿真，`host/` 是寄存器定义。RK 配套代码位于
`D:/FPGA/RK3568/pcie_colorbar`，协议说明见 `source/README_PCIE_VIDEO.md`。

在 PowerShell 中重新完整编译：

```powershell
& 'D:\Program Files\bin\pds_shell.exe' `
  -file 'D:\FPGA\PGL\Design\compile_hdmi_fmc_pcie.tcl' `
  -work_dir 'D:\FPGA\PGL\Design\build_my_colorbar'
```

脚本根据自身路径定位源码，可移动整个源码目录后修改命令中的路径。
执行 compile、synthesize、dev_map、pnr、report_timing、gen_bit_stream。
使用独立的新 build 目录，不需要覆盖或删除已有生成文件。
不要使用旧 `.pds`、`reference_only/` 或旧 `generate_bitstream/` 作为本次结果。

本次最终产物位于 `build_colorbar_20261014_verified/generate_bitstream/hdmi_fmc_pcie_top.sbit`。
PDS 2022.2-SP4.2 完整编译成功，时序摘要为 All Constraints Met。
仍有 Bitstream-2001：SCBV 未设置。当前文件没有足以确定实际板卡配置 Bank 电压的依据，
未猜测设置；烧录前应按实际板卡在 PDS Bit Stream Options / Configuration 中核对该参数。
现有 FMC/L4 约束为 1.8V；SCBV 是单独的配置参数，不能直接用 FMC VADJ 代替。

Linux/WSL 下执行仿真：

```sh
sh tests/run_sim.sh
sh tests/run_rx_sim.sh
```

第二项覆盖实际 RX 译码、BAR1 路由、DMA/TX 包装、两帧彩条、随机阻塞、复位和非法命令。
仿真没有模拟 PCIe 硬核、PHY 或 RK 驱动运行；板端验收仍需使用配套测试程序完成。
