#!/system/bin/sh
# Register metamodule overlay mounts into the KernelSU kernel umount list so
# that kernel_umount can hide module files from app processes.
# meta-overlayfs mounts whole partitions with overlayfs but never calls
# ksud kernel umount add / notify-module-mounted, so we do it here.
KSUD=/data/adb/ksud
[ -x "$KSUD" ] || exit 0

for p in system system_ext vendor product odm oem my_product; do
    if awk -v m="/$p" '$2==m && $3=="overlay"' /proc/mounts | grep -q .; then
        $KSUD kernel umount add "/$p" --flags 2 >/dev/null 2>&1
    fi
done

$KSUD kernel notify-module-mounted >/dev/null 2>&1
exit 0
