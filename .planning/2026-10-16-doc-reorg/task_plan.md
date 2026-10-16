# 任务计划：第一方 Markdown 分类归档与统一索引

## 目标
把散落在仓库根目录的第一方 Markdown 归类到既有目录结构下，建立统一索引，修复移动导致的链接，保留技术内容、固定入口与用户变更。不提交、不推送。

## 范围
- 纳入：仓库内第一方 Markdown（工程报告、方案、赛题资料、上游调研、显示开发文档、历史调试清单）。
- 排除：第三方依赖（资料/、UniAD/、RK3568/third_party/、tmp/rknn*、_tmp/ocs/、.venv）、构建产物、生成副本（RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/）。
- 保留原位：README/AGENTS/CLAUDE/技能文件、各子项目 README、Memory.md（定时整理入口）、.planning//.scratch//_tmp/ 过程记录（不迁入文档区）。

## 阶段
| 阶段 | 内容 | 状态 |
|---|---|---|
| P1 | 盘点（glob 393 个 md → 第一方 156）与基线链接扫描 | complete |
| P2 | 引用枚举（13 个待迁移文件的入链、图片、路径式引用） | complete |
| P3 | 建立目录并迁移（git mv 跟踪文件 / mv 未跟踪文件） | complete |
| P4 | 修复相对链接、图片、入口链接与路径式引用 | complete |
| P5 | 编写统一索引 docs/README.md | complete |
| P6 | 验证（链接检查 before/after、git status、diff 统计） | complete |
| P7 | 汇报给上游 agent | complete |

## 目标结构
    docs/                        工程报告（既有）+ 本次迁入的方案/接口文档
    docs/contest/                赛题三资料
    docs/research/               上游/开源调研
    docs/archive/                已被取代的历史清单
    RK3568/docs/                 RK 侧开发文档（既有 architecture/protocol + 显示三篇）

## 错误记录
| 错误 | 尝试 | 解决 |
|---|---|---|
| run_code 30s 超时（全盘递归 + 全量 grep） | 2 | 改为限定第一方目录扫描、逐目录 read/glob |
| node walk 函数作用域错误（函数声明在块外引用） | 1 | 改为函数声明式 walk(rel, out) |
