# PCIe 彩条实现说明

用户已授权直接完成代码、编译和打包；烧录、上传和实机测试由用户执行。

1. 顶层 hdmi_fmc_pcie_top，默认 USE_TEST_PATTERN=1；生成 1280x720 八色竖条。
   发生器仅 valid && ready 时推进，FORCE_CAPTURE=1 预填 FIFO 并随背压暂停，
   坐标跨 DMA chunk 保留，不因主机提交间隔而丢弃像素。HDMI 分支保留但本次未验证。
2. 每像素 DWORD=00RRGGBB，四像素/128bit，首像素低 DWORD。
   TLP 按参考代码逐 DWORD 换字节，RK 内存期望 B/G/R/00。
3. BAR1：0x110 地址低位、0x120 高位、最后写 0x100 命令；bit24=MWR、
   bit16=64bit、bits9:0=DWORD数减一。最大1020 DWORD/4080字节；16字节对齐且不跨4KiB。
   BAR1 0x130 bit0 为新增测试源/FIFO复位，保持16个PCIe周期，仅空闲时接受。
4. 实际RX将每个First-DW字节使能扩展4位，因此完整寄存器写检查全部16位。
   修复高地址有效脉冲、地址先写的边界计算、MWR稳定性/TLAST/地址递增和像素打包。
5. 独立RK驱动沿用参考map/write/read/unmap ABI子集，新增INFO/RESET，要求ABI=1。
   使用32位coherent DMA页、A5哨兵到达检测、超时隔离、独占打开及设备移除生命周期保护。
   该完成检测只适用00/FF彩条，不承诺任意实时视频；应用逐DWORD判定数据正确性。
6. 原始参考和旧生成文件保留，新PDS构建目录为build_colorbar_20261014_verified。
   PDS全流程和约束内时序通过；SCBV未设置告警保留，板端烧录前核对实际配置电压。
7. RTL仿真覆盖两完整帧、RX译码/BAR1复位、MPS、阻塞和非法命令；
   RK本机自检与ARM64静态交叉编译通过；驱动仅x86_64内核头文件编译通过。
   没有RK匹配内核构建树，不交付假冒RK模块，板端按uname -r编译驱动。
8. 发布包保存到D:/FPGA/RK3568/packages，含位流、匹配源码、ARM64程序、
   驱动源码、说明、期望图、日志和SHA256SUMS。不能把软件期望图或编译通过当作实机PCIe证据。
