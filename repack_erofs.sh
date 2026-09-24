#!/bin/bash
# 重打包 boot.img：新 kernel + ramdisk(注入 erofs fstab 条目)
# 用于 EROFS 分区 ROM：first_stage init 在 ext4 条目前多一条 erofs，优先按 erofs 挂载
set -e
KDIR="$HOME/xiaomi_kernel_chopin"
BOOT="$KDIR/boot/boot.img"
# kernel 来源：已验证的 -Chopin-su-tb 镜像(而非 out/ 里可能被他会话污染的 Image)
REFIMG="$KDIR/release/boot-Chopin-su-tb-20260924_053312.img"
TMP="$KDIR/boot/tmp_erofs_$$"
TS=$(date +%Y%m%d_%H%M%S)
OUT="$KDIR/release/boot-Chopin-su-tb-erofs-$TS.img"

# 1. 向指定 fstab 注入 erofs 条目(在每个 ext4 分区行前插一条 erofs 版)
inject_erofs() {
    local f="$1"
    [ -f "$f" ] || return 0
    local tmp="$f.tmp"
    cp "$f" "$tmp"
    for part in system vendor product mi_ext system_ext; do
        # 已有 erofs 则跳过
        grep -qE "^${part} .* erofs" "$tmp" && continue
        # 找到该分区的 ext4 行
        local ext4line=$(grep -m1 -E "^${part} .*( ext4 | ext4$)" "$tmp" 2>/dev/null || true)
        [ -z "$ext4line" ] && continue
        # 生成 erofs 行：把第3列 ext4 换成 erofs
        local erofsline
        erofsline=$(printf '%s\n' "$ext4line" | sed -E 's/^([[:space:]]*[^[:space:]]+ [^[:space:]]+) ext4 /\1 erofs /')
        [ -z "$erofsline" ] && continue
        # 插到该 ext4 行之前
        local line_no
        line_no=$(grep -n -E "^${part} .*( ext4 | ext4$)" "$tmp" | head -1 | cut -d: -f1)
        sed -i "$((line_no-1))i $erofsline" "$tmp"
        echo "    + ${part}: erofs 条目已插入(fstab 第${line_no}行前)"
    done
    mv "$tmp" "$f"
}

echo "==> 解包 $BOOT"
cd "$KDIR/boot"
rm -rf "$TMP" && mkdir "$TMP" && cd "$TMP"
../magiskboot unpack ../boot.img

echo "==> 提取已验证的 -Chopin-su-tb kernel (来自 $REFIMG)"
K2="$KDIR/boot/tmp_ref_$$"
rm -rf "$K2" && mkdir "$K2" && cd "$K2"
$KDIR/boot/magiskboot unpack "$REFIMG" >/dev/null 2>&1
cd "$TMP"
cp "$K2/kernel" kernel
cp "$K2/dtb" . 2>/dev/null || cp ../boot/dtb . 2>/dev/null || true
cp "$K2/ramdisk.cpio" ramdisk.cpio 2>/dev/null || true
rm -rf "$K2"
echo "    kernel 版本:"; strings -a kernel | grep -m1 "Linux version"

echo "==> 处理 ramdisk fstab"
if [ -f ramdisk.cpio ]; then
    RD=_rd_erofs
    mkdir -p "$RD" && cd "$RD"
    cpio -idm < ../ramdisk.cpio 2>/dev/null
    for fstab in first_stage_ramdisk/fstab.*; do
        [ -f "$fstab" ] && { echo "  注入: $fstab"; inject_erofs "$fstab"; }
    done
    find . | cpio -H newc -o 2>/dev/null > ../ramdisk.cpio
    cd ..
    rm -rf "$RD"
    echo "==> ramdisk 已重打包"
fi

echo "==> 重打包 boot.img"
../magiskboot repack ../boot.img "$OUT" 2>&1 | grep -E "Repack|KERNEL_SZ|DTB_SZ" || true
rm -rf "$TMP"
echo ""
echo "输出: $OUT"
ls -lh "$OUT"
