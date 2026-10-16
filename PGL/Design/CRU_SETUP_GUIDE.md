# 使用CRU强制HDMI输出 - 详细步骤

## 下载CRU工具

### 下载地址
- 官方论坛: https://www.monitortests.com/forum/Thread-Custom-Resolution-Utility-CRU
- 或搜索: "Custom Resolution Utility CRU download"

### 下载文件
- 文件名: CRU.zip
- 大小: 约500KB
- 免费、绿色、无需安装

---

## 使用步骤

### 1. 解压并运行
```
1. 解压CRU.zip到任意文件夹
2. 右键 CRU.exe → 以管理员身份运行
```

### 2. 选择HDMI输出
```
1. 在顶部下拉菜单中选择显示器
2. 找到您的HDMI输出（可能显示为"未知"或显示器型号）
3. 如果有多个，选择连接FMC卡的那个
```

### 3. 添加标准分辨率
```
1. 在"Standard resolutions"区域
2. 点击"Add..."按钮
3. 设置参数：
   - Active (像素): 
     - Horizontal: 1280
     - Vertical: 720
   - Refresh rate: 60 Hz
   - Timing: Automatic (或选择 CVT-RB)
4. 点击"OK"
```

### 4. 保存并重启驱动
```
1. 点击右上角的"OK"关闭CRU
2. 运行 restart64.exe（或restart.exe，32位系统）
   - 这会重启显卡驱动，屏幕会黑一下
3. 等待几秒钟恢复
```

### 5. 应用新分辨率
```
1. 右键桌面 → 显示设置
2. 滚动到"多个显示器"
3. 点击"检测"
4. 选择"扩展这些显示器"
5. 选择1280×720分辨率
6. 点击"应用"
```

---

## 截图示例

### CRU主界面应该看到：
```
┌─ Custom Resolution Utility ─────────────┐
│ [Display dropdown]         ▼             │
│                                          │
│ Standard resolutions:                    │
│ ┌──────────────────────────────────┐    │
│ │ 1280 × 720 @ 60 Hz              │    │ ← 添加这个
│ └──────────────────────────────────┘    │
│ [Add...] [Edit...] [Delete]             │
│                                          │
│ [OK] [Cancel]                            │
└──────────────────────────────────────────┘
```

---

## 常见问题

### Q1: 运行CRU时提示权限不足
**解决**: 右键CRU.exe → 以管理员身份运行

### Q2: 运行restart64.exe后屏幕不恢复
**解决**: 等待30秒，或按Ctrl+Alt+Del重新登录

### Q3: 添加分辨率后显示设置里还是没有
**解决**: 
1. 重启电脑
2. 检查是否选择了正确的显示器
3. 尝试添加为"Detailed resolution"而不是"Standard resolution"

### Q4: 不知道选择哪个显示器
**解决**: 
1. 先断开HDMI连接FMC卡
2. 运行CRU，记录显示器列表
3. 连接FMC卡
4. 再次运行CRU，新出现的就是HDMI输出

---

## 如果CRU也不行

### 最终方案：购买EDID模拟器

**淘宝/京东搜索关键词**:
- "HDMI EDID模拟器"
- "HDMI假负载"
- "HDMI虚拟显示器"
- "HDMI dummy plug"

**推荐型号**:
- 支持1920×1080或更高
- 价格: 20-50元
- 即插即用，无需设置

**连接方式**:
```
电脑HDMI口 → EDID模拟器 → HDMI线 → FMC卡
```

**优点**:
- 彻底解决问题
- 电脑会自动识别为显示器
- Win+P可以正常切换
- 支持任意分辨率

---

## 验证是否成功

### 步骤1: Windows显示设置
```
Win+P → 应该能看到投影选项
显示设置 → 应该能看到"显示器2"
```

### 步骤2: 在RK3568上测试
```bash
# 播放一个视频或显示图片
# 在电脑的"第二屏幕"上（即HDMI输出）

# 在RK3568上采集
./pango_rgb565_receiver --display ppm --ppm-dir /tmp/test --frames 1

# 检查数据
hexdump -C /tmp/test/frame_000000.ppm | head -20
```

**如果看到非零数据** → 成功！
**如果还是全0** → 需要进一步排查FMC卡和FPGA
