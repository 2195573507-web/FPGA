#!/usr/bin/env bash
# 迁移第一方 Markdown（P3）。tracked 用 git mv 保留历史，untracked 用 mv（真移动，非删除重建）。
cd /d/FPGA || exit 1
mkdir -p docs/contest docs/research docs/archive RK3568/docs

run() { echo "$ $*"; "$@" || echo "FAILED: $*"; }

run git mv -- "FPGA与RK3568任务分工及通信接口设计.md" "docs/FPGA与RK3568任务分工及通信接口设计.md"
run git mv -- "notes.md" "docs/research/notes.md"
run git mv -- "rk3568_pg2l100h_open_source_research.md" "docs/research/rk3568_pg2l100h_open_source_research.md"
run git mv -- "开源项目链接汇总.md" "docs/research/开源项目链接汇总.md"
run git mv -- "赛题三快速上手开发手册.md" "docs/contest/赛题三快速上手开发手册.md"
run git mv -- "赛题三三人分工与完成顺序.md" "docs/contest/赛题三三人分工与完成顺序.md"
run git mv -- "官方历程能力与赛题三映射.md" "docs/contest/官方历程能力与赛题三映射.md"

run mv -- "1080p60_视频压缩解压方案.md" "docs/1080p60_视频压缩解压方案.md"
run mv -- "1080p60_方案审计报告.md" "docs/1080p60_方案审计报告.md"
run mv -- "check_fpga_logic.md" "docs/archive/check_fpga_logic.md"
run mv -- "RK3568_HDMI输出开发文档.md" "RK3568/docs/RK3568_HDMI输出开发文档.md"
run mv -- "RK3568_MIPI屏幕开发文档.md" "RK3568/docs/RK3568_MIPI屏幕开发文档.md"
run mv -- "RK3568显示开发文档_MIPI屏幕与HDMI输出.md" "RK3568/docs/RK3568显示开发文档_MIPI屏幕与HDMI输出.md"

echo "--- 根目录剩余 md ---"
ls -1 *.md 2>/dev/null || echo "(none)"
echo "--- docs 顶层 ---"
ls -1 docs/*.md 2>/dev/null
echo "--- docs 子目录 ---"
ls -1 docs/*/*.md 2>/dev/null
echo "--- RK3568/docs ---"
ls -1 RK3568/docs/*.md 2>/dev/null
echo "--- git status ---"
git status --porcelain=v1 | head -40
