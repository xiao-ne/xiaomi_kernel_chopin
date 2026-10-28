#!/bin/bash

# ==================== 配置区 ====================
source ~/.bashrc && source ~/.profile

# pahole (dwarves) 免 root 安装在 ~/local-tools，用于生成 vmlinux BTF
# (CONFIG_DEBUG_INFO_BTF)。Ubuntu 的 ~/.bashrc 对非交互 shell 会 early return,
# 所以这里显式补一次 PATH，避免 BTF 被静默跳过。
if [ -x "$HOME/local-tools/root/usr/bin/pahole" ]; then
    export PATH="$HOME/local-tools/root/usr/bin:$PATH"
fi

KERNEL_DIR="$HOME/xiaomi_kernel_chopin"
# A17 用的完整配置（chopin_defconfig 缺 28+ 个 MTK 驱动项，会卡在早期 init）
DEFCONFIG="chopin_a17_defconfig"
RELEASE_DIR="$KERNEL_DIR/release"

# Ubuntu 系统交叉编译工具链
CROSS_COMPILE_PATH="aarch64-linux-gnu-"
CROSS_COMPILE_ARM32_PATH="arm-linux-gnueabi-"

KERNEL_VERSION="Clang13"
CLANG_VERSION="13"

# ==================== 工具函数 ====================
abort() { echo "❌ $1"; exit 1; }
ok() { echo "✅ $1"; }
warn() { echo "⚠️  $1"; }

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

    # 预生成 uapi asm-generic 包装头 (rm -rf out 后首次 defconfig 需要, 否则 'asm/types.h' not found)
    mkdir -p out/arch/arm64/include/generated/uapi out/arch/arm64/include/generated
    make -f scripts/Makefile.asm-generic src=uapi/asm obj=out/arch/arm64/include/generated/uapi/asm srctree=. SRCARCH=arm64 || abort "uapi asm 包装头生成失败"
    make -f scripts/Makefile.asm-generic src=asm obj=out/arch/arm64/include/generated/asm srctree=. SRCARCH=arm64 || abort "asm 包装头生成失败"

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

    # CONFIG_DEBUG_INFO_BTF 需要 pahole；缺了不会报错，只会静默不生成 BTF，
    # 而 Android 17 的 CO-RE 依赖 /sys/kernel/btf/vmlinux，所以这里直接拦住。
    if grep -q '^CONFIG_DEBUG_INFO_BTF=y' "$config" 2>/dev/null; then
        command -v pahole > /dev/null || abort "pahole 未安装 - BTF 不会生成，Android 17 CO-RE 会失败"
        ok "pahole: $(pahole --version 2>&1 | head -1)"
    fi

    # KernelSU-Next 版本号兜底：子模块缺少 .git 元数据（备份恢复/换机后常见）时，
    # kernel/Kbuild 会把 KSU_VERSION 退化成 1，管理器会判定内核过旧而不放 root。
    # 27c191da 的真实提交数是 2981，故 30000 + 2981 + 150 = 33131。
    # 判据必须是「真的能取到子模块自己的提交数」，只看 .git 是否存在会漏掉
    # gitlink 悬空（.git 是个指向已丢失的 .git/modules/... 的文本文件）、
    # dubious ownership 等情形 —— 那时 git 会向上回退到内核仓库，
    # Kbuild 探测失败后把 KSU_VERSION 退化成 1。
    KSU_FALLBACK_ARGS=""
    _ksu_root=$( cd drivers/kernelsu 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null )
    _kern_root=$( git rev-parse --show-toplevel 2>/dev/null )
    if [ -n "$_ksu_root" ] && [ "$_ksu_root" != "$_kern_root" ]; then
        _ksu_count=$( git -C "$_ksu_root" rev-list --count HEAD 2>/dev/null )
    else
        _ksu_count=""
    fi
    if [ -z "${_ksu_count:-}" ] || [ "${_ksu_count:-0}" = "0" ]; then
        KSU_FALLBACK_ARGS="KSU_GIT_VERSION_VALID=1 KSU_GIT_VERSION=2981 KSU_GIT_TAG=v3.2.0"
        echo "⚠️  drivers/kernelsu 取不到 git 提交数（.git 缺失/损坏/gitlink 悬空），兜底 KSU 版本 33131"
    else
        ok "KernelSU-Next 版本来源: git（${_ksu_count} 个提交）"
    fi

    # 编译并保存完整日志（后台），同时实时显示错误
    echo "开始编译..."
    echo "📝 完整日志: $full_log"
    echo "📝 错误日志: $error_log"
    echo "📝 详细分析: $detail_log"
    
    # 编译并保存所有输出
    make O=out -j$(nproc) CC="ccache clang-$CLANG_VERSION" KCFLAGS="-w" $KSU_FALLBACK_ARGS Image 2>&1 | tee "$full_log"
    
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

    # ========== 底包选择与校验 ==========
    # 绝不能把内核塞进原厂 A13 的 user ramdisk：那种 ramdisk 缺 androidboot.selinux=enforcing、
    # first_stage fstab 只有 ext4+AVB，内核配它会第一屏就死并回落 fastboot。
    local base_img="${BASE_IMG:-$boot_dir/boot.img}"
    _base_ok() { [ -f "$1" ] && strings -a -n 8 "$1" | grep -q 'androidboot.selinux=enforcing'; }
    if ! _base_ok "$base_img"; then
        if [ -n "${BASE_IMG:-}" ]; then
            abort "BASE_IMG=$base_img 不是可开机底包（缺 androidboot.selinux=enforcing），拒绝打包"
        fi
        warn "boot/boot.img 不是可开机底包（疑似原厂 user 镜像），自动改用已验证底包"
        local cand
        for cand in "$boot_dir/boot.img.good" \
                    "$RELEASE_DIR/boot-Clang13-ksu-20261026_0240.img" \
                    $(ls -t "$RELEASE_DIR"/boot-*.img 2>/dev/null); do
            if _base_ok "$cand"; then base_img="$cand"; break; fi
        done
        _base_ok "$base_img" || abort "找不到可开机底包：把 eng ramdisk 镜像放回 boot/boot.img，或 export BASE_IMG=/path/to/img"
        ok "底包: $base_img"
    fi

    ../magiskboot unpack "$base_img" || abort "解包失败"
    [ -f "$img_dir/Image.gz" ] && cp "$img_dir/Image.gz" kernel || cp "$img_dir/Image" kernel
    [ -f "$img_dir/dtb" ] && cp "$img_dir/dtb" .
    [ -f "$img_dir/dtbo.img" ] && cp "$img_dir/dtbo.img" .

    # 显示 kernel 版本串（打包前最后确认，防 out/ 被别的构建污染刷错内核）
    local _kver
    if file kernel | grep -q "gzip"; then
        _kver=$(zcat kernel 2>/dev/null | strings -a | grep -m1 "Linux version")
    else
        _kver=$(strings -a kernel | grep -m1 "Linux version")
    fi
    echo "🔍 kernel 版本: ${_kver:-未知}"

    # ========== EROFS fstab 检测与修复 ==========
    # 检查 ramdisk 的 fstab，缺 erofs 条目就补上（add_erofs_to_fstab 幂等）。
    # 关键约束：只有在 fstab 真的被改动时才重压 ramdisk，而且重压必须
    #   1) 保持原包的条目顺序（用原 cpio 的名字列表驱动 cpio -o，不要 find）
    #   2) 强制 root:root 属主（-R 0:0）
    # 否则会出现「第一屏无限重启」：以普通用户身份 cpio -o 会把 2854 个条目的
    # uid/gid 全写成 1000，Android 首阶段 init 直接起不来。
    echo "🔍 检查 ramdisk fstab 是否包含 erofs..."
    if [ -f ramdisk.cpio ]; then
        local rd_ref="_rd_ref$$"
        local rd_new="_rd_new$$"
        rm -rf "$rd_ref" "$rd_new"
        mkdir -p "$rd_ref" "$rd_new"
        ( cd "$rd_ref" && cpio -idm --quiet 'first_stage_ramdisk/fstab.*' < ../ramdisk.cpio 2>/dev/null )
        ( cd "$rd_new" && cpio -idm --quiet < ../ramdisk.cpio 2>/dev/null )

        for fstab in "$rd_new"/first_stage_ramdisk/fstab.*; do
            [ -f "$fstab" ] && add_erofs_to_fstab "$fstab"
        done

        local _changed=0
        local _f _b
        for _f in "$rd_new"/first_stage_ramdisk/fstab.*; do
            [ -f "$_f" ] || continue
            _b="$rd_ref/first_stage_ramdisk/$(basename "$_f")"
            if [ -f "$_b" ]; then cmp -s "$_f" "$_b" || _changed=1; else _changed=1; fi
        done

        if [ "$_changed" -eq 0 ]; then
            echo "ℹ️  ramdisk 的 fstab 无需修改，保持原样（不重压，避免破坏属主/顺序）"
        else
            ( cd "$rd_new" && cpio -it --quiet < ../ramdisk.cpio 2>/dev/null \
                | cpio -H newc -o -R 0:0 --quiet > ../ramdisk.cpio.new ) \
                && mv -f ramdisk.cpio.new ramdisk.cpio
            ok "ramdisk 已更新（保持原顺序 + root:root 属主）"
        fi
        rm -rf "$rd_ref" "$rd_new"
    fi

    local out="$RELEASE_DIR/boot-${KERNEL_VERSION}-${ts}.img"
    ../magiskboot repack "$base_img" "$out" || abort "打包失败"
    ok "boot.img: $out"
    echo "   kernel sha256: $(sha256sum kernel | cut -d' ' -f1)"
    echo "   底包: $(basename "$base_img")"
    cd "$boot_dir" && rm -rf "$tmp"
}

# ==================== 内核体检（原 check_kernel.sh 的功能，已并进来） ====================
check_kernel() {
    cd "$KERNEL_DIR" || abort "内核目录不存在"
    local img="out/arch/arm64/boot/Image"
    local vml=out/vmlinux
    local map=out/System.map

    echo "================ 1. 版本与产物 ================"
    grep -m2 -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION)' Makefile
    if [ -f "$img" ]; then
        ok "Image: $(stat -c %s "$img") 字节  sha256=$(sha256sum "$img" | cut -c1-16)…"
        strings "$img" | grep -m1 "Linux version"
    else
        echo "❌ 还没有 Image（先跑一次编译）"
    fi
    if [ -f "$vml" ]; then
        local btf_hex=$(readelf -SW "$vml" 2>/dev/null | awk '$2 == ".BTF" {print $6}')
        if [ -n "$btf_hex" ]; then
            local btf_dec=$((16#$btf_hex))
            ok ".BTF 段: $btf_dec 字节"
        else
            echo "❌ vmlinux 里没有 .BTF 段（CO-RE 会失败）"
        fi
    fi

    echo
    echo "================ 2. 关键符号（System.map） ================"
    if [ -f "$map" ]; then
        local syms="start_kernel kernel_init bpf_ringbuf_reserve bpf_ringbuf_submit bpf_ringbuf_discard bpf_ringbuf_output bpf_ringbuf_query bpf_sk_lookup_tcp bpf_sk_lookup_udp bpf_sk_release bpf_get_socket_cookie_sock bpf_sk_storage_get tnum_arshift __cgroup_bpf_run_filter_getsockopt __cgroup_bpf_run_filter_setsockopt ksu_handle_execveat ksu_handle_susfs_cmd"
        local miss=0
        for s in $syms; do
            local line
            line=$(grep -m1 -E " $s\$" "$map")
            if [ -n "$line" ]; then
                printf 'OK   %s\n' "$line"
            else
                printf 'MISS %s\n' "$s"
                miss=$((miss+1))
            fi
        done
        [ "$miss" -eq 0 ] && ok "关键符号齐全" || echo "⚠️  缺 $miss 个符号"
        local nksu
        nksu=$(grep -cE ' [tT] ksu_' "$map")
        [ "$nksu" -gt 100 ] && ok "KernelSU 符号 $nksu 个" || echo "⚠️  KernelSU 符号只有 $nksu 个（KSU 可能没编进去）"
    else
        echo "❌ 没有 System.map"
    fi

    echo
    echo "================ 3. 关键 CONFIG ================"
    if [ -f out/.config ]; then
        grep -E '^CONFIG_(LOCALVERSION|DEBUG_INFO_BTF|BPF_SYSCALL|PSI|BLK_CGROUP|CGROUP_DEVICE|CGROUP_PIDS|EROFS_FS|EROFS_FS_XATTR|KSU|MTK_RAM_CONSOLE|MTK_AEE_IPANIC|PANIC_ON_OOPS|PANIC_TIMEOUT|ARCH_MTK_PROJECT)=' out/.config
        local ncfg
        ncfg=$(grep -c '^CONFIG_' out/.config)
        echo "配置项总数: $ncfg"
    else
        echo "❌ 没有 out/.config"
    fi

    echo
    echo "================ 4. Android 17 移植要点是否在位 ================"
    _grep_point() {
        if grep -q "$2" "$1" 2>/dev/null; then printf 'OK   %s\n' "$3"; else printf 'MISS %s\n' "$3"; fi
    }
    _grep_point kernel/sys.c '5\.10\.209'            "uname 欺骗 -> 5.10.209"
    _grep_point include/uapi/linux/bpf.h 'BPF_CGROUP_INET_SOCK_RELEASE' "attach type 34 (sock release)"
    _grep_point net/core/filter.c 'bpf_sk_base_func_proto'              "cgroup_skb 的 sk_lookup 分派"
    _grep_point kernel/bpf/verifier.c 'check_mem_region_access'          "PTR_TO_MEM 帮助函数入参"
    _grep_point kernel/bpf/verifier.c 'case BPF_ARSH:'                   "ARSH 标量跟踪"
    _grep_point net/socket.c 'BPF_CGROUP_RUN_PROG_GETSOCKOPT'            "sockopt 钩子调用点"
    _grep_point net/core/bpf_sk_storage.c 'ARG_PTR_TO_SOCK_COMMON'       "sk_storage 接受 sock_common"

    echo
    echo "================ 5. 残留调试打印检查 ================"
    if [ -f "$img" ]; then
        local dbg
        dbg=$(strings "$img" | grep -c 'bpfdbg')
        [ "$dbg" -eq 0 ] && ok "无 bpfdbg 调试打印" || echo "⚠️  Image 里还有 $dbg 处 bpfdbg 打印"
    fi

    echo
    echo "================ 6. 打包产物 ================"
    ls -lht "$RELEASE_DIR"/*.img 2>/dev/null | head -5 || echo "（还没有 release 包）"

    echo
    echo "================ 7. 工具链 ================"
    echo "clang-$CLANG_VERSION: $(clang-$CLANG_VERSION --version 2>/dev/null | head -1)"
    echo "pahole: $(pahole --version 2>&1 | head -1)"
    echo "ccache: $(ccache --version 2>/dev/null | head -1)"

    echo
    echo "================ 8. 仓库状态 ================"
    git log -3 --oneline 2>/dev/null
    local dirty
    dirty=$(git status --porcelain 2>/dev/null | wc -l)
    [ "$dirty" -eq 0 ] && ok "工作区干净" || echo "⚠️  有 $dirty 个未提交改动"

    echo
    echo "================ 9. 最近一次构建日志 ================"
    local latest
    latest=$(ls -t "$KERNEL_DIR"/full_*.log 2>/dev/null | head -1)
    if [ -n "$latest" ]; then
        echo "文件: $latest"
        tail -12 "$latest"
    else
        echo "（无构建日志）"
    fi
    echo
    ok "体检结束"
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
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
setup_once
mkdir -p "$RELEASE_DIR"
ccache -M 32G

echo ""
echo "  Xiaomi chopin 内核编译"
echo ""

# 命令行模式：./build.sh all|compile|pack|check|cleanlog|error
MODE=""
case "${1:-}" in
    all|compile|pack|check|cleanlog|error) MODE="$1" ;;
    "") ;;
    *) echo "用法: ./build.sh [all|compile|pack|check|cleanlog|error]"; exit 1 ;;
esac

if [ -z "$MODE" ]; then
    read -p "版本名 (默认 $KERNEL_VERSION): " v
    [ -n "$v" ] && KERNEL_VERSION="$v"

    echo ""
    echo "1) 编译+打包  2) 仅编译  3) 仅打包  4) 清理旧日志  5) 查看最近错误  6) 内核体检"
    read -p "选择: " c
else
    echo "模式: $MODE"
    case $MODE in
        all) c=1 ;; compile) c=2 ;; pack) c=3 ;; cleanlog) c=4 ;; error) c=5 ;; check) c=6 ;;
    esac
fi

case $c in
    1) build_kernel && pack_img ;;
    2) build_kernel ;;
    3) pack_img ;;
    4) clean_logs ;;
    5) show_error ;;
    6) check_kernel ;;
    *) echo "无效选择" ;;
esac

echo ""
echo "输出: $RELEASE_DIR"
ls -lh "$RELEASE_DIR"/*.img 2>/dev/null

# 显示日志文件
echo ""
echo "📋 日志文件:"
ls -lth "$KERNEL_DIR"/*_*.log 2>/dev/null | head -5
fi
