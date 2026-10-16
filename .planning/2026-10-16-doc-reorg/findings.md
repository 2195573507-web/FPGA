# 发现：文档盘点与引用关系

## 数量基线
- 全仓 .md：393（glob）/ 372（跳过 .venv 等重型目录后）。
- 第一方 Markdown：156（不含 .venv、site-packages、third_party、rknn-toolkit2、ocs、资料/、UniAD/）。
- 第三方 Markdown：222；生成副本包（RK3568/packages/pcie_colorbar_...20261014/）：13 → 均不纳入。
- 其中过程记录（task_plan/progress/findings 与评审记录）：.planning/ 19、.scratch/ 4、_tmp/ 45、PGL/Design/ 3、adas_distill/ 3 → 保留原位，不迁入文档区。

## 待迁移 13 个文件与落点
| 文件（根目录） | 落点 | git 跟踪 |
|---|---|---|
| FPGA与RK3568任务分工及通信接口设计.md | docs/ | 是 |
| 1080p60_视频压缩解压方案.md | docs/ | 否 |
| 1080p60_方案审计报告.md | docs/ | 否 |
| 赛题三快速上手开发手册.md | docs/contest/ | 是 |
| 赛题三三人分工与完成顺序.md | docs/contest/ | 是 |
| 官方历程能力与赛题三映射.md | docs/contest/ | 是 |
| notes.md | docs/research/ | 是 |
| rk3568_pg2l100h_open_source_research.md | docs/research/ | 是 |
| 开源项目链接汇总.md | docs/research/ | 是 |
| check_fpga_logic.md | docs/archive/ | 否 |
| RK3568_HDMI输出开发文档.md | RK3568/docs/ | 否 |
| RK3568_MIPI屏幕开发文档.md | RK3568/docs/ | 否 |
| RK3568显示开发文档_MIPI屏幕与HDMI输出.md | RK3568/docs/ | 否 |

## 保留原位（有固定目录作用或定时入口）
- Memory.md（858 行，定时整理工程内存文档，更新于 2026-10-16 15:00）。
- AGENTS.md、docs/agents/*.md（代理指导）。
- RK3568/README.md、rtl/README.md、videos/README.md、PGL/Design/README_DESIGN.md、adas_distill/README.md、docs/assets/sfp_path_rx_sim/README_sim.md、RK3568 各 packages README（子项目入口）。

## 迁移前基线（.planning/2026-10-16-doc-reorg/link-baseline.txt）
- 范围内 md 156 个：相对链接 30 条、图片 0 张、外链 69 条、坏链 1 条。
- 唯一坏链（原有问题，非本次引入）：FPGA与RK3568任务分工及通信接口设计.md:481 → ./findings.md。
  git 证据：根目录 findings.md/progress.md/task_plan.md 已在工作区被删除（git diff --stat 显示 3 个文件 -65 行），而 .planning/2026-09-25-rk-fpga-protocol/findings.md 内容 md5 不同（ce47a2… vs ea35a8…），即目标确实不存在，属用户既有变更，不恢复。

## 图片引用
- 13 个待迁移文件中图片引用 0 处；范围内 md 图片引用 0 张 → 无图片需修复。
- 待迁移文件对图片/PDF 的引用集中在 官方历程能力与赛题三映射.md（tmp/official_examples/*.pdf 12 条）、赛题三快速上手开发手册.md（资料/紫光.pdf）→ 迁移后需补 ../../。

## 路径式引用（迁移后必须改写）
- D:/FPGA/1080p60_视频压缩解压方案.md → docs/ 前缀：docs/sfp_path_design.md:583、docs/design_audit.md:44、docs/sfp_verify_plan.md:587、rtl/README.md:3、_tmp/tasks.md:7、_tmp/plan_parts/part_h.md:77、.planning/2026-10-15-1080p60-audit/findings.md:5（D:\ 反斜杠形式）。
- D:/FPGA/rk3568_pg2l100h_open_source_research.md → docs/research/：_tmp/tasks.md:6。
- 绝对路径链接（原写法，非本次引入）：RK3568 显示三篇互链使用 D:\FPGA\*.md → 迁移后统一改为同目录相对链接。

## 不改动
- 裸文件名引用（如 `1080p60_视频压缩解压方案.md:411-413`）作为正文引证保留，由 docs/README.md 的迁移映射表解析。
- 不合并、不删除任何文档，不改技术结论。
