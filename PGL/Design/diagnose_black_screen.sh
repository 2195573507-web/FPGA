#!/bin/bash
# 在RK3568上运行此脚本来诊断全黑画面问题

echo "=== HDMI黑屏诊断脚本 ==="
echo ""

# 1. 保存一帧原始数据
echo "[1/4] 保存原始帧数据..."
./pango_rgb565_receiver --save-raw /tmp/frame.raw --frames 1 2>/dev/null

# 2. 检查文件大小
echo "[2/4] 检查文件大小..."
filesize=$(stat -c%s "/tmp/frame.raw" 2>/dev/null)
echo "文件大小: $filesize 字节"

# 计算理论大小
rgb565_size=$((1920 * 1080 * 2))
rgb888_size=$((1920 * 1080 * 3))
rgb888_padded=$((1920 * 1080 * 4))  # 32-bit per pixel

echo "  RGB565应该是: $rgb565_size 字节 (1920x1080x2)"
echo "  RGB888应该是: $rgb888_size 字节 (1920x1080x3)"
echo "  RGB888(32bit)应该是: $rgb888_padded 字节 (1920x1080x4)"

if [ "$filesize" = "$rgb888_padded" ]; then
    echo "  ⚠️  格式不匹配！FPGA发送RGB888(32bit)，但程序期望RGB565"
elif [ "$filesize" = "$rgb565_size" ]; then
    echo "  ✓ 格式匹配RGB565"
elif [ "$filesize" = "0" ]; then
    echo "  ❌ 文件为空，没有接收到数据"
else
    echo "  ❓ 未知格式，实际大小: $filesize"
fi

# 3. 查看前64字节的数据
echo ""
echo "[3/4] 查看原始数据（前64字节）..."
hexdump -C /tmp/frame.raw | head -5

# 4. 检查数据是否全为0
echo ""
echo "[4/4] 检查是否全黑（全0）..."
nonzero=$(hexdump -v -e '1/1 "%02x\n"' /tmp/frame.raw | head -1000 | grep -v "^00$" | wc -l)
if [ "$nonzero" = "0" ]; then
    echo "  ❌ 数据全为0 - 确实是全黑画面"
    echo "     可能原因："
    echo "     1. HDMI信号未锁定（MS7200未初始化）"
    echo "     2. 电脑HDMI输出分辨率不匹配"
    echo "     3. FMC卡连接问题"
else
    echo "  ✓ 数据中有非零值（找到 $nonzero 个非零字节）"
    echo "     可能原因："
    echo "     1. 像素格式不匹配（RGB888 vs RGB565）"
    echo "     2. 字节序错误（R/G/B顺序）"
    echo "     3. 接收程序解析错误"
fi

echo ""
echo "=== 诊断完成 ==="
