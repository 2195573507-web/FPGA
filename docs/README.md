# 文档索引（docs/）

> D:/FPGA 第一方 Markdown 的统一入口。2026-10-16 由独立文档整理专员建立，配合一次分类归档：13 个散落在仓库根目录的文档移入 docs/、docs/contest/、docs/research/、docs/archive/、RK3568/docs/。
> 本次只做分类、索引与链接修复；不合并、不删除文档，未改动任何技术结论。

## 一、从这里开始

| 入口 | 位置 | 作用 |
|---|---|---|
| 代理协作约定 | [AGENTS.md](../AGENTS.md) | AI 代理入口：issue tracker、triage 标签、领域文档约定 |
| 代理子规则 | [docs/agents/](agents/) | issue-tracker / triage-labels / domain（multi-context 说明） |
| 工程内存总表 | [Memory.md](../Memory.md) | 定时整理的工程内存/接口/缓冲区/进度汇总（保持原位的固定入口） |
| 任务分工与接口基线 | [FPGA与RK3568任务分工及通信接口设计.md](FPGA与RK3568任务分工及通信接口设计.md) | 三人协作的接口契约与实施顺序 |
| 视频链路主方案 | [1080p60_视频压缩解压方案.md](1080p60_视频压缩解压方案.md) | 定速率帧内压缩/解压方案（码流格式权威定义） |
| 方案审计 | [1080p60_方案审计报告.md](1080p60_方案审计报告.md) | 对上述方案的独立审计 |
| 赛题与上手 | [contest/赛题三快速上手开发手册.md](contest/赛题三快速上手开发手册.md) | 赛题三知识地图与开发顺序 |
| 上游调研 | [research/rk3568_pg2l100h_open_source_research.md](research/rk3568_pg2l100h_open_source_research.md) | 开源选型与许可调研 |

## 二、分类导航

### 2.1 工程报告与设计（docs/ 顶层）

| 主题 | 文档 |
|---|---|
| SFP 光口输入改造 | [sfp_path_design.md](sfp_path_design.md)、[sfp_verify_plan.md](sfp_verify_plan.md)、[sfp_e2e_report.md](sfp_e2e_report.md) |
| 以太网接收链 | [eth_pkt_rx_report.md](eth_pkt_rx_report.md)、[eth_rx_verify_report.md](eth_rx_verify_report.md) |
| 编解码与吞吐 | [encoder_parallel.md](encoder_parallel.md)、[dec_throughput_options.md](dec_throughput_options.md)、[tile_buf_report.md](tile_buf_report.md) |
| 帧级集成与顶层 | [frame_integration_report.md](frame_integration_report.md)、[top_integration.md](top_integration.md) |
| 主机侧与 PC 工具链 | [host_side_changes.md](host_side_changes.md)、[pc_tools_changes.md](pc_tools_changes.md)、[pc_tools_review.md](pc_tools_review.md) |
| 评审与审计 | [design_audit.md](design_audit.md)、[rtl_fix_code_review.md](rtl_fix_code_review.md) |
| 端到端验证 | [e2e_test_report.md](e2e_test_report.md) |
| 交付物与证据审计 | [sfp_delivery_manifest.md](sfp_delivery_manifest.md) |
| 设计说明归档 | [superpowers/specs/2026-10-14-pcie-colorbar-design.md](superpowers/specs/2026-10-14-pcie-colorbar-design.md) |
| 仿真资产说明 | [assets/sfp_path_rx_sim/README_sim.md](assets/sfp_path_rx_sim/README_sim.md) |

### 2.2 赛题三资料（docs/contest/）

| 文档 | 内容 |
|---|---|
| [赛题三快速上手开发手册.md](contest/赛题三快速上手开发手册.md) | 项目本质、知识地图、阶段推进顺序 |
| [赛题三三人分工与完成顺序.md](contest/赛题三三人分工与完成顺序.md) | 三人分工与里程碑 |
| [官方历程能力与赛题三映射.md](contest/官方历程能力与赛题三映射.md) | 官方例程能力映射 + 原始 PDF 索引 |

### 2.3 上游与开源调研（docs/research/）

| 文档 | 内容 |
|---|---|
| [rk3568_pg2l100h_open_source_research.md](research/rk3568_pg2l100h_open_source_research.md) | 开源项目选型、许可证与采用优先级（研究结论） |
| [开源项目链接汇总.md](research/开源项目链接汇总.md) | 链接清单与首版必用/备选 |
| [notes.md](research/notes.md) | 早期调研笔记（板级事实与上游结论） |

### 2.4 历史与归档（docs/archive/）

| 文档 | 说明 |
|---|---|
| [check_fpga_logic.md](archive/check_fpga_logic.md) | 早期 FPGA 逻辑检查清单；含「接收数据全 0」等历史排查条目，相关过程记录见 PGL/Design 与 .planning/pcie_colorbar_20261014 |

### 2.5 RK3568 侧

**2.5.1 开发文档（RK3568/docs/）**

| 文档 | 内容 |
|---|---|
| [RK3568/README.md](../RK3568/README.md) | RK 侧工程入口（目录约定、构建、运行边界） |
| [architecture.md](../RK3568/docs/architecture.md) | RK 侧软件架构 |
| [rk_fpga_protocol_v1.md](../RK3568/docs/rk_fpga_protocol_v1.md) | RK↔FPGA 通信协议规范 |
| [RK3568_HDMI输出开发文档.md](../RK3568/docs/RK3568_HDMI输出开发文档.md) | HDMI TX / HPD / EDID / DRM-KMS 与 FPGA RX 边界 |
| [RK3568_MIPI屏幕开发文档.md](../RK3568/docs/RK3568_MIPI屏幕开发文档.md) | MIPI DSI / ILI9881C / 设备树 / 点屏验收 |
| [RK3568显示开发文档_MIPI屏幕与HDMI输出.md](../RK3568/docs/RK3568显示开发文档_MIPI屏幕与HDMI输出.md) | 上述两篇的索引页 |

**2.5.2 板端验收程序与交付包（RK3568/ 下各子工程，子目录入口保留原位）**

| 文档 | 内容 |
|---|---|
| [pcie_colorbar/README.md](../RK3568/pcie_colorbar/README.md) | 彩条位流板端验收程序：设备节点、PCI ID 0755:0755、BAR1、逐像素比对 1280x720 八色竖条 |
| [pcie_colorbar/RESCAN_README.md](../RK3568/pcie_colorbar/RESCAN_README.md) | 板端强制重枚举 + 复测脚本（BAR 基址只在主机枚举时写入） |
| [pcie_colorbar/BUILD_REPORT.md](../RK3568/pcie_colorbar/BUILD_REPORT.md) | 2026-10-14 构建与验证报告（未上板） |
| [pcie_image_receiver/README.md](../RK3568/pcie_image_receiver/README.md) | RGB888 接收程序部署指南（源码、交叉编译、部署） |
| [pcie_test_packages/上传和运行说明.md](../RK3568/pcie_test_packages/上传和运行说明.md) | PCIe 测试包上传与板卡运行指南 |
| [pcie_test_packages/上传和运行命令_192.168.2.3.md](../RK3568/pcie_test_packages/上传和运行命令_192.168.2.3.md) | 指定板卡 192.168.2.3 的上传与运行命令 |
| [packages/rknn_four_slow_yolo_only/README.md](../RK3568/packages/rknn_four_slow_yolo_only/README.md) | four_slow 六类 YOLO 检测器 RK3568 包说明 |
| [packages/scheme4_student_rk3568_video_package/.../README.md](../RK3568/packages/scheme4_student_rk3568_video_package/scheme4_student_rk3568_video/README.md) | scheme4 student 单模型 RKNN 视频包说明 |

### 2.6 RTL、板级工程与工具

| 入口 | 位置 |
|---|---|
| FPGA RTL 解码链进度 | [rtl/README.md](../rtl/README.md) |
| PG2L100H PCIe 彩条工程 | [PGL/Design/README_DESIGN.md](../PGL/Design/README_DESIGN.md) |
| 主机侧寄存器/驱动说明 | [README_PCIE_VIDEO.md](../PGL/Design/source/README_PCIE_VIDEO.md)、[BAR1_FIX_INSTRUCTIONS.md](../PGL/Design/source/BAR1_FIX_INSTRUCTIONS.md) |
| PC 工具链 | [Tools/](../Tools/)（sender.py、receiver.py、fpga_codec.py、link_common.py 等） |
| 测试视频素材 | [videos/README.md](../videos/README.md) |

**2.6.1 PGL/Design 设计与排查（逐篇）**

| 文档 | 内容 |
|---|---|
| [PDS_ADD_FILES.md](../PGL/Design/PDS_ADD_FILES.md) | PDS 工程待加入的 RTL 文件清单（顶层 hdmi_fmc_pcie_top） |
| [CODE_ANALYSIS_REPORT.md](../PGL/Design/CODE_ANALYSIS_REPORT.md) | 2026-10-12 FPGA design 代码问题分析报告 |
| [HDMI_FMC_CODE_REVIEW.md](../PGL/Design/HDMI_FMC_CODE_REVIEW.md) | HDMI FMC→PCIe DMA 代码审查报告 |
| [HDMI_PCIe_DIAGNOSTIC.md](../PGL/Design/HDMI_PCIe_DIAGNOSTIC.md) | HDMI-FMC-PCIe-RK3568 系统诊断指南 |
| [HDMI_FMC_PCIe_RK3568_DIAGNOSIS.md](../PGL/Design/HDMI_FMC_PCIe_RK3568_DIAGNOSIS.md) | 同上，系统架构澄清版 |
| [VIDEO_TRANSMISSION_GUIDE.md](../PGL/Design/VIDEO_TRANSMISSION_GUIDE.md) | HDMI 视频传输完整指南 |
| [TEST_PATTERN_INTEGRATION_GUIDE.md](../PGL/Design/TEST_PATTERN_INTEGRATION_GUIDE.md) | 测试图案集成步骤 |
| [CRU_SETUP_GUIDE.md](../PGL/Design/CRU_SETUP_GUIDE.md) | 用 CRU 强制 HDMI 输出的操作步骤 |
| [HDMI_DEBUG_ACTION_PLAN.md](../PGL/Design/HDMI_DEBUG_ACTION_PLAN.md) | HDMI 调试行动方案 |
| [HDMI_NO_EDID_SOLUTION.md](../PGL/Design/HDMI_NO_EDID_SOLUTION.md) | 无 EDID / Win+P 无法切换的诊断 |
| [BLACK_SCREEN_DIAGNOSIS.md](../PGL/Design/BLACK_SCREEN_DIAGNOSIS.md) | HDMI 全黑画面诊断清单 |
| [HDMI_BLACK_SCREEN_COMPLETE_GUIDE.md](../PGL/Design/HDMI_BLACK_SCREEN_COMPLETE_GUIDE.md) | HDMI 全黑画面完整解决记录 |
| [ALL_ZERO_DEBUG.md](../PGL/Design/ALL_ZERO_DEBUG.md) | 「数据全 0」问题深度调试 |
| [FIX_ALL_ZERO_PROBLEM.md](../PGL/Design/FIX_ALL_ZERO_PROBLEM.md) | 「数据全 0」问题修复方案 |
| [I2C_CLOCK_DIAGNOSIS.md](../PGL/Design/I2C_CLOCK_DIAGNOSIS.md) | MS7200 I2C 初始化问题诊断 |
| [I2C_CLOCK_PROBLEM_SOLUTION.md](../PGL/Design/I2C_CLOCK_PROBLEM_SOLUTION.md) | I2C 时钟问题根因确认与处理 |

**2.6.2 蒸馏工程（adas_distill/，子目录入口保留原位）**

| 文档 | 内容 |
|---|---|
| [adas_distill/README.md](../adas_distill/README.md) | 蒸馏工程入口（数据、teacher/student、复现步骤） |
| [DISTILLATION_STATUS.md](../adas_distill/docs/DISTILLATION_STATUS.md) | 蒸馏状态总表（2026-10-05 正式视频切分 host 蒸馏等） |
| [TEACHER_STUDENT_CONTRACT.md](../adas_distill/docs/TEACHER_STUDENT_CONTRACT.md) | scheme-four teacher/student 契约（静态形状、RK3568 目标） |
| [REAL_DISTILL_PREREQUISITES.md](../adas_distill/docs/REAL_DISTILL_PREREQUISITES.md) | 真实蒸馏前置条件与校验（含历史 UniAD 适配器说明） |
| [WSL_UNIAD_ENV.md](../adas_distill/docs/WSL_UNIAD_ENV.md) | WSL2 环境与历史 UniAD 兼容性记录 |

### 2.7 过程记录（保留原位，不纳入文档区）

| 位置 | 内容 |
|---|---|
| [.planning/](../.planning/) | 分阶段任务计划、findings、progress（含 pcie_colorbar_20261014、1080p60-audit、iic-audit、rk-fpga-protocol、windows-setup、doc-reorg、md-organization） |
| [.scratch/](../.scratch/) | 交接单与临时结论（sfp-final、handoff） |
| [_tmp/](../_tmp/) | 评审记录、计划分片、证据片段（历史资料，保留分类） |
| [PGL/Design/](../PGL/Design/) 的 task_plan.md / findings.md / progress.md | PCIe 彩条工程的会话过程记录（保留原位，不迁入文档区） |
| [adas_distill/](../adas_distill/) 的 task_plan.md / findings.md / progress.md | 蒸馏工程的会话过程记录（保留原位，不迁入文档区） |

### 2.8 保留原位的固定入口

| 文件 | 原因 |
|---|---|
| AGENTS.md | 仓库代理入口 |
| Memory.md | 定时整理的工程内存总表（更新入口） |
| RK3568/README.md、rtl/README.md、videos/README.md、adas_distill/README.md、PGL/Design/README_DESIGN.md、docs/assets/sfp_path_rx_sim/README_sim.md、RK3568 各 packages README | 各自子目录的入口/交付说明 |
| docs/agents/*.md | 代理指导文档 |

## 三、本次迁移映射（2026-10-16）

| 原路径（仓库根目录） | 新路径 | 方式 |
|---|---|---|
| FPGA与RK3568任务分工及通信接口设计.md | [docs/FPGA与RK3568任务分工及通信接口设计.md](FPGA与RK3568任务分工及通信接口设计.md) | git mv |
| 1080p60_视频压缩解压方案.md | [docs/1080p60_视频压缩解压方案.md](1080p60_视频压缩解压方案.md) | mv |
| 1080p60_方案审计报告.md | [docs/1080p60_方案审计报告.md](1080p60_方案审计报告.md) | mv |
| 赛题三快速上手开发手册.md | [docs/contest/赛题三快速上手开发手册.md](contest/赛题三快速上手开发手册.md) | git mv |
| 赛题三三人分工与完成顺序.md | [docs/contest/赛题三三人分工与完成顺序.md](contest/赛题三三人分工与完成顺序.md) | git mv |
| 官方历程能力与赛题三映射.md | [docs/contest/官方历程能力与赛题三映射.md](contest/官方历程能力与赛题三映射.md) | git mv |
| notes.md | [docs/research/notes.md](research/notes.md) | git mv |
| rk3568_pg2l100h_open_source_research.md | [docs/research/rk3568_pg2l100h_open_source_research.md](research/rk3568_pg2l100h_open_source_research.md) | git mv |
| 开源项目链接汇总.md | [docs/research/开源项目链接汇总.md](research/开源项目链接汇总.md) | git mv |
| check_fpga_logic.md | [docs/archive/check_fpga_logic.md](archive/check_fpga_logic.md) | mv |
| RK3568_HDMI输出开发文档.md | [RK3568/docs/RK3568_HDMI输出开发文档.md](../RK3568/docs/RK3568_HDMI输出开发文档.md) | mv |
| RK3568_MIPI屏幕开发文档.md | [RK3568/docs/RK3568_MIPI屏幕开发文档.md](../RK3568/docs/RK3568_MIPI屏幕开发文档.md) | mv |
| RK3568显示开发文档_MIPI屏幕与HDMI输出.md | [RK3568/docs/RK3568显示开发文档_MIPI屏幕与HDMI输出.md](../RK3568/docs/RK3568显示开发文档_MIPI屏幕与HDMI输出.md) | mv |

迁移后仓库根目录只保留 AGENTS.md 与 Memory.md 两个固定入口。

## 四、随迁移修复的链接

| 文件 | 修复内容 |
|---|---|
| docs/contest/官方历程能力与赛题三映射.md | 资料/紫光.pdf、tmp/official_examples/*.pdf（13 条）改为 ../../ 前缀 |
| docs/contest/赛题三快速上手开发手册.md | 资料/紫光.pdf 改为 ../../ 前缀；同目录映射文档链接保持有效 |
| docs/FPGA与RK3568任务分工及通信接口设计.md | 关联文档改为同目录相对链接 contest/、research/ |
| docs/research/notes.md | 映射文档指向 ../contest/ |
| RK3568/docs/ 显示三篇 | 原先的 D:/FPGA/... 绝对路径链接改为同目录相对链接 |
| docs/design_audit.md、docs/sfp_verify_plan.md、docs/sfp_path_design.md、rtl/README.md、_tmp/tasks.md、_tmp/plan_parts/part_h.md、.planning/2026-10-15-1080p60-audit/findings.md | 指向方案/调研文档的路径引用补上 docs/ 与 docs/research/ 前缀 |
| Memory.md | 参考文档清单中两项改为 docs/ 前缀 |

## 五、已知问题与边界

1. 正文里的裸文件名引用（例如「见 1080p60_视频压缩解压方案.md:411-413」）作为引证保留；对应实体请查第三节映射表。
2. 原本存在的坏链 ./findings.md（根目录会话过程文件已在工作区被删除）改为文字说明，不再作为链接。
3. 未纳入范围：资料/（厂商资料）、UniAD/、RK3568/third_party/（rknn_model_zoo 等）、tmp/rknn-toolkit2-v2.3.0/、tmp/rknn23wsl/、_tmp/ocs/、install/lib/bin/include（Python venv 与第三方依赖）、RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/（生成交付副本）以及各类构建产物。
4. 外链（GitHub、厂商站点）未联网校验；本次链接检查仅覆盖仓库内相对路径与图片。
5. 覆盖度：除第 3 条排除项外，纳入范围的第一方 Markdown 均在第一、二节被链接或按目录整体链接（文档区 31 篇逐篇，PGL/Design 16 篇逐篇，RK3568 交付相关 8 篇逐篇，adas_distill 文档 5 篇逐篇）；过程记录目录（.planning/、.scratch/、_tmp/、PGL/Design 的 task_plan/findings/progress）按目录整体索引，不逐篇列举。
6. tmp/ 下的 Markdown（tmp/agent_briefs/*.md、tmp/yolov8_rk3568_four_slow_stage_20260929/...、tmp/hw_manual/ 等）属过程记录与生成/解包产物，与第 3 条同类，未纳入索引、未移动。
