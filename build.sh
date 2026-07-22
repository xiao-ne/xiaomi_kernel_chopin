#!/bin/bash

# ==================== 配置区 ====================
source ~/.bashrc && source ~/.profile

KERNEL_DIR="$HOME/xiaomi_kernel_chopin"
DEFCONFIG="chopin_defconfig"
RELEASE_DIR="$KERNEL_DIR/release"

# Ubuntu 系统交叉编译工具链
CROSS_COMPILE_PATH="aarch64-linux-gnu-"
CROSS_COMPILE_ARM32_PATH="arm-linux-gnueabi-"

KERNEL_VERSION="Clang13"
CLANG_VERSION="13"

# ==================== 工具函数 ====================
abort() { echo "❌ $1"; exit 1; }
ok() { echo "✅ $1"; }

# ==================== 编译（详细错误日志） ====================
build_kernel() {
    echo "编译内核 (Clang $CLANG_VERSION)..."
    cd "$KERNEL_DIR" || abort "内核目录不存在"
    
    # 获取时间戳
    local log_ts=$(date +%Y%m%d_%H%M%S)
    local full_log="full_${log_ts}.log"
    local error_log="error_${log_ts}.log"
    local detail_log="error_detail_${log_ts}.log"

    # 清理旧的编译产物
    make mrproper 2>/dev/null || true
    rm -rf out/

    # 设置交叉编译环境
    export ARCH=arm64 SUBARCH=arm64
    export CROSS_COMPILE="$CROSS_COMPILE_PATH"
    export CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32_PATH"
    export CLANG_TRIPLE=aarch64-linux-gnu-

    # 配置内核
    make O=out CC="ccache clang-$CLANG_VERSION" "$DEFCONFIG" || abort "配置失败"

    make O=out olddefconfig 2>/dev/null

    # 注入自定义内核版本后缀
    if [ -n "$KERNEL_VERSION" ]; then
        sed -i "s/CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=\"-${KERNEL_VERSION}\"/" out/.config
        make O=out olddefconfig 2>/dev/null
    fi

    # ========== BPF 兼容性配置 ==========
    # CONFIG_BPF_EVENTS 已在 kernel/trace/Kconfig 中设为 default n
    # 避免 __string() 宏与 BPF probe 展开不匹配导致编译失败

    # ========== 修复缺失的源文件配置 ==========
    # 禁用没有源文件的驱动配置
    local config="out/.config"
    if [ -f "$config" ]; then
        sed -i 's/^CONFIG_COMMON_CLK_MT8168=y/# CONFIG_COMMON_CLK_MT8168 is not set/' "$config"
        sed -i 's/^CONFIG_COMMON_CLK_MT8183=y/# CONFIG_COMMON_CLK_MT8183 is not set/' "$config"
        sed -i 's/^CONFIG_PINCTRL_MT8183=y/# CONFIG_PINCTRL_MT8183 is not set/' "$config"
        sed -i 's/^CONFIG_MTK_AEE_IPANIC=y/# CONFIG_MTK_AEE_IPANIC is not set/' "$config"
        echo "  缺失源文件配置已禁用"
    fi

    # 编译并保存完整日志（后台），同时实时显示错误
    echo "开始编译..."
    echo "📝 完整日志: $full_log"
    echo "📝 错误日志: $error_log"
    echo "📝 详细分析: $detail_log"
    
    # 编译并保存所有输出
    make O=out -j$(nproc) CC="ccache clang-$CLANG_VERSION" KCFLAGS="-w" Image 2>&1 | tee "$full_log"
    
    # 检查编译结果
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        # 提取错误和上下文
        echo "========================================" > "$detail_log"
        echo "编译错误详细分析" >> "$detail_log"
        echo "时间: $(date)" >> "$detail_log"
        echo "========================================" >> "$detail_log"
        echo "" >> "$detail_log"
        
        # 1. 提取所有错误行（带行号）
        echo "【错误列表】" >> "$detail_log"
        grep -n -E "(error:|Error:|ERROR:|undefined reference|failed:|致命错误)" "$full_log" >> "$detail_log"
        echo "" >> "$detail_log"
        
        # 2. 提取错误上下文（前后3行）
        echo "【错误上下文（前后3行）】" >> "$detail_log"
        grep -B3 -A3 -E "(error:|Error:|ERROR:|undefined reference|failed:|致命错误)" "$full_log" >> "$detail_log"
        echo "" >> "$detail_log"
        
        # 3. 提取未定义符号（链接错误）
        echo "【未定义符号】" >> "$detail_log"
        grep -E "undefined reference to" "$full_log" | sort -u >> "$detail_log"
        echo "" >> "$detail_log"
        
        # 4. 提取警告（可选，帮助诊断）
        echo "【相关警告】" >> "$detail_log"
        grep -E "(warning:|deprecated:|note:)" "$full_log" | head -50 >> "$detail_log"
        echo "" >> "$detail_log"
        
        # 5. 统计错误类型
        echo "【错误统计】" >> "$detail_log"
        local err_count=$(grep -c "error:" "$full_log" 2>/dev/null || echo 0)
        local undef_count=$(grep -c "undefined reference" "$full_log" 2>/dev/null || echo 0)
        local link_err=$(grep -c "ld:" "$full_log" 2>/dev/null || echo 0)
        echo "总错误数: $err_count" >> "$detail_log"
        echo "未定义符号: $undef_count" >> "$detail_log"
        echo "链接错误: $link_err" >> "$detail_log"
        echo "" >> "$detail_log"
        
        # 6. 提取第一个错误（往往最关键）
        echo "【首个错误】" >> "$detail_log"
        grep -m1 -B5 -A5 "error:" "$full_log" >> "$detail_log"
        echo "" >> "$detail_log"
        
        # 7. 提供修复建议
        echo "【修复建议】" >> "$detail_log"
        if grep -q "undefined reference to .*vfs_mkobj" "$full_log"; then
            echo "⚠️  vfs_mkobj 未定义 - 可能缺少相关头文件或内核版本不兼容" >> "$detail_log"
            echo "   修复: 确认 fs/ 目录代码完整，或检查 CONFIG_DEBUG_FS 是否开启" >> "$detail_log"
        fi
        if grep -q "undefined reference to .*bpf_ktime_get_boot_ns_proto" "$full_log"; then
            echo "⚠️  BPF 时间函数未定义 - 需要从 5.4+ 内核 backport bpf_ktime_get_boot_ns 到 4.14" >> "$detail_log"
            echo "   修复: 在 kernel/bpf/helpers.c 中添加 bpf_ktime_get_boot_ns 实现" >> "$detail_log"
        fi
        if grep -q "relocation R_AARCH64" "$full_log"; then
            echo "⚠️  重定位错误 - 可能是编译选项问题或工具链不匹配" >> "$detail_log"
            echo "   尝试: 更新交叉编译工具链或添加 -fPIC 编译选项" >> "$detail_log"
        fi
        if grep -q "No such file or directory" "$full_log"; then
            echo "⚠️  缺少头文件 - 检查内核源码是否完整" >> "$detail_log"
            echo "   尝试: 重新下载或同步内核源码" >> "$detail_log"
        fi
        echo "" >> "$detail_log"
        
        # 8. 显示错误摘要
        echo ""
        echo "==================== 错误摘要 ===================="
        echo ""
        echo "📊 统计: 错误 $err_count | 未定义符号 $undef_count | 链接错误 $link_err"
        echo ""
        echo "🔴 关键错误（前5个）:"
        grep -E "error:|undefined reference" "$full_log" | head -5
        echo ""
        echo "💡 查看详细分析: $detail_log"
        echo "📄 完整日志: $full_log"
        echo "=================================================="
        
        # 同时保存错误行到单独文件
        grep -E "(error:|Error:|ERROR:|undefined reference|failed:|致命错误)" "$full_log" > "$error_log"
        
        abort "编译失败"
    fi
    
    ok "编译成功"
}


# ==================== EROFS fstab 检测与修复 ====================
# 检查 ramdisk 中的 fstab 是否有 erofs 条目，没有就添加
# erofs 条目必须在 ext4 之前（否则会 bootloop）
add_erofs_to_fstab() {
    local fstab_file="$1"
    [ -f "$fstab_file" ] || return 0

    # 跳过没有 ext4 条目的 fstab（如 fstab.tuna）
    grep -qE "^(system|vendor|product|mi_ext|system_ext) .* ext4" "$fstab_file" 2>/dev/null || return 0

    echo "  🔧 检查 fstab: $(basename "$fstab_file")"

    local tmp_fstab="${fstab_file}.tmp"
    cp "$fstab_file" "$tmp_fstab"

    # 定义需要添加 erofs 的分区及其对应的 ext4 行匹配模式
    # 格式: "分区名|挂载点|erofs选项|匹配的ext4行关键词"
    local partitions=(
        "system|/system|ro wait,slotselect,avb=vbmeta_system,logical,first_stage_mount,avb_keys=/avb/q-gsi.avbpubkey:/avb/r-gsi.avbpubkey:/avb/s-gsi.avbpubkey|^system .* ext4"
        "vendor|/vendor|ro wait,slotselect,avb,logical,first_stage_mount|^vendor .* ext4"
        "product|/product|ro wait,slotselect,avb,logical,first_stage_mount|^product .* ext4"
        "mi_ext|/mnt/vendor/mi_ext|ro wait,slotselect,avb=vbmeta,logical,first_stage_mount,nofail|^mi_ext .* ext4"
        "system_ext|/system_ext|ro wait,avb,logical,first_stage_mount,slotselect|^system_ext .* ext4"
    )

    local modified=0
    for entry in "${partitions[@]}"; do
        IFS='|' read -r part mount opts ext4_pattern <<< "$entry"

        # 检查该分区是否已有 erofs 条目
        if grep -q "^${part} .* erofs" "$tmp_fstab" 2>/dev/null; then
            continue
        fi

        # 查找对应的 ext4 行
        local ext4_line=$(grep -m1 "$ext4_pattern" "$tmp_fstab" 2>/dev/null)
        if [ -z "$ext4_line" ]; then
            continue
        fi

        # 生成 erofs 行：将 ext4 替换为 erofs，其余保持不变
        local erofs_line=$(echo "$ext4_line" | sed "s| ${part} | ${mount} erofs ${opts}|" | sed 's| ext4 | erofs |')

        # 如果 sed 替换失败（格式不匹配），用备用方案构造
        if [ -z "$erofs_line" ] || ! echo "$erofs_line" | grep -q "erofs"; then
            erofs_line="${part} ${mount} erofs ${opts}"
        fi

        # 在 ext4 行之前插入 erofs 行
        sed -i "/^${part} .* ext4/i\\${erofs_line}" "$tmp_fstab"
        modified=1
        echo "    + ${part}: erofs 条目已添加"
    done

    if [ "$modified" -eq 1 ]; then
        cp "$tmp_fstab" "$fstab_file"
        echo "  ✅ fstab 修复完成"
    else
        echo "  ℹ️  fstab 已包含 erofs，无需修改"
    fi
    rm -f "$tmp_fstab"
}

pack_img() {
    local img_dir="$KERNEL_DIR/out/arch/arm64/boot"
    local boot_dir="$KERNEL_DIR/boot"
    local tmp="$boot_dir/tmp_$$"
    local ts=$(date +%Y%m%d_%H%M%S)

    cd "$boot_dir" || abort "boot目录不存在"
    rm -rf "$tmp" && mkdir "$tmp" && cd "$tmp"

    ../magiskboot unpack ../boot.img || abort "解包失败"
    [ -f "$img_dir/Image.gz" ] && cp "$img_dir/Image.gz" kernel || cp "$img_dir/Image" kernel
    [ -f "$img_dir/dtb" ] && cp "$img_dir/dtb" .
    [ -f "$img_dir/dtbo.img" ] && cp "$img_dir/dtbo.img" .

    # ========== EROFS fstab 检测与修复 ==========
    echo "🔍 检查 ramdisk fstab 是否包含 erofs..."
    if [ -f ramdisk.cpio ]; then
        local rd_tmp="_rd_fix$$"
        mkdir -p "$rd_tmp" && cd "$rd_tmp"
        cpio -idm < ../ramdisk.cpio 2>/dev/null

        # 修复 first_stage_ramdisk 中的 fstab
        for fstab in first_stage_ramdisk/fstab.*; do
            [ -f "$fstab" ] && add_erofs_to_fstab "$fstab"
        done

        # 重新打包 ramdisk
        find . | cpio -H newc -o 2>/dev/null > ../ramdisk.cpio
        cd ..
        rm -rf "$rd_tmp"
        echo "✅ ramdisk 已更新"
    fi

    local out="$RELEASE_DIR/boot-${KERNEL_VERSION}-${ts}.img"
    ../magiskboot repack ../boot.img "$out" || abort "打包失败"
    ok "boot.img: $out"
    cd "$boot_dir" && rm -rf "$tmp"
}

# ==================== 一次性依赖安装 ====================
SETUP_FLAG="$HOME/.chopin_kernel_setup_done"

setup_once() {
    if [ -f "$SETUP_FLAG" ]; then
        echo "依赖已安装，跳过设置"
        return
    fi

    echo "首次运行，安装依赖..."
    
    # 安装 Clang
    if ! command -v clang-$CLANG_VERSION > /dev/null; then
        echo "安装 Clang $CLANG_VERSION..."
        sudo apt-get update -qq
        sudo apt-get install -y clang-$CLANG_VERSION lld-$CLANG_VERSION llvm-$CLANG_VERSION
    fi

    # 安装交叉编译工具链
    if ! command -v aarch64-linux-gnu-gcc > /dev/null; then
        echo "安装 ARM64 交叉编译工具链..."
        sudo apt-get install -y gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
    fi
    if ! command -v arm-linux-gnueabi-gcc > /dev/null; then
        echo "安装 ARM32 交叉编译工具链..."
        sudo apt-get install -y gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi
    fi

    # 安装编译依赖
    local pkgs=(build-essential flex bison libssl-dev libelf-dev bc cpio rsync zip make python3 ccache)
    sudo apt-get install -y "${pkgs[@]}" 2>/dev/null

    # 标记完成
    touch "$SETUP_FLAG"
    ok "依赖安装完成"
    
    echo ""
    echo "按回车继续..."
    read
}

# ==================== 清理日志 ====================
clean_logs() {
    echo "清理旧日志..."
    find "$KERNEL_DIR" -maxdepth 1 -name "full_*.log" -mtime +3 -delete 2>/dev/null
    find "$KERNEL_DIR" -maxdepth 1 -name "error_*.log" -mtime +3 -delete 2>/dev/null
    find "$KERNEL_DIR" -maxdepth 1 -name "error_detail_*.log" -mtime +3 -delete 2>/dev/null
    ok "已清理超过3天的日志"
}

# ==================== 查看最近错误 ====================
show_error() {
    local latest_detail=$(ls -t "$KERNEL_DIR"/error_detail_*.log 2>/dev/null | head -1)
    local latest_error=$(ls -t "$KERNEL_DIR"/error_*.log 2>/dev/null | head -1)
    
    if [ -n "$latest_detail" ]; then
        echo "==================== 详细错误分析 ===================="
        cat "$latest_detail"
        echo ""
        echo "文件: $latest_detail"
    elif [ -n "$latest_error" ]; then
        echo "==================== 错误日志 ===================="
        cat "$latest_error"
    else
        echo "没有找到错误日志"
    fi
}

# ==================== 主流程 ====================
setup_once
mkdir -p "$RELEASE_DIR"
ccache -M 32G

echo ""
echo "  Xiaomi chopin 内核编译"
echo ""

read -p "版本名 (默认 $KERNEL_VERSION): " v
[ -n "$v" ] && KERNEL_VERSION="$v"

echo ""
echo "1) 编译+打包  2) 仅编译  3) 仅打包  4) 清理旧日志  5) 查看最近错误"
read -p "选择: " c

case $c in
    1) build_kernel && pack_img ;;
    2) build_kernel ;;
    3) pack_img ;;
    4) clean_logs ;;
    5) show_error ;;
    *) echo "无效选择" ;;
esac

echo ""
echo "输出: $RELEASE_DIR"
ls -lh "$RELEASE_DIR"/*.img 2>/dev/null

# 显示日志文件
echo ""
echo "📋 日志文件:"
ls -lth "$KERNEL_DIR"/*_*.log 2>/dev/null | head -5