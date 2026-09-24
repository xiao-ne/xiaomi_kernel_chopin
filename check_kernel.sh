#!/bin/bash
# chopin 内核体检脚本
set -u
cd /home/xiaone/xiaomi_kernel_chopin || exit 1

echo "======== 1. 版本与产物 ========"
head -6 Makefile
ls -lh out/arch/arm64/boot/Image 2>/dev/null
ls -lht release/*.img 2>/dev/null | head -6
strings out/arch/arm64/boot/Image 2>/dev/null | grep -m1 "Linux version"
echo

echo "======== 2. 开机关键符号 ========"
for s in start_kernel kernel_init mt_gpt_init __initcall_mt_gpt_init6 mtk_stmr_init do_mounts; do
  line=$(grep -E " ${s}\$" out/System.map 2>/dev/null | head -1)
  if [ -n "$line" ]; then
    echo "OK   $s -> $line"
  else
    echo "MISS $s"
  fi
done
echo

echo "======== 3. 关键 .config ========"
grep -E 'CONFIG_PANIC_ON_OOPS|CONFIG_PANIC_TIMEOUT|CONFIG_BPF_EVENTS|CONFIG_BPF_SYSCALL|CONFIG_KSU|CONFIG_MTK_UNIFY_POWER|CONFIG_MTK_TIMER_SYSTIMER|CONFIG_MTK_TIMER_APXGPT|CONFIG_PSTORE|CONFIG_SECURITY_SELINUX=|CONFIG_CMDLINE=|CONFIG_EROFS_FS=|CONFIG_MACH_MT' out/.config
echo

echo "======== 4. defconfig 对应项 ========"
grep -E 'PANIC_ON_OOPS|PANIC_TIMEOUT|BPF_EVENTS|MTK_UNIFY|MTK_TIMER|EROFS|MACH_MT' arch/arm64/configs/chopin_defconfig || true
echo

echo "======== 5. apxgpt fallback 条件 ========"
sed -n '1165,1207p' drivers/clocksource/mtk_apxgpt.c
echo

echo "======== 6. uname 欺骗 ========"
sed -n '1196,1202p' kernel/sys.c
echo

echo "======== 7. cgroup 修复 ========"
grep -n 'if (!ctx)' kernel/cgroup/cgroup.c | head -8
echo

echo "======== 8. KSU hook ========"
grep -n 'ksu_handle_execveat' fs/exec.c | head -8
grep -n 'ending with' drivers/kernelsu/kernel/feature/sucompat.c | head -4
echo

echo "======== 9. 最近构建日志尾部 ========"
latest_full=$(ls -t full_*.log 2>/dev/null | head -1)
echo "file: $latest_full"
if [ -n "$latest_full" ]; then tail -25 "$latest_full"; fi
echo

echo "======== 10. 最近错误分析 ========"
latest_err=$(ls -t error_detail_*.log 2>/dev/null | head -1)
echo "file: $latest_err"
if [ -n "$latest_err" ]; then
  # 只显示是否是今天的
  stat -c '%y %n' "$latest_err"
  head -50 "$latest_err"
fi
echo

echo "======== 11. git HEAD ========"
git log -3 --oneline
echo

echo "======== 12. KSU 符号(采样) ========"
grep -E 'ksu_handle_execveat|ksu_init' out/System.map 2>/dev/null | head -15
echo

echo "======== 13. CMDLINE ========"
grep CONFIG_CMDLINE out/.config
echo

echo "======== 14. DTS ramoops/pstore ========"
grep -n -i 'ramoops\|pstore' arch/arm64/boot/dts/mediatek/chopin*.dts* arch/arm64/boot/dts/mediatek/mt689*.dts 2>/dev/null | head -30 || echo "(未找到)"
echo

echo "======== DONE ========"
