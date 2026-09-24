#!/bin/bash
# 诊断包：续编 Image 并打包（不 mrproper）
set -e
cd /home/xiaone/xiaomi_kernel_chopin

export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export CLANG_TRIPLE=aarch64-linux-gnu-

if [ ! -f out/arch/arm64/include/generated/uapi/asm/types.h ]; then
  echo "缺少 asm/types.h 包装，重新生成..."
  mkdir -p out/arch/arm64/include/generated/uapi/asm
  mkdir -p out/arch/arm64/include/generated/asm
  make -f scripts/Makefile.asm-generic src=uapi/asm obj=out/arch/arm64/include/generated/uapi/asm
  make -f scripts/Makefile.asm-generic src=asm obj=out/arch/arm64/include/generated/asm
fi

if [ ! -f out/.config ]; then
  echo "缺少 .config，生成 defconfig..."
  make O=out CC="ccache clang-13" chopin_defconfig
  make O=out olddefconfig
fi

echo "=== 关键配置 ==="
grep -E 'CONFIG_PANIC_ON_OOPS|CONFIG_PANIC_TIMEOUT|CONFIG_MTK_AEE_IPANIC|CONFIG_LOCALVERSION' out/.config || true

echo "=== 开始编译 Image ==="
make O=out -j"$(nproc)" CC="ccache clang-13" KCFLAGS="-w" Image 2>&1 | tee full_20260924_diag.log | tail -50
rc=${PIPESTATUS[0]}
echo "MAKE_RC=$rc"
if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

echo "=== 打包（DiagBoot，不改 fstab）==="
export ENABLE_EROFS_FSTAB=0
# 直接调用 pack：通过交互菜单选项 3 仅打包，版本名 DiagBoot
printf 'DiagBoot\n3\n' | bash build.sh

echo "=== 完成 ==="
ls -lth release/boot-DiagBoot-*.img release/boot-*-DiagBoot*.img 2>/dev/null || ls -lth release/*.img | head -5
