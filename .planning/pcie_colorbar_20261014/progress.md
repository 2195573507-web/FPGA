# Progress

2026-10-14: Completed RTL fixes, dedicated RK driver/CLI, simulation, native checks and static ARM64
cross-build. Full PDS final build finished11:07 local, timing pass. Checked supplied board manuals
for SCBV evidence but no unambiguous configuration-bank voltage established. Preserve warning.
Final packaging with exact inputs, logs, protocol and board commands in progress.

Release complete: RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014.tar.gz
235 files, 6,631,280 bytes. Extracted archive SHA256SUMS, exact source copies,
TCL/IDF dependencies and ARM64 ELF verified. Archive SHA256:
67521c4b0d5e4eb39026be5a20ff88f4a77420bf028a9c75170b63c54fe0a6c3
Source-only driver folder cleaned of generated x86_64 module to avoid accidental board use.

## 2026-10-14 板端故障定位（多 agent 审计）

用户板端实测：PCIe 枚举正常、驱动装载正常，但所有 BAR1 访问导致 DMA 超时，
AER 报 UnsupReq+，HeaderLog=f0204130（=主机 BAR1 基址+0x130，驱动复位寄存器写）。

三个只读审计员独立结论：
- rx-auditor：BAR1 写通道唯一使能源是核心给出的 bar_hit（来自 axis_master_tuser[5:4]），
  硬件层无地址比对；地址失配时整条 BAR1 总线静默，命令永不锁存。
  与厂商四路工程对比：三个核心文件 SHA256 逐字节相同，无任何 RTL 差异能解释 UR。
  用真实 RTL 仿真复现：tuser[5:4]=2'b01 锁存成功；改为 2'b00 则 o_bar1_wr_en 恒 0。
  判定：修主机枚举/BAR 复位同步，不要改 RTL 解码。
- tx-auditor：命令锁存后 MWR TLP 能正常发出；未发现独立阻断。
  但记录了 D1（短命令静默丢弃，P1）、D3（DATA_TX 无超时出口，P1）、
  D4（源侧 active_r 与 FSM 判据分叉，P1）等缺陷供后续修复。
- identity-verifier：交付位流（84C4A649）从未出现在任何 Program 记录中；
  板端 BAR 指纹（8K/4K/8K-64bit/Gen2/MPS1024）8 项中 7 项等于 Pango IP 出厂默认，
  指向一份未覆盖 BAR 参数的原厂 demo 位流（强假设）。
  并独立确证：cfg_init 把 BAR base 写 0（INI_12/14/16 的 28'd0），
  三 Region 全带 [virtual] 是「设备侧 BAR 基址当前为 0」的直接观测。

本轮代码改动：
- driver/pango_pci_driver.c 新增 colorbar_restore_bars()，probe 时把内核记录的 BAR 地址
  写回配置空间，修复「FPGA 重配置后 BAR 归零」；模块参数 restore_bars 默认 1。
  本机 Linux 5.15 头文件 W=1 编译零警告。
- 新增 rescan_and_test.sh + RESCAN_README.md（板端强制重枚举 + 复测 + 判据）。
- 三份审计报告与根因记录放入包内 docs/。
- 发布包重新封存：pcie_colorbar_pg2l100h_rk3568_20261014.tar.gz
  SHA256 = 431383b9ad7098628d571f1fa3fd901e2ea790e464190234bd09e6068242f2c2
  241 文件，解包校验与包内 SHA256SUMS 全量校验通过。
  旧包（67521c4b…）已归档哈希到 .planning/pcie_colorbar_20261014/previous_release.sha256。

板端一锤定音命令见 rk3568/RESCAN_README.md；判据：重扫后 Region0=64K 且无 Region2。
