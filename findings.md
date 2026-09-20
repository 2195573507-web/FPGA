# Findings

## Confirmed Current Facts

- 项目目标板为 `RK3568_MES2L100H`，核心组合为 RK3568J + `PG2L100H`。
- 团队计划使用 HDMI 输入，不使用 OV5640 摄像头作为首版主输入。
- 厂商赛题架构建议明确推荐 FMC 转 HDMI 子卡接入 1080P 视频，并建议 FPGA 通过 PCIe DMA 向 RK3568 内存传输 ROI 或处理后的帧。
- 本地官方历程主要是 `MES50HP + PGL50H` 例程，只能作为协议、视频、DDR3、PCIe 和外设移植参考。
- 单路 HDMI 可以作为基础闭环；四路高阶要求需要四路独立输入硬件和独立通道证据。

## Recommended Baseline

- FPGA：HDMI RX、像素捕获、DDR3 帧缓存、实时预处理、特征/候选提取、快速状态和 PCIe DMA。
- RK3568：PCIe 驱动、结果消费、RKNN/CPU 高层目标分类与场景理解、决策状态机和 OSD。
- 系统：先用模拟前端结果验证 RK3568 高层感知，再替换为 FPGA PCIe DMA 结果。

## Unknowns Requiring Vendor Handoff

- FMC HDMI 子卡型号、HDMI RX 芯片、管脚约束和 PDS 工程；
- PG2L100H PCIe lane 数、端点角色、DMA 示例和 RK3568 驱动；
- RK3568 镜像的 NPU 节点、驱动和 RKNN Runtime 版本；
- 四路输入的实际硬件拓扑、带宽和同步方案。
