# Findings: 1080p60 方案审计

## Initial context

- 目标文档：`D:\FPGA\docs\1080p60_视频压缩解压方案.md`
- 目标平台：RK3568_MES2L100H + PG2L100H
- 既有项目记忆要求：区分官方能力、活动源代码/构建证据和实板证据；HDMI/FMC、IIC、PCIe 和 `.sbit` 不能仅凭生成物宣称已验证。

## Pending evidence

- `codec_budget_1080p60.py` 的真实位置、实现和输出。
- 方案引用的板卡手册、PHY/FPGA 工程和约束。
- 端到端 FPGA/UDP/实板运行日志。
