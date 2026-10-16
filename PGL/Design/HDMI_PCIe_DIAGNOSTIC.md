# HDMI-FMC-PCIe-RK3568 系统诊断指南

## 架构理解

```
电脑 (Windows/Linux)
  ↓ HDMI 输出端口
  ├─→ 输出视频信号 (1920×1080@60Hz RGB888)
  │
FMC HDMI 接收卡 (ATK FMC_HDMI_4K30)
  │ ├─ 接收电脑的 HDMI 信号
  │ └─ 输出 RGB888 + 同步信号
  ↓
FPGA (Pango)
  │ ├─ 接收 RGB888 视频数据
  │ ├─ 通过 PCIe 传输到 RK3568
  │ └─ PCIe 设备应在电脑上注册
  ↓
PCIe 总线 (电脑 ← FPGA)
  │ └─ 这是数据回传通道
  │    (不是给电脑看 HDMI，而是传输视频数据)
  ↓
RK3568 (ARM 开发板)
  │ └─ 接收 PCIe 传来的视频数据
  │    处理/显示/存储
```

---

## 问题诊断: "连接后看不到 HDMI 设备"

### 实际问题分析

**你的问题不是**:
- ❌ "电脑看不到 HDMI 输出" (这不重要)
- ❌ "HDMI 线接触不良" (这会影响 FPGA 侧输入)

**实际问题是**:
- ✓ "电脑无法识别 FPGA 的 PCIe 设备"
- ✓ 这导致电脑无法与 FPGA 通信
- ✓ 所以无法启动 HDMI 采集流程

### 症状表现

```
应该看到的现象:
  电脑 HDMI 输出 → FMC 接收卡接收 ✓
  FPGA 处理视频 → 准备通过 PCIe 发送
  电脑检测 FPGA PCIe 设备 ← ❌ 这一步失败了

结果:
  即使 FMC 正确接收了 HDMI 信号，
  电脑也无法与 FPGA 通信，
  整个系统无法工作
```

---

## 第一步: 检查电脑侧 PCIe 设备识别

### Windows 10/11 检查方法

#### 1. 打开设备管理器

```
方法1: Win + X → 设备管理器
方法2: 右键 "此电脑" → 管理 → 设备管理器
方法3: 按 Win+R → devmgmt.msc
```

#### 2. 查看 PCIe 设备

展开这些项目，查看是否有新设备:

```
【其他设备】
  └─ ⚠️ Pango FPGA / Unknown Device / PCI Device
     (这会显示一个感叹号 或 问号)

【网络适配器】
  (不应该在这里，除非驱动完全错误)

【通用串行总线控制器】
  (不应该在这里)

【PCI 设备】
  └─ 可能显示为一个数字编码的设备
     (如: PCI Device 1234:5678)
```

#### 3. 详细信息查看

右键设备 → 属性，记下:

```
设备名称: 
位置: PCI 总线 X, 设备 Y, 函数 Z
设备 ID: PCI\VEN_XXXX&DEV_YYYY&...
驱动程序: (空白 = 未安装驱动)
```

#### 4. 如果什么都看不到

这意味着设备根本没被 Windows 识别

**检查清单**:

```
[ ] PCIe 接线已完全插入 (听到"咔"的声音)
[ ] 另一端连接到 FPGA 的 PCIe 接口
[ ] 没有物理损伤
[ ] 更换另一个 PCIe 插槽试试
[ ] 重启电脑后查看
```

---

## 第二步: 验证 FPGA 固件状态

### 检查 FPGA 是否已加载比特流

```
观察 FPGA 板卡:

【外观检查】
  □ 是否有 LED 亮起? (通常用来指示工作状态)
  □ 是否有风扇转动?
  □ 是否能听到冷却风扇噪音?

【程序状态】
  □ 最近是否加载过比特流?
  □ 比特流文件位置: D:\FPGA\PGL\Design\output\*.fs (或 *.bit)
  □ 是否编译成功无错误?

【联动测试】
  □ 先拔掉 PCIe 接线
  □ 加载比特流到 FPGA
  □ 观察 LED 状态变化
  □ 再插上 PCIe 接线
  □ 查看设备管理器
```

### 加载比特流步骤 (如果未加载)

```
使用工具: PGL IDE 或 Vivado

1. 打开项目
   文件 → 打开项目
   选择: D:\FPGA\PGL\Design\

2. 编译设计 (如果还未编译)
   构建 → 生成比特流
   (或 Tools → Implement)

3. 程序 FPGA
   构建 → 配置 FPGA
   (或 Tools → Program Device)

4. 等待 100% 完成
```

---

## 第三步: 验证编译配置

### 检查之前报告的问题

来自 CODE_ANALYSIS_REPORT.md 的关键错误:

```
【问题1】Verilog-4163: Unsupported language construct
  位置: SystemVerilog 语法在 Verilog 模式中不支持
  
  修复:
  ✓ 项目 → 设置 → HDL 编译 → 语言 → "SystemVerilog"
  ✓ 构建 → 清理项目
  ✓ 构建 → 生成比特流

【问题2】PCIe IP 配置
  检查: Vivado/PGL 中的 pcie_core IP
  
  验证:
  ✓ Vendor ID 正确 (一般是 0x10EE 或 0x????  看 Pango 的)
  ✓ Device ID 唯一且有效
  ✓ BAR 空间已启用 (至少 BAR0 或 BAR1)
  ✓ 中断类型已设置 (MSI-X 或 INTx)

【问题3】FMC 约束
  检查: constraints/ 文件夹中的 .xdc 或 .cst
  
  验证:
  ✓ FMC_HDMI 引脚约束已加载
  ✓ RGB 数据线 (R[7:0], G[7:0], B[7:0])
  ✓ 同步信号 (HSYNC, VSYNC, DE/VALID)
  ✓ 输入时钟 (PCLK)
```

### 编译验证清单

```
打开编译日志: D:\FPGA\PGL\Design\build_*.log 或输出窗口

搜索关键词:
  [ ] "ERROR"     → 必须为 0 个
  [ ] "CRITICAL"  → 必须为 0 个
  [ ] "WARNING"   → 应该尽量少 (允许几个)
  [ ] "Verilog-4163" → 应该消失了

最后一行应该是:
  ✓ "生成比特流成功"
  ✓ "编译完成"
  ✓ 或类似的完成消息
```

---

## 第四步: BIOS 设置检查

### 如果设备管理器完全看不到任何新硬件

**可能原因**: BIOS 中 PCIe 插槽被禁用

**修复步骤**:

```
1. 重启电脑，进入 BIOS
   按键: Del / F2 / F10 (取决于主板型号)
   
2. 找到 PCIe 相关设置
   路径通常: Advanced → PCIe Configuration
   或: Integrated Peripherals → PCI Express

3. 查看设置项:
   [ ] PCIe Slot X Enable/Disable
       → 确保插 FPGA 的插槽为 "Enable"
   
   [ ] PCIe Gen Speed
       → 通常设为 "Auto" 或 "Gen 2" 即可
   
   [ ] PCIe 热插拔
       → 可选，"Enable" 或 "Disable" 都可以

4. 保存设置并重启
   按 F10 或类似键保存
   重启电脑

5. 进入 Windows 后查看设备管理器
```

---

## 第五步: PCIe 驱动程序

### 如果看到"未知设备"或感叹号

**这意味着**: 硬件被识别了，但缺少驱动

**解决步骤**:

```
1. 右键设备 → 属性
   
2. 记下关键信息:
   Device ID: VID_XXXX&DEV_YYYY&...
   PCI ID: XXXX:YYYY
   
3. 联系 Pango 技术支持或查找驱动:
   a) 官方网站是否有 PCIe 驱动下载
   b) 项目中是否有 drivers/ 文件夹
   c) GitHub 上是否有开源驱动
   
4. 安装驱动:
   右键设备 → 更新驱动程序
   → "浏览计算机以查找驱动程序"
   → 选择驱动文件所在文件夹
   → 自动安装
   
5. 完成后重启电脑

6. 查看设备管理器，确认驱动已安装
   (不应该再有感叹号或问号)
```

---

## 故障排除决策树

```
┌─ PCIe 设备能识别吗?
│
├─ 否 (看不到任何新硬件)
│  ├─ 检查 PCIe 接线
│  ├─ 检查 FPGA LED (固件加载?)
│  ├─ 进入 BIOS 检查 PCIe 插槽
│  ├─ 尝试不同 PCIe 插槽
│  └─ 重启电脑多次
│
└─ 是 (看到"未知设备"或感叹号)
   ├─ 检查驱动程序
   ├─ 尝试安装 Pango 官方驱动
   ├─ 重启电脑
   └─ 查看设备管理器
      ├─ 驱动安装成功?
      │  └─ 是 → 继续第六步
      └─ 否 → 联系技术支持


【设备成功识别后】
└─ 进行第六步: 验证 HDMI 采集
```

---

## 第六步: 验证 HDMI 采集 (设备识别后)

**前提**: 设备管理器中已正常显示 FPGA PCIe 设备

### 检查 HDMI 输入

```
【物理检查】
  [ ] HDMI 线已连接: 电脑 → FMC HDMI 接收卡
  [ ] HDMI 线两端完全插入
  [ ] 没有接触不良

【信号检查】
  [ ] 电脑 HDMI 输出口已启用
      (某些笔记本需要进行设置)
  
  [ ] HDMI 信号是否活跃?
      尝试接到电视/显示器验证
  
  [ ] FPGA 侧是否接收到信号?
      检查 video_locked 信号
      (需要在 FPGA 侧加 LED 指示)

【FPGA 工作指示】
  在 hdmi_fmc_rx_top.v 中可以加:
  
  assign debug_video_locked = video_locked;
  assign debug_stream_valid = stream_valid;
  
  然后在顶层例化中绑定 LED:
  
  set_property PACKAGE_PIN <LED_PIN> [get_ports debug_video_locked]
  
  重新编译，加载比特流
  LED 应该亮起 = 视频已锁定
```

### 调试建议

```
如果 HDMI 输入也看不到数据:

1. 先检查 HDMI 线本身
   → 用其他设备验证 HDMI 线可用

2. 检查 FMC 卡 MS7200 芯片初始化
   → 查看 hdmi_fmc_rx_top.v 中的 I2C 命令
   → 确认 I2C 总线正常
   → 验证 MS7200 是否已初始化

3. 检查 FPGA 时钟
   → HDMI 输入时钟是否正确?
   → 是否来自 FMC 卡 PCLK 引脚?

4. 检查约束文件
   → RGB888 引脚是否正确映射?
   → HSYNC/VSYNC 引脚是否正确?
```

---

## 需要收集的诊断信息

如果按照上述步骤仍无法解决，请提供:

```
【硬件信息】
  [ ] FPGA 型号 (Pango XYZ)
  [ ] 主板型号 (MSI / ASUS / 华硕 等)
  [ ] PCIe 插槽位置 (x1 / x4 / x16)
  [ ] 是否有 PCIe 转接卡

【软件信息】
  [ ] Windows / Linux 版本
  [ ] Vivado / PGL IDE 版本
  [ ] 比特流生成日期

【诊断截图】
  [ ] 设备管理器界面 (显示 PCIe 设备状态)
  [ ] FPGA 板卡正面照片 (显示 LED 状态)
  [ ] BIOS 中 PCIe 配置截图
  [ ] 编译日志最后 20 行

【现象描述】
  [ ] 连接后立即看不到，还是过了 30 秒才看不到?
  [ ] 是否曾经识别过 (现在突然看不到)?
  [ ] 拔掉再插入会怎样?
  [ ] 换 PCIe 插槽会怎样?

【已尝试的步骤】
  [ ] 已加载比特流吗?
  [ ] 已重启过电脑吗?
  [ ] 已进入 BIOS 检查过吗?
  [ ] 已尝试其他 PCIe 插槽吗?
```

---

## 快速检查清单 (5分钟快速排查)

```
[ ] FPGA 有加载比特流吗? (看看 LED)
[ ] PCIe 接线是否完全插入?
[ ] 设备管理器中有没有看到任何新硬件?
[ ] 最近重启过电脑吗?
[ ] BIOS 中 PCIe 插槽是否启用?
[ ] 编译时有没有错误?

如果全都是 ✓，但仍然看不到 → 进行完整诊断
```
