# chopin 内核功能变更记录（2026-10-24 → 2026-11-10）

本文件按**功能线**而不是按提交时间罗列，方便回答「这个内核相对原厂/上游到底改了什么」。
逐条 commit 用 `git log --oneline` 看；每项末尾标注对应提交与验证文档。

基线：Xiaomi chopin（Redmi Note 10 Pro，MT6893）4.14.336，目标是把
Android 13 的原厂内核改到能跑 **Android 17（HyperOS 3）**，同时接入
**KernelSU-Next + SUSFS**。当前 HEAD 内核版本串 `4.14.336-KsExt4`。

---

## 一、Android 17 BPF 网络栈（核心工作，最多提交的一条线）

A17 的 netd / 系统组件依赖一批 4.14 没有的 BPF 能力，缺一个就会在开机早期 abort
（典型现场：`netd1shot` 退出、`cgroup sockopt` 钩子不触发、`sk_storage` 建图失败）。
补的都是「让 A17 的 BPF 程序能通过 verifier 并真正跑起来」的最小集合：

| 能力 | 说明 | 提交 |
| --- | --- | --- |
| ring buffer map | `BPF_MAP_TYPE_RINGBUF` + `bpf_ringbuf_output/reserve/submit/discard`，新内核用它替代 perf buffer | `a3ab0e065` |
| `BPF_F_MMAPABLE` | array map 支持 mmap 给用户态直接读写 | `af3402a86` |
| `bpf_ktime_get_boot_ns` | 真实实现（原来只是占位） | `1283099ed` |
| `probe_read_kernel/user` | 别名到 `bpf_probe_read`，A17 程序按新名字调用 | `50aca5cc2` |
| verifier: PTR_TO_MEM | 支持可变偏移并做边界检查；支持 `BPF_ARSH`；给合成的 `sk_buff` 字段设 `target_size` | `93adb2aad` `972dce015` `00aaa091b` `eb33eda47` |
| `sk_storage` | 真实实现（含 `sk_fullsock` 守卫与 sock_common 修正）；子 socket 不继承 sk_storage | `528fa3b81` `d886a9ea3` `0fb83de5c` |
| cgroup/sock 程序 | 暴露 socket cookie、`sk_storage_get`；支持 cgroup/sock release hook（attach type 34）；`getsockopt`/`setsockopt` 真正触发 cgroup sockopt hook | `8bec71822` `dc856d4f1` `a95fadc33` |
| cgroup/skb 程序 | 允许调用 socket lookup helper；修正 LWT 的 `sk_lookup` 分派 | `74ef52829` `2b100b7e8` |
| defconfig | `arch/arm64/configs/chopin_a17_defconfig`（5677 行）纳入仓库 | `a1a12d3f5` |

细节与调试过程：`docs/android17-bpf-port.md`。

## 二、稳定性与配置

| 改动 | 原因 | 提交 |
| --- | --- | --- |
| `sched/uclamp` 不对已恢复的 free-group refcount 报 WARN | A17 运行中会刷屏 | `0e1d7db7b` |
| `blk_sync_queue` 不再取消未初始化的 `timeout_work` | 关机/卸载块设备时可能踩空 | `b4df15264` |
| 去掉只给 init 用的 `mdio_bus_init`/`xfrm4_protocol_init` 导出 | 模块导出符号不匹配导致加载失败 | `cb87d4827` |
| 只保留 aw8697 触感路径 | 原厂内核带多条 haptic 驱动，A17 参考内核只有 aw8697，多留会在 vibrator HAL 里选错设备 | `4378a90b6` → `docs/a17-vibrator.md` |
| uname 伪装 | 让部分检测看到期望的版本串 | `2b100b7e8` |
| `bpf: forward-declare struct poll_table_struct` | 编译期缺声明 | `f2e0877a4` |

## 三、KernelSU-Next 接入

引擎 `v3.4.0-legacy`（versionCode 33305、UAPI 4、`CONFIG_KSU_MANUAL_HOOK=y`、
SUSFS v2.0.0 NON-GKI）。管理器 versionCode 必须 **≤ 33305**，否则管理器进只读态。

| 改动 | 说明 | 提交 |
| --- | --- | --- |
| 子模块指向 SUSFS 移植 fork | `drivers/kernelsu` → `v3.4.0-legacy` | `d374b8085` `99b3c3721` `f7f674cb6` `7070078ef` |
| **SELinux 宽容模式持久化** | 管理器那个开关只是运行期 `setenforce 0`，重启必回 Enforcing。内核加 `/data/adb/ksu/.permissive` 记录上次观察到的模式，开机 `/data` 就绪后按 flag 恢复；轮询器每 3 秒采样并落盘 | `a49d2ef2f` → `docs/permissive-persist.md` |
| **kernel_umount 配元模块修复** | meta-overlayfs 用 overlayfs 挂整个分区，从不调 `ksud kernel umount add` / `notify-module-mounted`，导致内核 `mount_list` 空 + `ksu_module_mounted` 为假，卸载逻辑全空转。补 `post-mount.d/01-ksu-umount.sh` 登记分区并 notify | `1550a3ef0` → `docs/ksu-feature-audit.md` |
| **ADB Root 在 manual-hook 内核上可用** | 原实现只有 kprobes / ≥4.17 syscall-table 两条调用点，本内核两条都不成立 → 开关是死代码。补 `ksu_adb_root_handle_execve_kargs()` 并在 `fs/exec.c` 的 manual-hook 分支调用，靠 `LD_PRELOAD=libadbroot.so` 让 adbd 以 root 运行 | `a6dcb2aaf` → `docs/ksu-feature-audit.md` |

管理器侧功能审计（哪些开关有效、哪些是内核不支持）见 `docs/ksu-feature-audit.md`。

## 四、关机路径与重启目标

这一条线是踩坑最多的：**「点重启到 Recovery / Bootloader 却回系统」有三个独立原因**，
必须全部解决才稳定。

| 问题 | 根因 | 处置 |
| --- | --- | --- |
| 重启到 Bootloader 回系统 | 一度以为是 BCB 命令写错。曾加过「把 `bootonce-bootloader` 改写成 `boot-fastboot`」的补丁，结果 LK 对 `boot-fastboot` 的语义是**引导内核进 fastboot 模式** = fastbootd，反而把"真 fastboot"降级了 | `b85d5273b` 加、`7393f688f` **revert** |
| 同上 | 真正原因之一：并存的第二个 adb server（`E:\应用\搞机助手\adb.exe` 起 `-L tcp:23973`）独占总线，导致采样看到的是假象 | 无代码改动，记入文档 `f3ed835cf` |
| 重启到 Recovery 回系统 | **关机时内核 panic**：`meta-overlayfs/post-mount.sh` 调 `ksud kernel nuke-ext4-sysfs` → `ext4_unregister_sysfs()` 释放 proc 条目但不清 `sbi->s_proc`；关机 `ext4_put_super()` 再摘一次 → UAF → MTK 看门狗硬复位 → reboot reason 丢失 | `6d8d3d521` **让 `ext4_unregister_sysfs()` 幂等** |

`fs/ext4/sysfs.c` 的修法（关键两行）：

```c
		remove_proc_entry(sb->s_id, ext4_proc_root);
		sbi->s_proc = NULL;              /* 别让第二次再摘一遍 */
	}
	if (sbi->s_kobj.state_in_sysfs)      /* kobject_del 同理只做一次 */
		kobject_del(&sbi->s_kobj);
```

为什么改 ext4 而不是改 KSU：`nuke_ext4_sysfs()` 只拿到 `struct super_block *`，
`s_proc` 是 `ext4_sb_info` 的私有字段；幂等责任放在 ext4 内部，任何"提前摘一次"的
调用者都自动安全，nuke（反检测，藏 `/proc/fs/ext4/loopNN`）可以继续长期启用。

完整证据链（栈、复现表、排查口诀、三种 BCB 串语义）：`docs/boot-recovery-reboot.md`。

另外两个菜单项（Download / EDL）**不是 bug，是平台固件没这功能**，且已用代码证据坐实：

- 命令确实传到了内核：pstore 里 `init: Reboot start, reason: reboot,edl, reboot_target: edl`
  → `ARCH_RESET happen!!!` → `arch_reset: cmd = edl`。
- 卡在 `drivers/watchdog/mediatek/wdk/wd_api.c:659` 的 `arch_reset()`：cmd 白名单只有
  `charger` / `recovery` / `bootloader` / `dm-verity device corrupted` / `kpoc`，`edl` 与
  `download` 落到 `else` → `WD_SW_RESET_BYPASS_PWR_KEY`，等价于一次普通看门狗复位，
  PMIC spare register 里不留标记（`enum rtc_spare_enum` 也没有 DL/EDL 项）。
- LK 侧同样没有：`lk_a` 里 `edl` / `boot-edl` / `boot-download` / `downinit` 全 0，
  22 条 `oem` 命令无一能进；Preloader 里 `bootonce` / `boot-fastboot` / `boot-recovery` 全 0，
  只有 `download keys are pressed` 与 `emergency download mode(timeout: %ds)` —— 只认按键/工具握手。
- 旁证：`svc power reboot download` 之后 `persist.sys.boot.reason` 记成 `reboot,downinit`，
  但 `downinit` 这个字符串在内核、LK、init、framework 里一次都没出现过。

## 五、构建系统（`build.sh`）

原厂脚本只认它自己的打包流程，接官方 stock `boot.img` + Android 17 需要一串修补：

| 改动 | 说明 | 提交 |
| --- | --- | --- |
| 适配官方 stock boot.img | 原 `build.sh` 来自旧包，路径与镜像结构都不对 | `d27dfbc46` |
| **修 ramdisk 重打包** | 解包目录写错 + `$PWD` 漂移导致 fstab 修改静默不生效（打出来的包"看着成功、其实没改"） | `6ee78380d` → `b5efca720` |
| 底包校验 | 解包查 `ro.build.type`/`ro.debuggable`，拒绝不可开机的底包；默认走 A17 defconfig | `62db0e097` `9cc10eff9` `fb854f5ff` |
| 只在 fstab 真变了才重打包 ramdisk | 避免无谓改动导致校验失败 | `3e1a36e4d` |
| KSU 子模块健壮性 | 检测坏 gitlink（原脚本只在 `.git` 缺失时才报错，坏链接会静默通过）、处理 shallow 历史、相对 `build.sh` 定位内核树 | `50c39313e` `24f172dd1` |
| 产物只留最新 | release 目录不再堆积 | `14079dc8b` `ec5fbe778` |
| 其他 | 恢复 `build.sh` 可执行位、忽略 `build_fix_*.log`、把辅助脚本折进 `build.sh` | `7e621f4b9` `4960ad0a9` `6a62d50df` |

## 六、刷机与排查经验（不进代码，但每次都要用）

- **不能 `dd` 写 boot 分区**：`dd` 报成功，回读 `cmp` 报 `WRITE_LOST`，数据根本没落盘。必须 `fastboot flash boot_a`。
- **`adb reboot bootloader` 后立刻起 `fastboot flash`**，它会 `< waiting for any device >` 等着。
- USB 标识：`2717:FF48` = 系统（含 MTP/ADB 子接口）、`2717:FF08` = LK 阶段瞬时、`18D1:D00D` = fastboot 家族、`18D1:4E11` = recovery。
- 判 fastbootd vs LK：`fastboot getvar is-userspace`（`yes` = fastbootd）与 `getvar version-bootloader`（LK 有版本号，fastbootd 报 `unknown`）。
- **设备管理器正常但 `adb devices` 空 → 先查有没有第二个 adb server**（`Get-CimInstance Win32_Process -Filter "Name='adb.exe'"`），别折腾驱动。
- **重启没到预期目标，先翻 `/sys/fs/pstore/`**：`dmesg-ramoops-*` 里有 `Oops#1`/`Panic#2` 就说明关机时内核崩了，reboot reason 必然丢失。`console-ramoops` 会截断到 256KB，完整栈常常只在 `dmesg-ramoops-*`。
- 编译只能用 `build.sh`：菜单 `2` 仅编译、`3` 仅打包（菜单 3 不改 `LOCALVERSION`，版本串保持上次的）。自拼 `make` 会因 `CONFIG_CROSS_COMPILE` 与 kconfig 交互而失败。
- PowerShell 会把 `|`、`"` 当自己的语法：检查脚本一律写成 **LF 结尾**的文件，用 `su -c 'sh /data/local/tmp/x.sh'` 跑；`Out-File -Encoding ASCII` 会写 CRLF 导致 `exit: bad number: 0\r`。

## 七、当前已知限制

| 项 | 状态 |
| --- | --- |
| 重启至 Download / EDL | **平台固件层缺失，内核无法补**。命令能传到内核（pstore：`arch_reset: cmd = edl`），但 `drivers/watchdog/mediatek/wdk/wd_api.c:659 arch_reset()` 的 cmd 白名单只有 `charger`/`recovery`/`bootloader`/`dm-verity device corrupted`/`kpoc`，其余落到 `WD_SW_RESET_BYPASS_PWR_KEY` 普通复位；`enum rtc_spare_enum` 也没有 DL/EDL 项。LK（`lk_a`）里 `edl`/`boot-edl`/`boot-download`/`downinit` 全 0，22 条 `oem` 命令无一能进；Preloader 里 `bootonce`/`boot-fastboot`/`boot-recovery` 全 0，只有 `download keys are pressed` 与 `emergency download mode(timeout: %ds)` —— 只认按键/工具握手。详见 `docs/boot-recovery-reboot.md` 第 8 节 |
| `Restrict shell root to ADB` | 内核缺对应 feature 位，管理器直接标注「内核不支持此特性」 |
| `adb remount` | ROM 是 `user` 构建 + dm-verity，即使 adbd 已是 root 也不可用 |
| 宽容模式下的 selinux_hide | `feature/selinux_hide.c` 在非 enforcing 且非 late-load 时 `skip not enforcing`，挂宽容等于隐藏功能半残 |
| A17 DSU 首屏 | SurfaceFlinger 自我 abort（`sys_ptrace` 被拒导致 crash_dump64 无法产出 tombstone），permissive 救不了，需要补 A17 sepolicy |
