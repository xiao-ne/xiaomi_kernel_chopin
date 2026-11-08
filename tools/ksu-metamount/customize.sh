#!/system/bin/sh
# This module only installs a post-mount hook; it never mounts anything itself.
SKIPMOUNT=true
mkdir -p /data/adb/post-mount.d
cp -f "$MODPATH/01-ksu-umount.sh" /data/adb/post-mount.d/01-ksu-umount.sh
chmod 755 /data/adb/post-mount.d/01-ksu-umount.sh
ui_print "- installed /data/adb/post-mount.d/01-ksu-umount.sh"
