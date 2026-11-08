# SELinux 宽容模式持久化（内核侧）+ 功能审计

## 背景

管理器 KernelSU-Next v3.4.0 设置页里的「SELinux 宽容模式」开关，实测**只在当次生效**：
点开 → `getenforce` 立刻变 `Permissive`，再点 → 变回 `Enforcing`。
但重启后一定回到 `Enforcing`，开关也复位。

原因有三层：

1. 管理器侧只是一次性执行 `setenforce 0`（APK dex 里有 `setenforce`、`getenforce`、
   `/sys/fs/selinux/enforce`、`Permissive` 等字符串），而 `dumpsys package com.rifsxd.ksunext`
   的 Receiver 表只有 `androidx.profileinstaller.ProfileInstallReceiver`，**没有 BOOT_COMPLETED 接收器**
   → 重启没有恢复动作。
2. 内核侧没有对应 feature：`drivers/kernelsu/kernel/uapi/feature.h` 只有
   `KSU_FEATURE_SU_COMPAT=0 / KERNEL_UMOUNT=1 / SULOG=2 / ADB_ROOT=3 / SELINUX_HIDE=4 / AVC_SPOOF=10003`。
3. `kernel/core/init.c:169-170` 只在 late-load 分支做单向 `setenforce(true)`（"Permissive SELinux, enforcing"），
   内建（builtin）模式完全没有触点。

## 方案：内核侧延时 worker

新增 `drivers/kernelsu/kernel/selinux/permissive.c` / `permissive.h`：

- `KSU_PERMISSIVE_FLAG "/data/adb/ksu/.permissive"`，文件内容就是"上次看到的 enforcing 值"：
  - `'0'` = 上次是宽容 → 开机 /data 就绪后恢复 `setenforce(false)`
  - `'1'` = 上次就是 enforcing → 什么也不做（开机默认就是 enforcing）
- `ksu_permissive_tick()`（delayed_work）：
  - 启动阶段每 1s 检查一次 `/data/adb` 是否可 `kern_path(..., LOOKUP_DIRECTORY, ...)`，
    最长 `KSU_PERMISSIVE_BOOT_TRIES=200` 次；就绪后读 flag，`'0'` 就 `setenforce(false)`，
    读不到就跳过（`/data never showed up, skip restore`）；
  - 之后每 `KSU_PERMISSIVE_POLL_MS=3000` 采样一次 `getenforce()`，与上次值不同就把新值写回 flag
    （`O_WRONLY|O_CREAT|O_TRUNC`，0600，用 `override_creds(ksu_cred)` 才能在 builtin 模式写 /data）。
- 初始化点：`kernel/core/init.c` 在 `ksu_app_profile_init()` 之后调用 `ksu_permissive_persist_init()`；
  `kernel/Kbuild` 增加 `kernelsu-objs += selinux/permissive.o`。

## 验证（真机，boot_a）

镜像：`release/boot-KsPerm-20261108_090406.img`（内核串 `4.14.336-KsPerm`），
`fastboot flash boot_a` 刷入（**boot 分区不能 dd 写**，见下）。

```
$ su -c 'dmesg | grep -F "KernelSU: permissive"'
[    1.748877] KernelSU: permissive: persist worker started, enforcing=0
[    7.850350] KernelSU: permissive: boot restore done, enforcing=1
```

宽容 → 记录 flag：

```
$ su -c 'setenforce 0; sleep 5; getenforce; cat /data/adb/ksu/.permissive'
Permissive
0
[   90.854486] KernelSU: permissive: mode changed to permissive, persisting
```

重启后自动恢复：

```
$ getenforce
Permissive
$ su -c 'dmesg | grep -F "KernelSU: permissive"'
[    7.879994] KernelSU: permissive: restoring permissive mode
[    7.880000] KernelSU: permissive: boot restore done, enforcing=0
```

反向（关掉开关）也要保持：

```
$ su -c 'setenforce 1'          # 或管理器里把开关关掉
$ cat /data/adb/ksu/.permissive
1
$ adb reboot && getenforce
Enforcing
[    7.884068] KernelSU: permissive: stored mode is enforcing
```

## 功能审计（管理器 v3.4.0 + 本内核）

| 功能 | 内核 feature | 结论 |
| --- | --- | --- |
| 传统 SU 命令支持 | su_compat (0) | 可用：开启后 `/system/bin/su` 出现，`su -c id` → `uid=0(root) context=u:r:ksu:s0` |
| 内核处理卸载模块 | kernel_umount (1) | 开关能写入内核（`ksud feature get` 跟随变化），但需要真模块才能验证卸载行为 |
| SU 日志 | sulog (2) | 可用：开启后 `/data/adb/ksu/log/sulog-YYYY-MM-DD.log` 落盘，含 `type=ioctl_grant_root uid=...` |
| ADB Root | adb_root (3) | **有害**：开启后 adbd 被 LD_PRELOAD 注入，KSU 的 setresuid hook 又把 adbd 降回 2000（`handle_setresuid from 0 to 2000`），adbd 反复被杀，adb 完全失联；必须在管理器里手动关掉才能恢复 |
| 隐藏 SELinux 修改 | selinux_hide (4) | 开关生效（值跟随）；宽容模式下内核会跳过（`selinux_hide: skip not enforcing`） |
| AVC 日志伪装 | avc_spoof (10003) | 开关生效（值跟随） |
| SELinux 宽容模式 | 无 feature | 当次生效但重启失效 → 由本次内核补丁补上持久化 |
| 模块挂载 | — | 本版 ksud 的挂载依赖元模块（metamodule）；未安装元模块时模块装了也不挂载（`/system/bin/ksu_probe` 不存在、`mount | grep ksu` 为空、logcat 里没有任何 mount 记录），`ksud module metamodule` 报 `Error: Unsupported` |

另外两个坑（不是这次改的，但踩了要记住）：

- **boot 分区不能用 dd 写**：`dd of=/dev/block/by-name/boot_a` 报告成功但数据丢失
  （写完立刻回读 `cmp` 报 `WRITE_LOST`，整盘 sha256 还是旧的）。只能用 fastboot。
- **管理器版本必须 ≤ 内核**：内核是 v3.4.0-legacy（app_profile VER 4），管理器 v3.2.0 写的是 VER 3，
  `profile_valid()` 直接 `Unsupported profile version: 3` → `ksu_set_app_profile` 返回 EINVAL →
  「每个应用的超级用户开关点了没反应」。装 v3.4.0 (33294) 管理器即恢复；v3.4.2 (33355) 版本高于内核
  会显示 `Kernel update required` 并进入只读态（超级用户/模块 tab 消失）。
