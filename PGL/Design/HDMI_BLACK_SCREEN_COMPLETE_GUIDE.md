# HDMI全黑画面问题 - 完整解决方案

## 问题现状
- PCIe链路正常工作
- 能接收帧数据，但全是0（全黑）
- 电脑HDMI输出正常（显示器有画面）
- 分辨率已设置为1280×720

## 根本原因
**FPGA没有接收到有效的HDMI视频信号**

---

## 解决方案1：使用测试图案验证（推荐优先）

### 目的
验证PCIe传输链路是否完全正常，排除DMA/传输问题

### 步骤
1. 将 `test_pattern_generator.v` 添加到项目
2. 按照 `test_pattern_instructions.txt` 修改 `hdmi_fmc_pcie_top.v`
3. 重新编译并加载比特流
4. 在RK3568上运行接收程序

### 预期结果
- **能看到彩色条纹** → PCIe链路正常，问题在HDMI接收
- **还是全黑** → PCIe/DMA配置有问题

---

## 解决方案2：修复HDMI接收问题

### 可能原因A：MS7200未初始化

**症状**：FMC卡的MS7200芯片没有正确初始化

**检查**：
```verilog
// 在hdmi_fmc_pcie_top.v中查看hdmi_init_done信号
// 如果这个信号为0，说明初始化失败
```

**解决**：
1. 检查I2C时钟是否正确（应该是25MHz）
2. 检查I2C配置寄存器值是否正确
3. 增加初始化等待时间

### 可能原因B：HDMI信号未锁定

**症状**：video_locked信号为0

**原因**：
- 输入分辨率不支持
- HDMI线缆问题
- 时钟恢复失败

**解决**：
1. 添加LED指示video_locked信号
2. 尝试不同的HDMI分辨率
3. 更换HDMI线缆

### 可能原因C：FMC物理连接

**检查**：
1. FMC卡是否完全插入40pin接口
2. FMC卡是否需要独立供电
3. FMC卡LED指示（如果有）

---

## 解决方案3：添加LED调试

### 修改约束文件

在 `hdmi_fmc_pcie_video_merged.fdc` 末尾添加：

```tcl
# video_locked LED
define_attribute {p:video_locked} {PAP_IO_DIRECTION} {OUTPUT}
define_attribute {p:video_locked} {PAP_IO_LOC} {XX}  # 需要查板卡原理图
define_attribute {p:video_locked} {PAP_IO_VCCIO} {1.8}
define_attribute {p:video_locked} {PAP_IO_STANDARD} {LVCMOS18}
```

### LED状态含义
- **LED亮** → HDMI信号已锁定，但数据可能有问题
- **LED不亮** → HDMI信号未锁定，MS7200未工作

---

## 快速诊断检查清单

```
[ ] 测试图案能正常显示彩色条纹？
    ├─ 是 → PCIe正常，继续检查HDMI接收
    └─ 否 → 检查PCIe/DMA配置

[ ] video_locked LED是否亮？
    ├─ 是 → HDMI信号锁定，检查数据格式
    └─ 否 → MS7200未初始化或信号未锁定

[ ] hdmi_init_done信号是否为1？
    ├─ 是 → MS7200初始化成功
    └─ 否 → I2C配置失败

[ ] FMC卡是否完全插入？
    ├─ 是 → 继续检查
    └─ 否 → 重新插拔

[ ] HDMI线是否有问题？
    ├─ 用显示器测试正常 → 继续检查
    └─ 显示器也不行 → 更换HDMI线
```

---

## 推荐的诊断顺序

1. **先用测试图案验证PCIe链路**（最快排除传输问题）
2. 如果测试图案正常，添加LED调试HDMI接收
3. 根据LED状态决定下一步
4. 检查MS7200初始化代码
5. 尝试不同的HDMI分辨率

---

## 需要的文件

已创建的文件：
- `test_pattern_generator.v` - 测试图案生成器
- `test_pattern_instructions.txt` - 集成指导
- `BLACK_SCREEN_DIAGNOSIS.md` - 诊断指南
- `VIDEO_TRANSMISSION_GUIDE.md` - 完整传输指南

---

## 下一步

请告诉我：
1. 您是否方便重新编译FPGA？
2. 您想先尝试哪个解决方案？
3. 是否需要我帮您找LED引脚定义？
