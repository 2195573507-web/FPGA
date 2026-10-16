# 迁移清单（可追踪，2026-10-16）

| 原路径（仓库根目录） | 新路径 | 方式 | 大小 |
|---|---|---|---|
| FPGA与RK3568任务分工及通信接口设计.md | docs/FPGA与RK3568任务分工及通信接口设计.md | git mv | 22905 B |
| 1080p60_视频压缩解压方案.md | docs/1080p60_视频压缩解压方案.md | mv | 47349 B |
| 1080p60_方案审计报告.md | docs/1080p60_方案审计报告.md | mv | 16243 B |
| 赛题三快速上手开发手册.md | docs/contest/赛题三快速上手开发手册.md | git mv | 21655 B |
| 赛题三三人分工与完成顺序.md | docs/contest/赛题三三人分工与完成顺序.md | git mv | 17060 B |
| 官方历程能力与赛题三映射.md | docs/contest/官方历程能力与赛题三映射.md | git mv | 13959 B |
| notes.md | docs/research/notes.md | git mv | 3969 B |
| rk3568_pg2l100h_open_source_research.md | docs/research/rk3568_pg2l100h_open_source_research.md | git mv | 11500 B |
| 开源项目链接汇总.md | docs/research/开源项目链接汇总.md | git mv | 6149 B |
| check_fpga_logic.md | docs/archive/check_fpga_logic.md | mv | 2205 B |
| RK3568_HDMI输出开发文档.md | RK3568/docs/RK3568_HDMI输出开发文档.md | mv | 7181 B |
| RK3568_MIPI屏幕开发文档.md | RK3568/docs/RK3568_MIPI屏幕开发文档.md | mv | 7508 B |
| RK3568显示开发文档_MIPI屏幕与HDMI输出.md | RK3568/docs/RK3568显示开发文档_MIPI屏幕与HDMI输出.md | mv | 1023 B |

新路径均以 statSync 确认存在；迁移后仓库根目录仅剩 AGENTS.md、Memory.md。
git 视图：本批共 7 个 git mv（对应上表「方式」列为 git mv 的行，git 显示 100% rename），6 个 mv（对应「方式」列为 mv 的行，真移动而非删除重建）；两类在表中交错分布，具体以方式列为准。
