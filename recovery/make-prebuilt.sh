#!/bin/bash
# 从内核构建产物生成 TWRP device tree 需要的那两个预编译件：
#   prebuilt/kernel  —— gzip 过的 Image（TWRP 的 TARGET_PREBUILT_KERNEL 要的是这个格式）
#   prebuilt/dtb.img —— chopin 的 dtb
#
# 用法：
#   ./recovery/make-prebuilt.sh --out <device_tree>/prebuilt
#   ./recovery/make-prebuilt.sh --image out/arch/arm64/boot/Image --dtb boot/boot.img --out /tmp/prebuilt
#
# 不给 --image 时用 out/arch/arm64/boot/Image；不给 --dtb 时从 boot/boot.img 解包取。

set -euo pipefail

KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE="$KERNEL_DIR/out/arch/arm64/boot/Image"
DTB_SRC=""
OUT=""
KERNEL_ONLY=0

usage() {
    cat <<'EOF'
用法: recovery/make-prebuilt.sh --out DIR [--image PATH] [--dtb PATH] [--kernel-only]

  --out         输出目录，通常指向 device tree 的 prebuilt/
  --image       内核镜像，Image 或 Image.gz（默认 out/arch/arm64/boot/Image）
  --dtb         dtb 文件，或含 dtb 的 boot.img（默认 boot/boot.img）
  --kernel-only 只生成 prebuilt/kernel，不动 dtb（chopin 的 dtb 是固定的，CI 里拿不到 boot.img 时用这个）
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --dtb)   DTB_SRC="$2"; shift 2 ;;
        --out)   OUT="$2"; shift 2 ;;
        --kernel-only) KERNEL_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1"; usage; exit 1 ;;
    esac
done

[ -n "$OUT" ] || { echo "缺少 --out"; usage; exit 1; }
[ -f "$IMAGE" ] || { echo "找不到内核镜像: $IMAGE"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 内核：TWRP 要 gzip 格式。已经是 gzip 就原样用，否则压一次。
if [ "$(head -c 2 "$IMAGE" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
    cp -f "$IMAGE" "$tmp/kernel"
else
    gzip -9 -n -c "$IMAGE" > "$tmp/kernel"
fi

mkdir -p "$OUT"
cp -f "$tmp/kernel" "$OUT/kernel"

kver="$(zcat -f "$OUT/kernel" | strings -a | grep -m1 'Linux version' || true)"
echo "prebuilt/kernel  : $(stat -c%s "$OUT/kernel") 字节"
echo "  版本串         : ${kver:-未知}"
sha256sum "$OUT/kernel"

if [ "$KERNEL_ONLY" -eq 1 ]; then
    echo "prebuilt/dtb.img : 跳过（--kernel-only）"
    exit 0
fi

# dtb：认两种 magic —— 裸 FDT（d00dfeed）和 Android DTBO 镜像（d7b7ab1e）。
# chopin 的 boot header v2 里那个 "dtb" 字段装的是 DTBO blob，不是裸 FDT；都不是才当成 boot.img 解包。
[ -n "$DTB_SRC" ] || DTB_SRC="$KERNEL_DIR/boot/boot.img"
[ -f "$DTB_SRC" ] || { echo "找不到 dtb 来源: $DTB_SRC"; exit 1; }

magic="$(head -c 4 "$DTB_SRC" | od -An -tx1 | tr -d ' \n')"
if [ "$magic" = "d00dfeed" ] || [ "$magic" = "d7b7ab1e" ]; then
    cp -f "$DTB_SRC" "$tmp/dtb.img"
else
    # 必须解到独立子目录：magiskboot 会在 CWD 里写出 boot.img 自带的 kernel，
    # 跟上面那个 "$tmp/kernel" 撞名，会把刚压好的内核覆盖成原厂那个。
    mkdir -p "$tmp/unpack"
    ( cd "$tmp/unpack" && "$KERNEL_DIR/boot/magiskboot" unpack "$DTB_SRC" >/dev/null ) \
        || { echo "解包失败: $DTB_SRC"; exit 1; }
    [ -s "$tmp/unpack/dtb" ] || { echo "这个 boot.img 里没有 dtb: $DTB_SRC"; exit 1; }
    mv -f "$tmp/unpack/dtb" "$tmp/dtb.img"
fi

cp -f "$tmp/dtb.img" "$OUT/dtb.img"
echo "prebuilt/dtb.img : $(stat -c%s "$OUT/dtb.img") 字节"
sha256sum "$OUT/dtb.img"
