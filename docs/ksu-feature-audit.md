# KSU 管理器功能审计（chopin / Android 13，2026-11-08）

环境

| 项 | 值 |
| --- | --- |
| 设备 | Redmi Note 10 Pro (chopin)，HyperOS `V816.0.22.0.TKTCNXM`，Android 13 `TP1A.220624.014`，`user` 构建 |
| 内核 | `4.14.336-KsPerm`（KSU-Next `v3.4.0-legacy`，引擎 33305，UAPI 4，Manual hook，SUSFS v2.0.0 NON-GKI） |
| 管理器 | KernelSU-Next **v3.4.0 (33294)**（必须 ≤ 内核引擎版本，否则显示 `Kernel update required` 并隐藏「超级用户/模块」页） |
| 元模块 | meta-overlayfs **v1.3.1**（`meta-overlayfs-13100-1.3.1.zip`） |

## 审计结论

| 设置项 | 状态 | 结论 |
| --- | --- | --- |
| 每个应用的「超级用户」开关 | 可用 | 管理器 v3.2.0 写 `app_profile` VER 3，内核要 VER 4 → `profile_valid()` 拒收（`policy/allowlist.c:129`）→ `SET_APP_PROFILE` 返回 `-EINVAL`。换 v3.4.0 管理器后正常，列表徽标 `UMOUNT`→`ROOT`，首页计数 +1 |
| 传统 SU 命令支持 | 可用 | 打开后 `/system/bin/su` 出现，`su -c id` → `uid=0(u:r:ksu:s0)` |
| SU 日志 | 可用 | 打开后写 `/data/adb/ksu/log/sulog-YYYY-MM-DD.log`，内容如 `type=ioctl_grant_root retval=0 uid=10279 comm="libksud.so"` |
| 隐藏 SELinux 修改 | 钩子已装，应用侧未端到端验证 | 开机日志 `ksu_selinux_hide: hooked sel_context_ops->write` / `hooked sel_handle_status_ops->open` / `fake status ready`；开关值可写（1↔0）。真实效果要 untrusted_app 域进程读 `/sys/fs/selinux/status`、`/sys/fs/selinux/context` 才能观察 |
| AVC 日志伪装 | 同上 | 开关值可写（1↔0），内核 `avc_spoof` 钩子在场；效果需在内核 audit 日志里看 |
| 内核处理卸载模块 | 已修好（见下节） | 原版配元模块时**完全无效**：内核 `mount_list` 没人登记。仓库 `tools/ksu-metamount-umount` 补齐后，应用进程看不到模块文件 |
| ADB Root | 有害，勿开 | 打开后 adbd 被反复杀（dmesg `KernelSU: handle_setresuid from 0 to 2000` → `Sending signal 9 to service 'adbd'`），adb 彻底失联，只能到管理器里手动关 |
| SELinux 宽容模式 | 内核补丁后重启保持 | 见 `docs/permissive-persist.md` |
| Restrict shell root to ADB | 内核不支持 | 管理器直接标注「内核不支持此特性」 |
| 模块挂载（模块页） | 需先装元模块 | 未装元模块时 `ksud module install` 成功但重启后不挂载、logcat 无 mount 记录、`ksud module metamodule` 报 `Error: Unsupported`。装 meta-overlayfs v1.3.1 后 `mount | grep KSU` 出现 `KSU on /system type overlay` |
| App Profile 模版 / 备份恢复 / 个性化 | — | 纯用户态功能，未逐项测 |

## 为什么 kernel_umount 配元模块时失效

内核侧的卸载逻辑只认一张表：

- `feature/kernel_umount.c`：`ksu_handle_umount(old_uid, new_uid)` 第一行 `if (!ksu_module_mounted) return 0;`，之后还要 `is_appuid()` / `is_zygote(current_cred())`，最后把 `umount_tw_func()` 排到 `task_work`，遍历 `mount_list` 逐个 `try_umount(entry->umountable, entry->flags)`。
- `runtime/boot_event.c:102 on_module_mounted()` 才会把 `ksu_module_mounted` 置 true；
- `supercall/dispatch.c:602 add_try_umount()`（`KSU_IOCTL_ADD_TRY_UMOUNT`，`0x40004b12`）才会往 `mount_list` 加条目。

也就是说：**登记是用户态的责任**。magic-mount 时代由 ksud 在挂载循环里逐个 `ksud kernel umount add <path>`；而 meta-overlayfs 用自己的二进制把整个分区做成 overlayfs（`KSU on /system type overlay lowerdir=...`），既不 add 也不 notify → 内核里表空、标志 false → 卸载全空转，应用照样看得见模块文件。

手动实证（未装修复模块时）：

```
ksud kernel umount add /system --flags 2   # dmesg: cmd_add_try_umount: /system added!
ksud kernel notify-module-mounted          # dmesg: on_module_mounted!
# 再冷启动 com.android.camera(uid 10146)
# dmesg: handle umount for uid: 10146 / umount_tw_func: unmounting: /system flags: 0x2
# ls /proc/<pid>/root/system/bin/ksu_probe → No such file or directory
# 而 root shell 的 /system/bin/ksu_probe 仍在
```

## 修复：`tools/ksu-metamount-umount`

- `tools/ksu-metamount/01-ksu-umount.sh`：扫描 `/proc/mounts`，凡是 overlay 挂在 `system/system_ext/vendor/product/odm/oem/my_product` 上的分区就 `ksud kernel umount add /<part> --flags 2`，最后 `ksud kernel notify-module-mounted`。
- `tools/ksu-metamount/module.prop` + `customize.sh`：`SKIPMOUNT=true`（自身不参与挂载），只把脚本装到 `/data/adb/post-mount.d/01-ksu-umount.sh`（755）。
- `tools/ksu-metamount-umount.zip`：直接 `ksud module install` 用。
- 时机：ksud 会在元模块 mount 之后执行 `/data/adb/post-mount.d/*.sh`（logcat `ksud::module: exec /data/adb/post-mount.d/01-ksu-umount.sh`）。

实测（冷启动一条龙）：dmesg `[8.836] cmd_add_try_umount: /system added!` + `[8.851] on_module_mounted!` → 应用进程 pid 看不到 `/system/bin/ksu_probe`，root shell 仍能看到。

## 几个坑

- 脚本必须 LF。PowerShell 写出的 CRLF 会让 `exit $?` 变成 `exit: bad number: 0\r`。
- `/proc/mounts` 的格式是 `source mountpoint fstype options`，**没有** `mount` 命令输出里的 `on` / `type` 字样；用 `awk '$2==m && $3=="overlay"'` 判断。
- `adb push` 到 `/data/local/tmp` 时超长文件名会被截断（`ksu-metamount-umount.zi`），用短名再装。
- 重启后 adb 偶尔掉线（Windows 剩 `USB\VID_2717&PID_FF48` 且无子接口），在通知栏把 USB 用途改成「传输文件」即可。

## ADB Root：从死代码到可用

### 现象

`ADB Root` 开关打开后 `adb root` 仍报 `adbd cannot run as root in production builds`，
`adb shell id` 还是 `uid=2000(shell)`；dmesg 里只有
`KernelSU: handle_setresuid from 0 to 2000`，**没有** `escape to root for adb`。

### 根因

`feature/adb_root.c` 的 `ksu_adb_root_handle_execve*` 只有两个调用点：

- `hook/hook_manager.c:358-359` —— 需要 `CONFIG_KPROBES` + `CONFIG_KSU_KPROBES_HOOK`；
- `hook/syscall_table_hook.c:151/174` —— Kconfig 要求 kernel >= 4.17。

本内核是 4.14 + `CONFIG_KSU_MANUAL_HOOK=y` + `# CONFIG_KPROBES is not set`，
两条都不成立，所以这个开关只是翻了一个没人看的 static key，属于死代码。

### 修复

1. `feature/adb_root.c`
   - 把 `do_ksu_adb_root_handle_execve()` 的实现拆成 `adb_root_apply(regs, envp_p)`；
   - 新增 `is_adbd_kernel_path(const char *name)` 与
     `long ksu_adb_root_handle_execve_kargs(const char *path, void *envp_p)`，
     供没有 `pt_regs` 的 manual hook 调用；
   - `adb_root.h` 补原型。
2. `fs/exec.c`：在 `do_execveat_common()` 的 `#ifdef CONFIG_KSU_MANUAL_HOOK`
   分支里，`ksu_handle_execveat(...)` 之后调用
   `ksu_adb_root_handle_execve_kargs(filename->name, &envp.ptr.native)`。

### 三个坑

1. **init 在 execve 前就改了子进程的 SID**。init 对 adbd 调过 `setexeccon()` 之后才
   execve，所以进入 `do_execveat_common()` 时 `is_init(current_cred())` 已经是 false。
   改用 `ppid == 1` 兜底：
   `if (current->pid == 1 || (ppid != 1 && !is_init(current_cred()))) return 0;`
2. **批量读 envp 会整批 fault**。原 `setup_ld_preload()` 一次 `copy_from_user` 读 16 个
   指针，当数组尾部紧邻未映射页时整批失败，dmesg 只留一句 `truncated envp array!`。
   改成逐指针读，fault 即视为数组结束（上限 1024 项，一项都读不到就放弃注入）。
3. **`struct user_arg_ptr` 的字段偏移**。本内核 `CONFIG_COMPAT=y`，结构是
   `{ bool is_compat; union { const char *native; ... } }`，`is_compat` 在偏移 0、
   `ptr.native` 在偏移 8。传 `&envp` 读到的是 `is_compat`（值 0），必须传
   `&envp.ptr.native`。这一条让调试多刷了两次机。

### 验证

```sh
uname -r                                  # 4.14.336-KsAdb
/data/adb/ksud feature set adb_root 1
/data/adb/ksud feature save
adb reboot
adb shell id                              # uid=0(root) ... context=u:r:ksu:s0
adb root                                  # adbd is already running as root
tr '\0' '\n' < /proc/$(pidof adbd)/environ | grep LD_
# LD_PRELOAD=/data/adb/ksu/lib/libadbroot.so
# LD_LIBRARY_PATH=/data/adb/ksu/lib
dmesg | grep -F "escape to root for adb"
```

反向验证：`feature set adb_root 0` + 重启 → `adb shell id` 回到 `uid=2000(shell)`。

### 注意

- 开关的生效点是 **adbd 启动时**，所以要么重启设备、要么重启 adbd；而
  `setprop ctl.stop adbd; setprop ctl.start adbd` 很容易让 adb 变 `offline`
  （adbd 重启老毛病），**推荐直接重启手机**。
- 本 ROM 是 user 版，`adb root` 命令本身仍会被 adbd 以
  "not run as root in production builds" 拒绝；这里做到的是 "adbd 进程本身就是
  root" —— `adb shell` 直接是 root，`adb remount` 之类仍受 user 版与 dm-verity 限制。
