# Task Plan: 1080p60 视频压缩解压方案审计

## Goal

审计 `1080p60_视频压缩解压方案.md` 的数学、格式、硬件可实现性、网络链路和证据边界；输出按严重度排序的发现与可执行修订建议。

## Phases

- [in_progress] Phase 1: 建立方案、脚本、板卡和相关工程的证据清单。
- [ ] Phase 2: 复算像素率、码率、UDP 开销、条带预算和码率上界。
- [ ] Phase 3: 审计 MED/Rice/量化/格式/重排/行缓存/吞吐逻辑的一致性。
- [ ] Phase 4: 检查 FPGA、PHY、PDS、实板和实时编码证据边界。
- [ ] Phase 5: 形成审计报告并验证文件路径、关键引用和结论。

## Evidence policy

- 文档声明、脚本输出、源代码/约束、综合时序、板级运行分开报告。
- 不把经验估算、生成 bitstream 或离线 Python 闭环当作板级验收。

## Errors Encountered

| Error | Attempt | Resolution |
|---|---:|---|
| PowerShell `Get-ChildItem -Filter` 不接受数组 | 1 | 改用 `Where-Object` 按名称筛选 |
