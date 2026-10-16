# 验证记录（2026-10-16 文档整理）

## 最新增量验收（延迟专员报告后）

索引补充RK3568、PGL/Design、adas_distill逐篇导航后，主会话独立复核当前索引：93处本地链接、78个唯一目标，缺失0；此前路径说明、中性历史描述及移除固定行数等修正全部保留。git diff --check 与 git diff --cached --check 再次以0退出。以下63处链接记录保留为首次验收历史。

## 首次验收补记

迁移表新路径补为可点击链接后，主会话独立读取索引与清单，使用本地 existsSync 验证：索引63处链接、48个唯一目标，缺失0；迁移清单13个目标存在，原根路径残留0。git diff --check 与 git diff --cached --check 均以0退出。下方79条相对链接是补充映射表链接前的阶段记录，不是最终索引链接总数。

## 迁移前基线（link-baseline.txt）

```
scope md files: 156
relative links: 30 images: 0 external: 69
BROKEN: 1
FPGA与RK3568任务分工及通信接口设计.md  ->  ./findings.md
```

## 迁移后（link-after.txt）

```
scope md: 175 relative links: 79 images: 0 external: 69
BROKEN: 0


OK   adas_distill/README.md  ->  docs/REAL_DISTILL_PREREQUISITES.md
OK   adas_distill/README.md  ->  docs/DISTILLATION_STATUS.md
OK   docs/contest/官方历程能力与赛题三映射.md  ->  ../../资料/紫光.pdf
OK   docs/contest/官方历程能力与赛题三映射.md  ->  ../../tmp/official_examples/盘古50K-实验例程说明1-LED流水灯实验.pdf
OK   docs/contest/官方历程能力与赛题三映射.md  ->  ../../tmp/official_examples/盘古50K-实验例程说明2-键控流水灯实验.pdf
OK   docs/contest/官方历程能力与赛题三映射.md  ->  ../../tmp/official_examples/盘古50K-实验例程说明3-I2C读写实验.pdf
OK   docs/contest/官方历程能力与赛题三映射.md  ->  ../../tmp/official_examples/盘古50K-实验例程说明4-串口收发实验.pdf
OK   docs/contest/官方历程能力与赛题三映射.md  ->  ../../tmp/official_examples/盘古50K-实验例程说明7-DDR3的读写实验.pdf
OK   docs/contest/官方历程能力与赛题三映射.md  ->  ../../tmp/official_examples/盘古50K-实验例程说明8-光纤通信测试实验.pdf
OK   docs/contest/官方历程能力与赛题三映射.md  ->  ../../tmp/official_examples/盘古50K-实验例程说明9-PCIE通信测试实验.pdf
OK   docs/contest/官方历程能力与赛题三映射.md  ->  ../../tmp/official_examples/盘古50K-实验例程说明10-OV5640双目摄像头实验.pdf
OK   docs/contest/官方历程能力与赛题三映射.md  ->  ../../tmp/official_examples/盘古50K-实验例程说明11-以太网传输实验.pdf
OK   docs/contest/官方历程能力与赛题三映射.md  ->  ../../tmp/official_examples/盘古50K-实验例程说明17-HDMI显示波形实验.pdf
OK   docs/contest/官方历程能力与赛题三映射.md  ->  ../../tmp/official_examples/盘古50K-实验例程说明20-VGA输出彩条实验.pdf
OK   docs/contest/官方历程能力与赛题三映射.md  ->  ../../tmp/official_examples/盘古50K-实验例程说明56-HDMI实验.pdf
OK   docs/contest/赛题三快速上手开发手册.md  ->  ../../资料/紫光.pdf
OK   docs/contest/赛题三快速上手开发手册.md  ->  官方历程能力与赛题三映射.md
OK   docs/FPGA与RK3568任务分工及通信接口设计.md  ->  contest/赛题三快速上手开发手册.md
OK   docs/FPGA与RK3568任务分工及通信接口设计.md  ->  contest/赛题三三人分工与完成顺序.md
OK   docs/FPGA与RK3568任务分工及通信接口设计.md  ->  contest/官方历程能力与赛题三映射.md
OK   docs/FPGA与RK3568任务分工及通信接口设计.md  ->  research/rk3568_pg2l100h_open_source_research.md
OK   docs/README.md  ->  ../AGENTS.md
OK   docs/README.md  ->  agents/
OK   docs/README.md  ->  ../Memory.md
OK   docs/README.md  ->  FPGA与RK3568任务分工及通信接口设计.md
OK   docs/README.md  ->  1080p60_视频压缩解压方案.md
OK   docs/README.md  ->  1080p60_方案审计报告.md
OK   docs/README.md  ->  contest/赛题三快速上手开发手册.md
OK   docs/README.md  ->  research/rk3568_pg2l100h_open_source_research.md
OK   docs/README.md  ->  sfp_path_design.md
OK   docs/README.md  ->  sfp_verify_plan.md
OK   docs/README.md  ->  sfp_e2e_report.md
OK   docs/README.md  ->  eth_pkt_rx_report.md
OK   docs/README.md  ->  eth_rx_verify_report.md
OK   docs/README.md  ->  encoder_parallel.md
OK   docs/README.md  ->  dec_throughput_options.md
OK   docs/README.md  ->  tile_buf_report.md
OK   docs/README.md  ->  frame_integration_report.md
OK   docs/README.md  ->  top_integration.md
OK   docs/README.md  ->  host_side_changes.md
OK   docs/README.md  ->  pc_tools_changes.md
OK   docs/README.md  ->  pc_tools_review.md
OK   docs/README.md  ->  design_audit.md
OK   docs/README.md  ->  rtl_fix_code_review.md
OK   docs/README.md  ->  e2e_test_report.md
OK   docs/README.md  ->  superpowers/specs/2026-10-14-pcie-colorbar-design.md
OK   docs/README.md  ->  assets/sfp_path_rx_sim/README_sim.md
OK   docs/README.md  ->  contest/赛题三快速上手开发手册.md
OK   docs/README.md  ->  contest/赛题三三人分工与完成顺序.md
OK   docs/README.md  ->  contest/官方历程能力与赛题三映射.md
OK   docs/README.md  ->  research/rk3568_pg2l100h_open_source_research.md
OK   docs/README.md  ->  research/开源项目链接汇总.md
OK   docs/README.md  ->  research/notes.md
OK   docs/README.md  ->  archive/check_fpga_logic.md
OK   docs/README.md  ->  ../RK3568/README.md
OK   docs/README.md  ->  ../RK3568/docs/architecture.md
OK   docs/README.md  ->  ../RK3568/docs/rk_fpga_protocol_v1.md
OK   docs/README.md  ->  ../RK3568/docs/RK3568_HDMI输出开发文档.md
OK   docs/README.md  ->  ../RK3568/docs/RK3568_MIPI屏幕开发文档.md
OK   docs/README.md  ->  ../RK3568/docs/RK3568显示开发文档_MIPI屏幕与HDMI输出.md
OK   docs/README.md  ->  ../rtl/README.md
OK   docs/README.md  ->  ../PGL/Design/README_DESIGN.md
OK   docs/README.md  ->  ../PGL/Design/source/README_PCIE_VIDEO.md
OK   docs/README.md  ->  ../PGL/Design/source/BAR1_FIX_INSTRUCTIONS.md
OK   docs/README.md  ->  ../PGL/Design/
OK   docs/README.md  ->  ../Tools/
OK   docs/README.md  ->  ../videos/README.md
OK   docs/README.md  ->  ../adas_distill/README.md
OK   docs/README.md  ->  ../.planning/
OK   docs/README.md  ->  ../.scratch/
OK   docs/README.md  ->  ../_tmp/
OK   RK3568/docs/architecture.md  ->  rk_fpga_protocol_v1.md
OK   RK3568/docs/RK3568_HDMI输出开发文档.md  ->  RK3568_MIPI屏幕开发文档.md
OK   RK3568/docs/RK3568_MIPI屏幕开发文档.md  ->  RK3568_HDMI输出开发文档.md
OK   RK3568/docs/RK3568显示开发文档_MIPI屏幕与HDMI输出.md  ->  RK3568_MIPI屏幕开发文档.md
OK   RK3568/docs/RK3568显示开发文档_MIPI屏幕与HDMI输出.md  ->  RK3568_HDMI输出开发文档.md
OK   RK3568/README.md  ->  docs/architecture.md
OK   RK3568/README.md  ->  docs/rk_fpga_protocol_v1.md
OK   RK3568/README.md  ->  third_party/README.md
```
