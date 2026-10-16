# FPGA 与 RK3568 任务分工及通信接口设计

## 1. 文档信息

| 项目 | 内容 |
|---|---|
| 适用平台 | RK3568_MES2L100H：RK3568J + PG2L100H FPGA |
| 适用赛题 | 赛题三：基于 FPGA 的道路环境监测、特定场景感知与 MCU-FPGA 高速通信 |
| 首版目标 | FPGA 完成单路采集、实时预处理和感知前端，RK3568 完成高层感知、决策、通信和显示 |
| 高阶目标 | 四路独立视频感知、结果交互和多通道控制 |
| 主通信链路 | FPGA PCIe Endpoint + RK3568 PCIe Host + DMA |
| 控制辅助链路 | PCIe BAR/PIO、MSI/MSI-X；UART/以太网仅用于调试或低速配置 |
| 文档状态 | 架构和接口建议，尚未完成目标板级实测 |
| 更新时间 | 2026-09-20 |

本文将任务边界、数据流、通信接口、缓冲区 ownership 和验收标准集中整理，作为 FPGA、Linux 驱动和 RK3568 应用的共同基线。文中“MCU/主控”在本平台对应 RK3568 的 ARM/Linux 侧；RK3568 是应用处理器，不是传统裸机 MCU。

## 2. 证据边界

### 2.1 已确认事实

- 目标组合为 RK3568_MES2L100H + PG2L100H。
- 厂商赛题架构建议使用 FMC 转 HDMI 子卡接入 1080P 视频。
- 厂商建议 FPGA 通过 PCIe DMA 将 ROI 或处理后的帧写入 RK3568 内存。
- 本地官方例程主要面向 MES50HP + PGL50H，只能作为 HDMI、DDR3、PCIe 和外设移植参考。
- 首版应先完成单路闭环，再扩展四路输入和复杂场景。
- 赛题以 FPGA 为实时视频处理和感知前端核心；道路监测与场景感知由 FPGA 前端和 RK3568 高层感知协同完成。
- MCU/主控与 FPGA 之间必须完成高速数据交互和指令控制，PCIe 是首选主链路。

### 2.2 必须向厂商确认的事项

| 项目 | 影响 |
|---|---|
| FMC HDMI 子卡型号、RX 芯片、管脚和 I2C 配置 | 决定 HDMI 接收能否落地 |
| PG2L100H PCIe IP、DMA 示例和约束 | 决定 FPGA 端点和 DMA 实现方式 |
| PCIe lane 数、端点角色、参考时钟和复位 | 决定有效吞吐和链路初始化 |
| RK3568 Linux 镜像、设备树、驱动和 NPU Runtime | 决定 BAR、MSI、DMA 和 RKNN 是否匹配 |
| FPGA 侧 HDMI TX 是否可用 | 决定 OSD 放在 RK3568 还是 FPGA |
| 四路输入的真实硬件拓扑 | 决定高阶任务是否具备硬件前提 |

### 2.3 证据标签

- source：厂商手册、本地赛题资料或已固定的源码文档；
- design：本文提出的接口和实现建议；
- build：综合、编译或驱动构建结果；
- bench/device：板级、PCIe、HDMI、DMA 或 NPU 实测结果；
- unknown：尚未获得或尚未验证的信息。

当前本文主要包含 source 和 design，不替代 bench/device 证据。

## 3. 赛题边界和设计原则

### 3.1 主功能归属

| 功能层 | FPGA | RK3568 MCU/主控 |
|---|---|---|
| 道路视频采集 | 主责 | 不直接采集像素流 |
| 像素级并行处理 | 主责 | 不作为实时主路径 |
| 道路特征提取 | 主责，输出特征和候选区域 | 接收特征并做高层解释 |
| 特定场景感知 | 完成实时前端、候选和低延迟状态 | 完成目标分类、场景理解、多帧融合和最终判断 |
| 实时状态/安全输出 | 输出低延迟状态和硬件故障保护 | 完成上层决策、显示和记录，不得覆盖硬件急停 |
| 高速通信 | PCIe Endpoint、DMA、状态寄存器 | PCIe Host、驱动、命令和数据消费 |
| 参数与模式控制 | 执行和反馈 | 配置、下发、保存和管理 |
| 日志、显示和调试 | 提供状态/结果 | 主责 |

本项目不能以“FPGA 只采集视频，RK3568 负责全部识别”作为验收架构；同时也不能把所有复杂场景理解都硬塞进 FPGA。推荐由 FPGA 完成实时前端和候选提取，由 RK3568 完成高层识别、融合和决策。

### 3.2 感知结果优先于原始视频

默认通信内容应是 FPGA 生成的特征、候选区域、快速状态、告警和统计量；原始帧或 ROI 只在以下情况下传输：

- 现场调试、结果复核和录像；
- RK3568 执行可选的复杂算法；
- 模型训练数据采集或故障复现。

这样可以减少 PCIe 带宽、RK 内存和 Linux 驱动压力，同时突出 FPGA 并行处理和确定性响应能力。

## 4. 总体架构

    FMC HDMI 子卡 / 其他视频输入
                |
                v
         FPGA HDMI RX / 采集
                |
                +--> 帧计数、时间戳、CRC、失锁检测
                +--> 格式转换、ROI、缩放、像素流水线
                +--> 道路特征提取、候选生成和快速状态
                +--> 特征/候选结果、告警、实时状态
                |
                v
      FPGA DDR3 / 结果环形缓存
                |
                +<-- PCIe BAR/PIO：配置、状态、错误、心跳
                +--> PCIe DMA：感知结果、统计、可选 ROI/帧
                +<-- MSI/MSI-X：结果就绪、命令完成、错误通知
                |
                v
       RK3568 Linux 驱动 / 命令与结果队列
                |
                +--> 参数、模式和指令下发
                +--> RKNN/NPU/CPU 高层感知与场景理解
                +--> 结果显示、记录和上层决策
                |
                +--> RK3568 HDMI OSD / LED / UART
                +--> PCIe 控制消息回传 FPGA

FPGA 应能在不依赖 Linux 调度和 RKNN 推理的情况下完成实时前端处理、候选提取和本地安全状态输出；RK3568 负责复杂场景的最终解释和决策。RK3568 的命令不能绕过 FPGA 的实时状态机和安全约束。

## 5. 任务分工

### 5.1 FPGA 侧职责

FPGA 是赛题道路环境监测和特定场景感知的实时前端核心，负责从视频输入到特征、候选和低延迟状态的确定性高速处理。

| 模块 | FPGA 工作内容 | 输出或交接 |
|---|---|---|
| 输入接收 | HDMI RX 初始化、锁定、像素时钟、DE/HSYNC/VSYNC 检查 | 有效像素流、分辨率、失锁状态 |
| 帧管理 | 行计数、帧计数、frame_seq、时间戳、帧边界 | 帧元数据 |
| 数据可靠性 | 行计数、长度检查、CRC、丢帧、FIFO 溢出和输入错误统计 | 错误寄存器和描述符状态 |
| 像素预处理 | RGB/YUV/灰度转换、ROI、裁剪、缩放、Letterbox | 感知流水线输入 |
| 道路特征提取 | Sobel、阈值、颜色统计、边缘、行列投影、形态学 | 车道、斑马线、红绿灯和障碍物候选 |
| 感知前端 | 红绿灯/车道/斑马线/障碍物候选、颜色/边缘/几何快速判断和前端状态机 | 特征、候选区域、快速状态、告警 |
| 实时输出 | 本地 LED/告警/状态信号，必要时输出视频叠加信息 | 不依赖 RK 调度的安全状态 |
| 帧/结果缓存 | DDR3 控制、ping-pong/ring buffer、突发读写 | DMA 可读取的帧或结果缓冲区 |
| PCIe Endpoint | BAR 寄存器、DMA 请求、描述符、MSI/MSI-X | RK3568 可访问的控制和数据通道 |
| 故障隔离 | 超时、复位、输入失锁、DMA 错误后的状态收敛 | 可观察的错误码和计数器 |

FPGA 不负责模型训练、RKNN 模型转换、复杂目标分类、长期文件管理和复杂离线分析；RK3568 不负责替代 FPGA 的像素级实时前端和硬件故障保护。

### 5.2 RK3568/Linux 侧职责

| 模块 | RK3568 工作内容 | 输入或交接 |
|---|---|---|
| PCIe 驱动 | 枚举、BAR 映射、DMA buffer、MSI、中断、缓存一致性 | FPGA 控制寄存器和结果描述符 |
| 参数下发 | 模式、阈值、ROI、测试图案、复位和心跳 | FPGA 控制消息 |
| 结果接收 | 读取特征、候选、告警、状态和统计，检查 CRC/序号 | FPGA 前端结果 |
| 高层感知 | 使用 RKNN/NPU、CPU/OpenCV 完成目标分类、场景理解和多帧融合 | 特征、候选、可选 ROI/帧 |
| 上层决策 | 将高层感知与人工指令、任务策略和系统状态融合 | 不能覆盖 FPGA 硬实时安全约束 |
| 输出显示 | HDMI OSD、箭头、文字、报警颜色、调试信息 | 与 frame_seq/result_seq 绑定 |
| 系统管理 | 配置、日志、性能统计、模型文件和故障恢复 | PCIe 状态、应用状态 |

### 5.3 集成层职责

PCIe、协议和系统集成建议独立维护以下责任：

- 固定 PDS、PCIe IP、RK Linux、设备树、驱动和 RKNN Runtime 版本；
- 冻结 BAR 寄存器、描述符格式、字节序、版本号和 CRC；
- 维护生产者/消费者索引和 buffer ownership；
- 统一超时、复位、错误码和心跳；
- 记录 PIO、DMA、NPU、端到端延迟和丢帧数据。

## 6. FPGA 内部数据路径

### 6.1 感知路径

    HDMI RX
     -> 像素流 CDC/FIFO
     -> 行缓存
     -> RGB/YUV/Gray 转换
     -> ROI 裁剪
     -> 缩放/Letterbox
     -> Sobel/阈值/颜色/几何特征
     -> 红绿灯/车道/斑马线/障碍物候选与快速状态
     -> FPGA 前端告警
     -> 特征/候选结果环形缓存
     -> PCIe DMA

RK3568 侧继续执行：

    特征/候选结果
     -> RKNN/NPU 或 CPU 高层感知
     -> 多帧融合和规则决策
     -> OSD、日志和上层指令

### 6.2 显示或调试路径

    HDMI RX
     -> 原始帧/低分辨率帧
     -> DDR3 帧缓存或直通
     -> FPGA 本地状态/显示或 RK3568 HDMI 输出

感知路径必须在 FPGA 内形成可独立验收的结果；显示路径应优先保证帧同步和可观察性。两条路径不要相互阻塞。

### 6.3 FPGA 性能利用原则

1. 使用流式流水线，尽量做到每时钟一个像素或固定并行像素数。
2. 3×3 滤波、Sobel 等使用 BRAM/eRAM 行缓存，不要反复读写 DDR3。
3. 使用定点数、查表和 DSP 乘加，避免浮点运算。
4. 先 ROI、再缩放、再格式转换、再特征提取和结果编码，尽早减少数据量。
5. DDR3 只承担帧缓存和跨速率解耦，不把它当作每个像素的临时工作区。
6. 控制面使用 PIO，结果面使用 DMA；只有调试或可选增强时才传输图像帧，避免 CPU 参与大块 memcpy。
7. 各时钟域之间使用异步 FIFO 或明确握手，禁止直接跨域传递多 bit 状态。
8. 任何预处理模块都要提供旁路模式，便于与原始帧对比和故障定位。

## 7. FPGA 与 RK3568 通信设计

### 7.1 通信分层

| 层级 | 机制 | 用途 | 是否承载整帧 |
|---|---|---|---|
| 控制面 | BAR/PIO | 启停、配置、状态、错误计数、心跳 | 否 |
| 通知面 | MSI/MSI-X 或等效中断 | 新帧、DMA 完成、错误通知 | 否 |
| 数据面 | PCIe DMA | 感知结果、统计、告警；可选帧/ROI | 结果为主 |
| 辅助面 | UART/以太网 | 调试日志、参数下发、低速状态 | 否 |

UART、I2C 和 FSPI 不作为高速感知结果或整帧视频的主传输通道；可用于低速调试和辅助配置。

### 7.2 BAR/PIO 建议寄存器表

以下是 design 级建议地址，不代表厂商 IP 已经采用这些地址；具体偏移必须在 FPGA RTL、Linux 驱动和测试程序中统一。

| 偏移 | 名称 | 方向 | 说明 |
|---:|---|---|---|
| 0x000 | VERSION | 只读 | 协议版本、硬件版本 |
| 0x004 | CAPS | 只读 | 通道数、像素格式、DMA 能力 |
| 0x008 | CONTROL | 读写 | start/stop/reset/test_pattern |
| 0x00C | STATUS | 只读 | link_ready/frame_ready/busy/fault |
| 0x010 | HEARTBEAT | 读写 | 双方递增心跳 |
| 0x014 | RESULT_SEQ_LO | 只读 | 最近完成结果序号低位 |
| 0x018 | RESULT_SEQ_HI | 只读 | 最近完成结果序号高位 |
| 0x01C | PRODUCER_INDEX | 只读 | FPGA 已生产描述符索引 |
| 0x020 | CONSUMER_INDEX | 读写 | RK 已消费描述符索引 |
| 0x024 | RELEASE_INDEX | 读写 | RK 释放给 FPGA 的 buffer 索引 |
| 0x028 | DMA_STATUS | 只读 | 活动、完成、超时、错误 |
| 0x02C | ERROR_FLAGS | 读写 | 写 1 清除错误位 |
| 0x030 | RESULT_DROP_COUNT | 只读 | 结果丢弃累计数 |
| 0x034 | DMA_ERROR_COUNT | 只读 | DMA 错误累计数 |
| 0x038 | IRQ_ENABLE | 读写 | 中断使能 |
| 0x03C | IRQ_STATUS | 读写 | 写 1 清除中断状态 |
| 0x040 | ROI_CONFIG | 读写 | ROI 配置索引或启用状态 |

寄存器访问必须定义对齐、读写宽度、端序、复位值和并发访问规则。

### 7.3 FPGA → RK3568 前端感知结果描述符

默认每个生产的特征、候选或快速状态记录对应一个描述符；原始帧/ROI 使用同一描述符格式的可选扩展字段：

    descriptor_version
    result_seq
    frame_seq
    channel_id
    capture_time_us
    buffer_index
    buffer_dma_addr
    byte_count
    width
    height
    stride
    pixel_format
    roi_x, roi_y, roi_width, roi_height
    feature_type
    candidate_type
    candidate_count
    fast_state
    alarm_code
    suggested_action
    confidence
    crc32
    producer_state
    error_flags

字段要求：

- result_seq 单调递增，frame_seq 标识结果对应的视频帧；跨复位后必须通过状态位标记重新开始；
- channel_id 在单路时固定为 0，四路时每路独立；
- buffer_dma_addr 仅在携带帧、ROI 或扩展数据时使用，必须由驱动分配并完成 DMA 映射；
- byte_count 对结构化结果表示有效载荷长度，对图像数据表示实际 stride 和格式；
- pixel_format 对图像扩展至少区分 RGB888、YUV422、NV12、GRAY8；结构化结果使用 RESULT_FORMAT；
- crc32 用于 bring-up 和故障定位；
- producer_state 与 ownership 状态机统一为 FREE、FPGA_WRITING、READY、RK_READING、RK_RELEASED、ERROR。

### 7.4 RK3568 → FPGA 指令和参数消息

    start
    stop
    reset
    mode
    command
    input_format
    roi_enable
    roi_config
    threshold_config
    output_enable
    buffer_release_index
    heartbeat
    test_pattern
    irq_enable
    command_seq
    ack_required

控制消息必须幂等。例如重复写入 stop 不得导致感知状态机或 DMA ring 进入不可恢复状态；reset 必须区分感知模块复位、DMA ring 复位和整条 PCIe 链路复位。FPGA 应返回 command_seq 对应的 ACK/NACK 和错误码。

### 7.5 RK3568 → FPGA 高层结果与控制反馈

RK3568 完成高层感知和策略融合后，可向 FPGA 返回与当前帧/通道绑定的显示或控制反馈：

    message_version
    result_seq
    frame_seq
    channel_id
    scene_type
    final_class
    final_confidence
    navigation_action
    display_flags
    alarm_code
    valid_until_frame
    crc32

RK3568 可以回传高层结果和上层命令，但不能用过期、无效或低优先级命令覆盖 FPGA 的实时安全状态。建议动作优先级固定为：

    故障/急停
      > 红灯停车
      > 碰撞停车
      > 实线禁止变道
      > 允许导航动作
      > 正常行驶

## 8. Buffer ownership 和时序

### 8.1 推荐状态机

    FREE
      -> FPGA_WRITING
      -> READY
      -> RK_READING
      -> RK_RELEASED
      -> FREE

发生错误时进入 ERROR，只能由明确的复位或错误清除流程重新进入 FREE。

### 8.2 所有权规则

1. FPGA 只有在 buffer 为 FREE 时才能写入。
2. FPGA 写完结果或扩展数据、完成 DMA 描述符和必要的内存屏障后，才能置为 READY。
3. RK 只有看到 READY 和有效中断后才能读取。
4. RK 完成 DMA 读取、缓存失效、高层感知/结果记录和可选算法处理后，才能写 RELEASE_INDEX。
5. FPGA 看到释放索引后才能复用 buffer。
6. 任何一侧超时都不能直接覆盖对方仍处于 WRITING 或 RK_READING 的 buffer。

### 8.3 缓冲策略

- 单帧 bring-up：至少两个 buffer，便于验证 ownership；
- 连续单路：建议 3 至 4 个 buffer，吸收 DMA 和 NPU 抖动；
- 四路扩展：按通道维护 ring，不能让一路阻塞其他通道；
- 高负载丢帧：优先丢弃未开始推理的旧帧，不覆盖正在读取的 buffer。

## 9. 错误处理和恢复

| 错误 | 检测位置 | 默认处理 |
|---|---|---|
| HDMI 失锁 | FPGA | 停止生产新结果，保留错误码，等待重新锁定 |
| CDC/FIFO 溢出 | FPGA | 丢弃当前帧，递增计数，不污染下一帧 |
| DDR3 初始化/校验失败 | FPGA | 阻止结果 DMA，进入故障状态 |
| PCIe 链路异常 | 驱动/FPGA | 停止 DMA，保留寄存器状态，执行受控恢复 |
| DMA 超时 | 驱动/FPGA | 回收未完成描述符，禁止重复释放 |
| CRC/长度错误 | RK 驱动/应用 | 丢弃该结果或扩展数据并记录 result_seq/frame_seq |
| RKNN/高层感知超时 | RK 应用 | 丢弃高层结果，保持 FPGA 快速状态或进入安全默认状态 |
| 决策消息过期 | RK 应用/FPGA | 忽略旧消息，进入保守状态 |
| 心跳超时 | 双方 | 停止数据面，等待复位或重新握手 |

FPGA 寄存器和 RK 日志至少记录：

    last_result_seq
    last_frame_seq
    last_channel_id
    result_drop_count
    fifo_overflow_count
    dma_timeout_count
    dma_error_count
    crc_error_count
    link_reset_count
    optional_algorithm_timeout_count
    last_error_code

错误统计必须带时间或帧号，避免只有一个无法定位的累计值。

## 10. 带宽与性能预算

未压缩视频 payload 近似为：

    width × height × bytes_per_pixel × fps

| 视频 | RGB888 | YUV422 |
|---|---:|---:|
| 1080P@30 单路 | 186.6 MB/s | 124.4 MB/s |
| 1080P@60 单路 | 373.2 MB/s | 248.8 MB/s |
| 1080P@30 四路 | 746.4 MB/s | 497.7 MB/s |

以上不包含 PCIe 协议、描述符、空闲周期、缓存和调度开销，不能直接当作 PCIe 实测吞吐。

首版建议：

1. FPGA 内部完成实时预处理、特征/候选提取和快速状态，PCIe 首先传结构化前端结果和告警；
2. HDMI 原始帧或 ROI 只在调试、复核和可选算法增强时传输；
3. PIO 只传控制信息，结构化结果和扩展数据走 DMA；
4. 分别测量 FPGA 感知延迟、结果 DMA、命令响应、RK 显示和端到端延迟；
5. 未确认实际 PCIe lane 数前，不承诺四路全帧吞吐。

## 11. 分阶段验收

### G0：厂商资料交接

必须拿到并记录目标 PDS 版本、PG2L100H PCIe IP/DMA、FMC HDMI RX 和 DDR3 工程、RK3568 Linux 镜像/设备树/驱动，以及可选 RKNN Toolkit/Runtime 与 NPU 驱动版本。G0 未完成前，不开始编写依赖厂商 PCIe 原语的最终 DMA RTL。

### G1：FPGA 视频基础

- HDMI 分辨率、帧率和锁定状态正确；
- 直通或测试图案连续运行，无花屏和丢行；
- DDR3 写入/读出 CRC 一致；
- 复位后能够重新初始化。

### G2：PCIe 控制面

- 链路枚举成功；
- BAR/PIO 读写稳定；
- 版本、能力、状态和错误寄存器可读取；
- 中断和链路复位行为明确。

### G3：PCIe 数据面

- 已知模式 DMA 内容、长度和 CRC 正确；
- 单条真实前端结果 DMA 正确；
- 连续至少 1000 次循环无错误；
- ownership、缓存一致性和超时恢复无冲突。

### G4：协同感知

- FPGA 可以独立输出颜色、边缘、几何特征、候选区域、快速状态和告警；
- RK3568 可以基于 FPGA 前端结果完成目标分类、场景理解、多帧融合和最终策略；
- 前端结果带有 result_seq、frame_seq、channel_id、候选类型和告警码；
- 前端结果与输入视频帧对齐，输入失锁和低置信度可观察；
- FPGA 在 RK3568 不运行时仍能保持前端处理和硬件安全状态，完整高层识别则标记为不可用。

### G5：单路全链路

    HDMI RX -> FPGA 前端处理/候选提取 -> 结果/ROI DMA
                                      -> RK3568 高层感知/决策/显示
                                      <- PCIe 指令/参数/反馈

要求连续运行无持续结果错位、缓冲区泄漏、死锁或不可解释丢帧；RK3568 的命令必须能得到 ACK/NACK 和状态反馈。

### G6：四路扩展

只有在单路通过 G5 后，才进入四路。四路必须具备独立 channel_id、帧号、结果序号、时间戳和错误统计，独立或明确分区的 DDR3 buffer 和 DMA ring，RK3568 多路结果消费和命令调度策略，一路失锁不拖死其他通道，以及实际吞吐、帧率、延迟和丢帧证据。

## 12. 工程落点与潜在影响

本文不直接修改代码。实施时建议按以下边界落地：

| 位置 | 负责内容 | 修改原因 |
|---|---|---|
| FPGA RTL/PDS 工程 | 采集、CDC、预处理、DDR3、PCIe Endpoint、BAR 和 DMA 请求 | 保持像素级实时路径在 FPGA 内闭环 |
| FPGA 约束/IP 配置 | 管脚、时钟、DDR3、PCIe 和 HDMI RX | 目标板与 PGL50H 例程并非直接兼容 |
| RK Linux 驱动/设备树 | PCIe 枚举、BAR、MSI、DMA 映射、缓存一致性 | 建立安全的硬件数据面 |
| RK3568 用户态应用 | 指令、参数、前端结果消费、高层感知、决策、显示和日志 | 处理复杂感知和主控交互，不替代 FPGA 实时前端 |
| 共享接口头文件 | 寄存器、描述符、消息、错误码、版本和端序 | 避免 FPGA、驱动、应用各自定义协议 |
| 测试工具 | PIO、已知模式 DMA、CRC、长稳、性能计时 | 将 source/build/device 证据分开记录 |

潜在影响：接口字段、字节序、buffer ownership、复位语义和错误码一旦冻结，后续 FPGA、驱动和应用必须同步升级协议版本，不能只改一端。

## 13. 当前实施顺序

    M0 资料和版本冻结
     -> M1 时钟/复位/HDMI 直通
     -> M2 DDR3 和 FPGA 预处理
     -> M3 FPGA 道路特征和场景感知
     -> M4 PCIe PIO/MSI/结果 DMA/指令 ACK
     -> M5 RK3568 显示、记录和控制联调
     -> M6 单路基础要求封版
     -> M7 四路和复杂场景扩展

核心原则：先证明数据正确，再优化吞吐；先完成单路闭环，再扩展四路；先固定通信协议，再并行开发 FPGA、驱动和算法。

## 14. 关联文档

- [赛题三快速上手开发手册.md](contest/赛题三快速上手开发手册.md)
- [赛题三三人分工与完成顺序.md](contest/赛题三三人分工与完成顺序.md)
- [官方历程能力与赛题三映射.md](contest/官方历程能力与赛题三映射.md)
- [rk3568_pg2l100h_open_source_research.md](research/rk3568_pg2l100h_open_source_research.md)
- findings.md（原根目录会话过程文件，工作区已不存在；相关档案见 .planning/2026-09-25-rk-fpga-protocol/）
