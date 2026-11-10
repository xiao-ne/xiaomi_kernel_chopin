# 重启菜单（Recovery / Bootloader / Download / EDL）在 chopin 上的真实行为

本文件记录 `4.14.336` chopin（Redmi Note 10 Pro / MT6893，A/B 无 recovery 分区）上，
KernelSU 管理器「重启」菜单各入口的实测行为、MTK LK 的 BCB 语义，以及一次错误的修复尝试。

## 1. 结论速查

| 入口 | 底层动作 | 结果 |
|---|---|---|
| 重启至 Recovery | 管理器先切飞行模式，再 `svc power reboot recovery`；init 写 BCB=`boot-recovery` | 进 recovery（boot ramdisk 里的 `system/bin/recovery`） |
| 重启至 Bootloader | `PowerManager.reboot("bootloader")` → ShutdownThread → `Reboot reason: bootloader`；init 写 BCB=`bootonce-bootloader` | **LK 原生 fastboot**（`is-userspace: no`，`version-bootloader: chopin-b4b182403-...`），15s 到达并长期停留 |
| 重启至 Download | `svc power reboot download` → init 传 `reboot_target: download` → 内核 `arch_reset()` 白名单无此项 → 普通看门狗复位 | 只会普通重启回系统（详见第 8 节） |
| 重启至 EDL | `svc power reboot edl` → 同上，`arch_reset()` 白名单无 `edl` | 只会普通重启回系统（详见第 8 节） |

## 2. 关键证据：BCB 字符串决定 LK 走哪条路

`lk_a`（8 MB，未压缩）里出现的 BCB 命令串只有 `boot-fastboot` 与 `boot-recovery`：

- `boot-recovery` → 引导 recovery。
- `bootonce-bootloader`（Android 标准串，`libbootloader_message.so` 里就这一个）→ LK **自己** 进 fastboot 并停住。
- `boot-fastboot`（MTK 私有串）→ LK **引导内核** 进 fastboot 模式 = **fastbootd**（`is-userspace: yes`）。

实测（管理器点「重启至 Bootloader」，每 2s 采样 USB 与 fastboot 协议）：

```
无补丁内核（4.14.336-KsNoBcb）：
  t=15s → 18D1:D00D  is-userspace: no     ← LK 原生 fastboot
  t=169s 仍然 is-userspace: no            ← 稳定停留

带 BCB 翻译补丁的内核（4.14.336-KsBcb）：
  t=2..30s   2717:FF08                    ← LK 阶段
  t=34..57s  无 USB                        ← LK 交出，开始引导内核
  t=60s →    18D1:D00D  is-userspace: yes  ← fastbootd
```

## 3. 那次错误的尝试（已回退）

曾经加过一个 `kernel/runtime/boot_bcb.c` 轮询器：每秒读 `misc`，把
`bootonce-bootloader` 改写成 `boot-fastboot`，理由是"LK 不认前一个串"。实测证明这个前提是错的：

- 改写确实发生了（写 `bootonce-bootloader` 后 4 秒回读到 `boot-fastboot`）。
- 结果反而把"真 fastboot"降级成"fastbootd"，就是用户看到的「点 bootloader 落在 fastbootd」。

补丁已在子模块中整体回退（`git reset --hard ce8921ee~1`，HEAD 回到 `625159a2`），
`kernel/runtime/boot_bcb.c|h` 与 Kbuild / `core/init.c` / `supercall/supercall.c` 的引用全部移除。

## 4. 复现与验证命令

```bash
# 看当前 fastboot 是谁
fastboot getvar is-userspace      # no = LK 原生；yes = fastbootd
fastboot getvar version-bootloader  # LK 会给 chopin-b4b182403-...

# 手工写 BCB 后普通重启（会进 LK fastboot）
adb shell "su -c 'dd if=/dev/zero of=/dev/block/by-name/misc bs=1 count=64 conv=notrunc'"
adb shell "su -c \"printf 'bootonce-bootloader' | dd of=/dev/block/by-name/misc bs=1 seek=0 conv=notrunc\""
adb reboot

# 回系统
fastboot reboot   # 有时需要连发 2 次
```

## 5. 注意

- 不要用 `dd` 写 `boot_a`：该分区在系统内挂载后被保护，`dd` 会"报告成功但数据丢失"
  （写 1 MB 随机数据后 `cmp` 立刻 `WRITE_LOST`）。刷机只能用 `fastboot flash boot_a`。
- `adb reboot bootloader` 后要立刻起 `fastboot flash`（它会 `< waiting for any device >` 等设备）。
- bootloader 重启那条链现在完全依赖 reboot reason：内核只把 reason 往下传，
  KSU 的 `ksu_handle_sys_reboot()` 对非 KSU magic 立即返回，不参与判定。
## 6. 第 8 轮复核（2026-11-09 晚）：症状未复现，真凶是并存的 adb server

用户回报「刷了 `boot-KsNoBcb` 之后，管理器点重启到 Recovery / Bootloader 都直接回系统」。复核结论是这个症状**没能复现**，且当时环境里有一个独立故障点。

### 6.1 干扰源：搞机助手自带的 adb server 抢占 USB 接口

```
PID 67404  E:\应用\搞机助手\adb.exe        adb -L tcp:23973 fork-server server
PID 70676  F:\...\platform-tools\adb.exe    adb -L tcp:5037 fork-server server
```

现象：Windows 设备管理器里 `USB\VID_2717&PID_FF48&MI_01`（`ADB Interface`）状态 `OK`、驱动 `WINUSB`、无黄色感叹号，但 `adb devices` 永远为空；`adb kill-server/start-server`、`pnputil /scan-devices`、`adb reconnect offline` 全都无效。

处理：`Stop-Process -Id <搞机助手 adb 的 PID>`，再 `adb kill-server && adb start-server`，设备立刻回来。

教训：**设备管理器正常 + adb 看不到设备 = 先查是不是别的 adb server 占着接口**（`Get-CimInstance Win32_Process -Filter "Name='adb.exe'"` 看 `CommandLine` 里的 `-L tcp:<port>`）。别一上来就去折腾驱动。

### 6.2 复测：两条链都正常

| 触发 | misc 预处理 | 采样 | 落点 |
|---|---|---|---|
| `svc power reboot recovery` | 清零 | t=10–16s 无 USB → **t=18s `18D1:4E11`** | recovery |
| `svc power reboot recovery` | 故意写 `bootonce-bootloader` | t=10–16s 无 USB → **t=18s `18D1:4E11`** | recovery（残渣无关） |
| `svc power reboot bootloader` | 清零 | t=12–14s 无 USB → **t=16s `18D1:D00D`** | LK 原生 fastboot |

`fastboot getvar is-userspace` → `no`；`getvar version-bootloader` → `chopin-b4b182403-20230427143113-20231102161415`。

### 6.3 用户亲手点 UI 的证据

清空 logcat 后让用户自己在管理器里点「重启至 Bootloader」，事后从 `/data/local/tmp/lc2.log` 取到：

```
11-09 20:57:49.564 D/PowerManagerService( 1680): Reboot reason:bootloader, calling pid:10034
11-09 20:57:49.565 D/ShutdownThread( 1680): Reboot reason:bootloader
11-09 20:57:51.144 I/ShutdownThread( 1680): Rebooting, reason: bootloader
```

用户确认手机进入了黑底 FASTBOOT。→ 管理器 v3.4.0 的「重启至 Bootloader」在 `KsNoBcb` 内核上**正常**。

### 6.4 结论

- 之前的「都回系统」= 观测时刻 adb 被另一个 server 占住（看不到设备）+ 可能把"没连上"误判成"进了系统"；与内核、BCB 残留、管理器版本都无关。
- `bootonce-bootloader` 残留在 misc 里不影响后续 Recovery 重启（init 会覆写 BCB）。
- 排查重启类问题时的固定动作：先确认只有一个 adb server、再每 2 秒采样 USB（`VID_2717` vs `VID_18D1`）判定落点。
## 7. 第 9 轮（2026-11-09 深夜）：关机时 ext4 sysfs 重复摘除导致内核 panic

### 7.1 现象与现场

用户点管理器「重启至 Recovery」→ 手机重启后回到系统。`/sys/fs/pstore/dmesg-ramoops-0` 抓到了现场（21:11 那次）：

```
[561.798] init: Received sys.powerctl='reboot,recovery' from pid: 1683 (system_server)
[561.805] init: Reboot start, reason: reboot,recovery, reboot_target: recovery
[566.310] Oops#1:
          remove_proc_entry+0x90/0x210
          ext4_unregister_sysfs+0x28/0x6c
          ext4_put_super+0xa4/0x330
          generic_shutdown_super ← kill_block_super ← deactivate_locked_super
          ← deactivate_super ← cleanup_mnt ← __cleanup_mnt
          ← task_work_run ← do_notify_resume ← work_pending
[568.001] wdt_arch_reset: disable pwrap before wdt reset
```

init 已经把重启目标正确设成 recovery，但 6 秒后内核在卸载 ext4 时踩到已释放内存 → panic →
MTK 看门狗硬复位 → reboot reason 丢失 → LK 按普通启动进系统。
**这就是「点 Recovery 回系统」的全部原因**，与 BCB、管理器、reboot reason 传递都无关。

### 7.2 成因链

1. 元模块 `meta-overlayfs` 把 2GB ext4 镜像 loop 挂到 `/data/adb/modules/meta-overlayfs/mnt`（本次是 `/dev/block/loop33`）。
2. 它的 `post-mount.sh` 调 `ksud kernel nuke-ext4-sysfs <mnt>`，内核侧
   `drivers/kernelsu/kernel/runtime/boot_event.c:79 int nuke_ext4_sysfs(const char *mnt)`
   直接 `ext4_unregister_sysfs(sb)` —— 目的是把该 fs 从 `/proc/fs/ext4/<name>` 藏起来（反检测）。
3. `fs/ext4/sysfs.c:434 ext4_unregister_sysfs()` 里的 `remove_proc_entry()` **会释放**这些 proc 条目，
   但 `sbi->s_proc` 指针没有清空。
4. 关机时 `ext4_put_super()`（`fs/ext4/super.c:924`）**再次**调 `ext4_unregister_sysfs()` →
   拿着已释放的 `s_proc` 再 `remove_proc_entry()` → use-after-free → panic。

`kobject_del()` 同样不幂等（第二次会破坏 kset 链表），所以两处都要处理。

### 7.3 为什么「时好时坏」

复现实验（同一颗内核 `4.14.336-KsNoBcb`，nuke 开启）：

| 操作 | 结果 |
|---|---|
| `svc power reboot recovery` | t=18s → `18D1:4E11`（进 recovery，未见 panic） |
| `adb reboot`（nuke 生效中） | `ro.boot.bootreason=reboot`，console 无 panic |
| 用户那次 UI 点击 | panic，回系统 |

所以 100% 复现做不到：这个 UAF 是否崩，取决于释放后的内存有没有被别的东西改写成野指针。
但机制是确定的（一次释放 + 一次必然发生的重复摘除），panicking 的调用栈也把位置钉死在
`ext4_unregister_sysfs`。

### 7.4 修法（内核侧，已落地）

让 `ext4_unregister_sysfs()` 幂等（`fs/ext4/sysfs.c`）：

```c
	if (sbi->s_proc) {
		for (p = proc_files; p->name; p++)
			remove_proc_entry(p->name, sbi->s_proc);
		remove_proc_entry(sb->s_id, ext4_proc_root);
		sbi->s_proc = NULL;          /* 关键：别让第二次再摘一遍 */
	}
	if (sbi->s_kobj.state_in_sysfs)  /* 同理，kobject_del 只做一次 */
		kobject_del(&sbi->s_kobj);
```

为什么改 ext4 而不是改 KSU：`nuke_ext4_sysfs()` 手里只有 `struct super_block *`，
而 `s_proc` 是 `ext4_sb_info` 的私有字段。把幂等责任放在 ext4 内部，
任何"提前摘一次"的调用者（KernelSU 只是其中一个）都自动安全。

### 7.5 现场处置

- 诊断期间先停用了 `post-mount.sh` 里的 `nuke-ext4-sysfs`（原文件备份在 `/data/local/tmp/post-mount.sh.bak`）。
- 关掉 nuke 的代价：`/proc/fs/ext4/loop33` 会重新可见（少一层反检测）。
- 装上这个内核补丁后**没有这个取舍**：nuke 可以继续用，也不会在关机时 panic。

### 7.6 排查口诀

- 重启没到预期目标时，先翻 `/sys/fs/pstore/`：`dmesg-ramoops-*` 里出现 `Oops#1` / `Panic#2`
  就说明**关机过程中内核崩了**，此时 reboot reason 必然丢失，LK 只会普通启动。
- `console-ramoops` 被截断到 256KB，panic 的完整调用栈常常**只落在** `dmesg-ramoops-*`，
  两处都要看。

## 8. 第 10 轮（2026-11-10）：Download / EDL 点了只回系统，根因在内核重启白名单

### 8.1 实测（每 2 秒采样 USB VID/PID）

| 命令 | USB 轨迹 | 结果 |
| --- | --- | --- |
| `svc power reboot download` | `2717:FF48` → 无 USB（关机）→ `2717:FF08`（LK 阶段）→ `2717:FF48` | 回系统 |
| `svc power reboot edl` | `2717:FF48` → 无 USB → `2717:FF08` → `2717:FF48` | 回系统 |

全程没有出现 `0E8D`（MTK Preloader / BROM 的 USB ID），`misc` 始终保持 32 字节全零
（`dd if=/dev/block/by-name/misc bs=32 count=1 | od -A x -t x1`）。

### 8.2 命令确实传到了内核，卡在 `arch_reset()` 的白名单

`/sys/fs/pstore/console-ramoops` 原文（`svc power reboot edl` 那次）：

```
init: Received sys.powerctl='reboot,edl' from pid: 1684 (system_server)
init: Reboot start, reason: reboot,edl, reboot_target: edl
ARCH_RESET happen!!!
arch_reset: cmd = edl
wdt_arch_reset: compatible node found: toprgu
wdt_arch_reset: disable pwrap before wdt reset
```

`drivers/watchdog/mediatek/wdk/wd_api.c:659` 的 `arch_reset(char mode, const char *cmd)`
只认四条 cmd：

```c
if (cmd && !strcmp(cmd, "charger"))                        { /* nothing */ }
else if (cmd && !strcmp(cmd, "recovery"))                  { rtc_mark_recovery(); }
else if (cmd && !strcmp(cmd, "bootloader"))                { rtc_mark_fast(); }
else if (cmd && !strcmp(cmd, "dm-verity device corrupted")) { ... }
else if (cmd && !strcmp(cmd, "kpoc"))                      { rtc_mark_kpoc(); }
else                                                        { reboot = WD_SW_RESET_BYPASS_PWR_KEY; }
```

`"edl"` / `"download"` 都不在表里 → 落到 `else` → 退化成一次普通看门狗复位，
PMIC 的 spare register 里不留任何标记，LK 只能当普通开机处理。

### 8.3 为什么 `recovery` / `bootloader` 能成，这两个不能

差别就在这张表上：`bootloader` 走 `rtc_mark_fast()`（`drivers/mfd/mt6358-misc.c:717`），
把 `RTC_FAST_BOOT` spare register 置 1；`recovery` 走 `rtc_mark_recovery()` 置
`RTC_FAC_RESET`。LK 上电读这两个标记才决定进 fastboot / recovery。
`edl`、`download` 既没有对应分支，spare register 枚举里也没有 DL/EDL 项
（`enum rtc_spare_enum`：FGSOC / ANDROID / FAC_RESET / BYPASS_PWR / PWRON_TIME /
FAST_BOOT / KPOC / DEBUG / PWRON_AL / UART / AUTOBOOT / PWRON_LOGO / 32K_LESS / LP_DET /
FFU_FLAG / FG_INIT）。

### 8.4 LK 与 Preloader 侧同样没有入口（不是内核能补的）

从设备 dump 出来的 `lk_a`（8388608 字节，未压缩）：

- `edl` 出现 **0 次**；`boot-edl` 0；`boot-download` 0；`downinit` 0；`bootonce` 0。
- 认的重启原因只有：`Reason: vol down`、`Reason: reboot bootloader`、`Reason: boot menu`、
  `Reason: detect META Mode`、`Reason: unknown`。
- BCB 命令串只有 `boot-fastboot`（偏移 685732）与 `boot-recovery`（偏移 685816）。
- 22 条 `oem` 命令（`oem printk` / `lkmsg` / `lpmsg` / `cdms` / `dump_pllk_log` / `off` / `key` /
  `lks` / `unlock` / `lock` / `get_socid` / `fbreason` / `scp_status` / `scp_log_thru_ap_uart` /
  `usb` / `mrdump` / `mrdump_chkimg` / `get_token` / `ultraflash` / `ultraflash_en` / `poweroff`）
  里没有一条能进 Download / EDL。

`preloader_chopin.bin`（453580 字节）：

- `bootonce` / `boot-fastboot` / `boot-recovery` 全 0 —— Preloader **根本不看 misc**。
- 但有两条关键串：`download keys are pressed`、`%s emergency download mode(timeout: %ds)`。
- 说明这两个模式只由**按键 / 工具握手**触发，与 misc、BCB、reboot reason 无关。

HyperOS4（A17）的 `images/lk.img` 对比结果相同：`boot-edl` / `boot-download` / `downinit` 全 0。

### 8.5 结论

- Download / EDL 在 chopin 上是**平台固件层面的缺失**（Preloader / LK 都是闭源二进制），
  系统侧和内核侧都无法补。
- 管理器里这两项是上游通用菜单，实现是 `svc power reboot <reason>`，在固件支持该 reason 的
  机型上才有意义。
- 旁证：`svc power reboot download` 之后 `persist.sys.boot.reason` 记成 `reboot,downinit`
  （MIUI 管 Download 模式叫 downinit），但 `downinit` 这个字符串在内核、LK、init、framework
  里**一次都没出现过**——名字有，实现没有。

### 8.6 真要进这两个模式只能物理操作

- Download 模式：关机 → 同时按住音量 + 与音量 - → 插 USB，触发 Preloader 的
  `download keys are pressed`，等 DA 握手（`FlashROM/` 里的 `MTK_AllInOne_DA.bin` +
  `SP_Download_tool`）。
- EDL：同类按键组合走 `emergency download mode`（带 timeout），或短接测试点。
- 风险提示：真进了 EDL 只能靠 SP Flash Tool 出来，测试时建议先只试 Download 模式。

## 9. 第 11 轮（2026-11-10 晚）：把 Download / EDL 重定向到 LK fastboot（已落地并验证）

第 10 轮定位到 `arch_reset()` 的白名单是根因之后，用户选择了「改内核，让这两个入口落到已验证可用的
LK fastboot」。改动只有一处，不碰 KSU、不写 BCB。

### 9.1 改动

`drivers/watchdog/mediatek/wdk/wd_api.c` 里 `void arch_reset(char mode, const char *cmd)`
的 cmd 分派表，在 `bootloader` 分支之后新增一支：

```c
} else if (cmd && (!strcmp(cmd, "download") || !strcmp(cmd, "edl") ||
                   !strcmp(cmd, "downinit"))) {
        pr_info("%s: %s has no firmware entry, booting LK fastboot instead\n",
                __func__, cmd);
        rtc_mark_fast();
}
```

三个 target 名都收：`edl` 与 `download` 是管理器菜单直接传的，`downinit` 是 MIUI 在
`persist.sys.boot.reason` 里记录的别名，三个走同一支。

`rtc_mark_fast()`（`drivers/mfd/mt6358-misc.c:717`）写 PMIC 的 `RTC_FAST_BOOT` spare 位，
和 `reboot bootloader` 完全是同一条路——所以落点必然是同一个界面，不需要新的验证前提。

### 9.2 为什么不是写 BCB

一开始想复用第 6 轮那版「改写 misc 里的 BCB」，但静态取证否掉了：`lk_a` 里 `bootonce`
搜索 0 次命中，也就是 LK **不认** Android 标准的 `bootonce-bootloader`（这也解释了为什么
misc 里残留该串时设备照样进 recovery / 普通系统）。真正决定 LK 停不停在 fastboot 的是
PMIC 的 `RTC_FAST_BOOT` 位，不是 misc。所以最终只改 `arch_reset()`。

### 9.3 实测（kernel `4.14.336-KsEdl`，镜像 `boot-KsEdl-20261110_183333.img`）

| 入口 | USB 轨迹 | 落点 | 结论 |
|---|---|---|---|
| `svc power reboot edl` | `2717:FF48` → 无 → t=14s `18D1:D00D` 持续 | `is-userspace: no` | ✅ LK fastboot |
| `svc power reboot download` | `2717:FF48` → 无 → t=14s `18D1:D00D` 持续 | `is-userspace: no` | ✅ LK fastboot |
| `svc power reboot bootloader` | `2717:FF08` → `18D1:D00D` t=14s | `is-userspace: no` | ✅ 未受影响 |
| `svc power reboot recovery` | `2717:FF48` → 无 → t=18s `18D1:4E11` | recovery | ✅ 未受影响 |
| 普通 `adb reboot` | 正常 | `ro.boot.bootreason=reboot` | ✅ 未受影响 |

两次 Download / EDL 测试前都先把 misc 前 32 字节清零，排除残留干扰；两次都稳定停在
`18D1:D00D` 超过 40 秒，`fastboot devices` 可见，`version-bootloader` 为
`chopin-b4b182403-20230427143113-20231102161415`（LK 原生，非 fastbootd）。

`dmesg` 直证这次也没抓到：MTK 看门狗复位前 dmesg 来不及落盘（`dmesg -w > 文件` 只留下
`init: Received sys.powerctl='reboot,recovery'` 之后就断了）。行为证据是充分且可重复的，
但"是我们改了 `arch_reset()` 才这样"这一点仍属行为推断——如果需要直证，可以在
`rtc_mark_fast()` 之后加一次 `printk` 到 pmsg，或把日志写进 `pstore`。
