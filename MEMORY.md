# FPGA 项目记忆文档

> 更新时间：2026-09-20  
> 适用目录：`/Users/zhiqin/Projects/FPGA`  
> 文档性质：项目上下文、稳定决策和验证边界索引，不替代详细设计文档。

## 1. 项目身份与目标

- 目标平台：`RK3568_MES2L100H`，组合为 Rockchip `RK3568J` + logos2 `PG2L100H` FPGA。
- 当前视频输入方向：首版使用 HDMI，不以 OV5640 摄像头作为主输入。
- 首版目标：完成单路 HDMI 输入、FPGA 实时前端、PCIe 数据传输、RK3568 高层感知和决策显示闭环。
- 后续目标：在单路闭环稳定后，再扩展四路独立视频和复杂场景。
- 当前仓库阶段：架构、接口、开源项目和验证门槛已整理；目标板级 PDS、PCIe、HDMI、DDR3、Linux/RKNN 实测仍未完成。

## 2. 当前已确认事实

- 厂商架构建议使用 FMC 转 HDMI 子卡接入 1080P 视频。
- 厂商建议 FPGA 通过 PCIe DMA 将 ROI 或处理后的帧写入 RK3568 内存。
- 本地官方历程主要面向 `MES50HP + PGL50H`，只能作为 HDMI、DDR3、PCIe 和外设移植参考，不能直接视为 `PG2L100H` 工程。
- 单路 HDMI 可以作为基础闭环；四路高阶要求必须有四路独立输入、独立通道标识/缓存/传输和性能证据。
- 当前没有修改 FPGA、Linux、PDS、PCIe 或 RKNN 源代码，也没有由本项目文档证明板级运行成功。

## 3. 已形成的架构边界

```text
FMC HDMI 子卡
    -> FPGA HDMI RX / 采集 / CDC / 预处理 / DDR3
    -> 特征、候选区域、快速状态、告警
    -> PCIe DMA -> RK3568 Linux 驱动 / 结果队列
    -> RKNN/OpenCV 高层感知、融合、决策、OSD、日志
    <- PCIe BAR/PIO、MSI/MSI-X、指令、参数和 ACK/NACK
```

### FPGA 侧主要职责

- HDMI 接收、时序检测、像素捕获和失锁检测；
- CDC、格式转换、缩放/ROI 等确定性预处理；
- DDR3 帧缓存、帧号、CRC、丢帧和错误统计；
- 道路特征、候选区域、快速状态和低延迟安全状态；
- PCIe Endpoint、BAR/PIO、DMA 数据面和硬件侧状态反馈。

### RK3568/Linux 侧主要职责

- PCIe Host、设备树、驱动、BAR、MSI、DMA 映射和缓存一致性；
- 接收并校验 FPGA 结果，完成 RKNN/CPU 高层分类、场景理解和多帧融合；
- 决策状态机、OSD、显示、日志、参数和指令管理。

### 系统集成边界

- PCIe 是主数据链路；PIO/BAR 用于配置、状态、错误和心跳，DMA 用于结果/ROI/帧数据。
- UART/以太网只作为调试、配置或日志辅助链路，不能代替最终高速数据面。
- FPGA 和 RK3568 之间的字段宽度、字节序、版本、CRC、超时、错误码和 buffer ownership 必须在共享接口文件中统一定义。

## 4. 需要冻结的接口方向

以下是当前接口字段方向，具体字段宽度和编码仍以正式共享接口文档为准：

### FPGA -> RK3568 前端结果

```text
result_seq, frame_seq, channel_id, capture_time_us,
feature_type, candidate_type, candidate_count, fast_state,
alarm_code, suggested_action, confidence,
buffer_dma_addr, byte_count, crc32, producer_state
```

### RK3568 -> FPGA 控制消息

```text
start, stop, reset, input_format, roi_enable,
buffer_release_index, heartbeat, test_pattern
```

### RK3568 -> FPGA 高层结果与控制反馈

```text
result_seq, frame_seq, channel_id,
scene_type, final_class, final_confidence,
navigation_action, display_flags, alarm_code
```

所有权规则：FPGA 完成结果和描述符写入后才移交 buffer；RK3568 消费并释放后，FPGA 才能复用。接口一旦冻结，任何字段变更都必须同步升级协议版本和两端实现。

## 5. 证据边界

| 标签 | 含义 | 当前状态 |
|---|---|---|
| `source` | 厂商手册、赛题资料、仓库设计文档 | 已有部分资料 |
| `design` | 当前架构和接口建议 | 已整理，未等同于实测 |
| `build` | PDS、RTL、驱动、应用构建结果 | 尚无本项目目标板构建证据 |
| `bench/device` | 板级 HDMI、PCIe、DMA、NPU 实测 | 未完成 |
| `unknown` | 尚无可靠资料或验证 | 多项待厂商交接 |

重要边界：文档、开源仓库、静态分析或主机编译不能证明目标板已烧录、PCIe 已建链、HDMI 已稳定、DMA 已可靠或 RKNN 已在板端运行。

## 6. 当前关键未知项

开始编写依赖厂商 IP 的最终 HDL/DMA 前，必须确认：

1. FMC HDMI 子卡型号、HDMI RX 芯片、管脚约束、I2C 配置和匹配 PDS 工程；
2. PG2L100H PCIe IP、DMA 示例、约束、lane 数、端点角色、参考时钟和复位方案；
3. DDR3 型号、位宽、控制器配置和可用帧缓存容量；
4. RK3568 Linux 镜像、设备树、PCIe 驱动、NPU 节点和匹配的 RKNN Runtime；
5. HDMI 输出实际走 RK3568 还是 FPGA；
6. 四路输入的真实硬件拓扑、同步方式、带宽和独立缓存条件。

## 7. 推荐实施顺序与验收门槛

```text
M0 资料和版本冻结
 -> M1 时钟/复位/HDMI 直通
 -> M2 DDR3 和 FPGA 预处理
 -> M3 FPGA 特征与场景前端
 -> M4 PCIe PIO/MSI/结果 DMA/指令 ACK
 -> M5 RK3568 显示、记录和控制联调
 -> M6 单路基础闭环
 -> M7 四路和复杂场景扩展
```

- `G0`：拿到匹配的 PDS、PCIe IP/DMA、HDMI RX、DDR3 工程、Linux/驱动和 RKNN 版本；
- `G1`：HDMI 分辨率/帧率/锁定、直通、DDR3 CRC 和复位恢复正确；
- `G2`：PCIe 枚举、BAR/PIO、版本/状态寄存器和复位行为正确；
- `G3`：已知模式和真实结果 DMA 的长度/CRC/ownership 正确，连续 1000 次无错误；
- `G4`：FPGA 前端结果与帧号对齐，RK3568 可完成高层感知、融合和决策；
- `G5`：单路 HDMI -> FPGA -> DMA -> RK3568 -> 决策/显示连续运行稳定；
- `G6`：四路具备独立 `channel_id`、帧号、缓存、DMA、结果消费和故障隔离证据。

核心原则：先证明数据正确，再优化吞吐；先完成单路闭环，再扩展四路；先冻结协议，再并行开发。

## 8. 文档索引与权威顺序

### 详细设计和当前基线

- [FPGA与RK3568任务分工及通信接口设计.md](./FPGA与RK3568任务分工及通信接口设计.md)：当前架构、通信、ownership、错误恢复和 G0-G6。
- [赛题三快速上手开发手册.md](./赛题三快速上手开发手册.md)：知识体系、学习顺序、开发环境和完成定义。
- [赛题三三人分工与完成顺序.md](./赛题三三人分工与完成顺序.md)：团队职责、里程碑和共享接口。

### 研究和过程记录

- [findings.md](./findings.md)：确认事实、推荐基线和未知项。
- [notes.md](./notes.md)：硬件手册、官方资料和开源研究笔记。
- [progress.md](./progress.md)：按日期记录的项目进展。
- [task_plan.md](./task_plan.md)：研究任务和阶段完成情况。
- [官方历程能力与赛题三映射.md](./官方历程能力与赛题三映射.md)：官方例程能力边界。
- [开源项目链接汇总.md](./开源项目链接汇总.md)：固定版本、许可证和采用边界。
- [rk3568_pg2l100h_open_source_research.md](./rk3568_pg2l100h_open_source_research.md)：开源项目研究和 bring-up gates。

### 权威规则

1. 当前目标板资料、实际源码、构建配置和板级证据优先于本记忆文档；
2. 本文只汇总已存在的项目决策，不创建第二套协议或寄存器定义；
3. 发现冲突时保留原文并更新本索引的状态和日期，不静默覆盖历史结论；
4. 每次更新应记录日期、变更原因、证据来源和验证范围。

## 9. 下一步默认动作

1. 完成 `G0` 厂商资料交接和版本冻结；
2. 确认目标板实物、FMC HDMI 子卡、PDS 工程和 PCIe/DMA 资料；
3. 先验证 HDMI 直通、DDR3 读写和 PCIe PIO，再开始真实 DMA；
4. 以单路已知模式和单帧结果建立第一条可重复的端到端证据链；
5. 所有验证结果分别记录为 `source`、`build`、`bench/device` 或 `unknown`，不跨证据类型推断。
