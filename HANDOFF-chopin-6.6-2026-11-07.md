# chopin 内核 —— 会话交接（第 2 代，2026-11-07 19:05）

## 先读这个：怎么继续

在 `E:\项目\内核` 新开对话，第一句说「读 HANDOFF-chopin-6.6-2026-11-07.md 继续」。
**旧会话 `session-40db0b62-7157-4978-9d4c-45374a4243eb`（标题「进入WSL小米内核源码」）已经报废，绝对不要再往里发消息。**

### 旧会话为什么报废
不是超上下文，是 **billion-context 折叠边界把一对工具调用切开了**：
`compress` 调用 `call_00_vthfeykb3uch7gxn298datv4`（seq 20928）与其结果（seq 20930）都在日志里配对完整，
但 bili 重渲染出去的 body 里 `tool_use` 后面没紧跟 `tool_result`（报错点 `messages.76`），
Anthropic 线协议要求 result 紧跟 use 的下一条 → 上游恒 400，且每轮重渲染都是同一个坏形状，永远好不了。

最后一次用户输入两条（这两条**没有**被回答，是本次接着做的）：
1. 报错 `build.sh: line 363: cd: _rd_fix82131: No such file or directory` …
2. 报错同上 + `重新修改并提交`

---

## 本次（第 2 代会话第 1 轮）做了什么 —— 已完成

上一轮那次「修复」**根本没修好**，只是语法过了、日志看着像成功。本鱼这次重查了两只虫子：

### 虫子 1：解包去错目录（静默失效，最危险）
```bash
mkdir -p "$rd_tmp"
cpio -idm < "$PWD/ramdisk.cpio"      # ← 没有 cd 进 $rd_tmp
```
ramdisk 内容全解到 `boot/tmp_$$` 根目录，而后面所有检查都去
`$rd_tmp/first_stage_ramdisk/` 里找 → 全部空转。
**后果不是报错，而是日志照样打印「fstab 修复完成」「已补 GSI AVB 公钥」，但产物里 erofs 行和公钥根本不存在。**
（现场证据：`boot/tmp_136190/_rd_fix136190/` 是空目录，而 `boot/tmp_136190/` 里躺着 `dcb/first_stage_ramdisk/…`）

### 虫子 2：`$PWD` 漂移 → 重压成空包
```bash
( cd "$rd_tmp" && cpio -it --quiet < "$PWD/ramdisk.cpio" > "$_names" )
```
子 shell 里先 `cd "$rd_tmp"`，此刻 `$PWD` 已经是临时目录，`"$PWD/ramdisk.cpio"` 不存在
→ `_names` 空 → `cpio -H newc -o` 吐出一个 **512 字节的空 cpio** → `mv` 落空 → `abort`。
现场证据：`tmp_136190/_rd_fix136190/ramdisk.cpio.new` 只有 512 字节（就是个空 newc 头）。

### 修法（commit `6ee78380d`）
- 解包显式在 `$rd_tmp` 内执行：`( cd "$rd_tmp" && cpio -idm --quiet --no-absolute-filenames < "$rd_cpio" )`
- 在 `cd` 之前把路径固化成 `rd_cpio="$PWD/ramdisk.cpio"`，读取列表 / 重压输出 / `mv` 全走这个绝对路径
- 重压产物加 `[ -s "$rd_cpio.new" ]` 非空校验，宁可报错也不产出空 ramdisk

### 验证（真跑，不是 `bash -n`）
`printf 'X\n3\n' | ./build.sh`（选项 3 = 仅打包，底包用原厂 user `boot/boot.img`）rc=0，
产出 `release/boot-X-<ts>.img`；**重新解包该产物复验**：
- `first_stage_ramdisk/fstab.emmc` / `fstab.mt6893` 的 system/vendor/product/mi_ext(+system_ext) 均有 `erofs` 行，且都在对应 `ext4` 行**之前**
- `first_stage_ramdisk/avb/` 下 `q-gsi.avbpubkey` / `r-gsi.avbpubkey` / `s-gsi.avbpubkey` 三把齐全
- cmdline 追加了 `androidboot.selinux=enforcing`（原 `bootopt=64S3,32N2,64N2 buildvariant=user` 保留）
- ramdisk 条目 921 → 925（+4 = 3 把公钥 + avb 目录）

### 文档
`docs/boot-diagnosis.md` 末尾新增一节，写了症状原文、两只虫子、修法、复验命令
（commit `b5efca720`）。**教训也写进去了**：这类 shell 补丁只有重跑并解包复验产物才算验证。

### 收尾状态
- 4.14 仓库 `~/xiaomi_kernel_chopin`，分支 `backport-4.14.336-A17`，**工作区干净**
- HEAD = `b5efca720`（docs），其下 `6ee78380d`（build.sh 修复）、`d27dfbc46`（A17 底包适配）
- 清掉了 `boot/` 下 8 个历史 `tmp_*` 残留目录；测试产物包已删，`release/` 只剩 `boot-Clang13.img`
- **注意：本仓库没有配置 git remote**（`git config --list | grep remote` 为空，`.git/config` 里只有 kernelsu 子模块 URL）。旧交接文档里写的「push 成功 / 远端复核 sha」**是假的**，别再信。

---

## 仍是待办（本次没动）

1. **A17 实测**：STOCK ramdisk 包能否开机、pstore 是否有日志 —— 一直等用户实机测。现在 build.sh 打包链路已经修好，可以先出一个正式包放 `F:\刷机\boot\测试\`。
2. 设备侧 adb 当前**不在线**（`which adb` 空，`adb devices` 无输出）。用户插线后再走：刷包 → 失败则回刷 V02 → `adb shell su -c` 读 `/proc/last_kmsg` 和 `/sys/fs/pstore/`。
3. BPF 特性级 helper 仍未补（非开机必需）：126 `seq_printf`、131/132/133 `ringbuf_reserve/submit/discard`（要 `PTR_TO_MEM` verifier 支持）、134 `ringbuf_query`、158 `get_current_task_btf`、182。
4. 6.6 主线那边（`~/linux-6.6.160`，分支 `master`）有自己的进度，与 4.14 这条线**分开**：
   最后一次提交 `77d09df8e chopin: mark the initcall levels and stop touching initdata after free_initmem`（2026-10-31），
   工作区里 `init/chopin66_mark.c` 有未提交改动（多写 4 个物理地址槽提高命中率）。
   它的进度记录在 `docs/linux66-chopin-plan.md`（轮次 3～8）。

---

## 关键事实（别被旧文档带偏）

- 机型：**chopin = 红米 Note 10 Pro（M2104K10AC，MT6891Z / 天玑1100）**，不是 ares（K40 Gaming / MT6893）。板上 `ro.board.platform=mt6893`，DTS model `MT6891Z/CZA`，`k6891v1_64` 与 `k6893v1_64` 共用平台代码。
- 构建用 `chopin_defconfig`（原 `chopin_a17_defconfig` 已合并进来，现在只有这一份；早先那份
  `chopin_defconfig` 缺 28+ MTK 驱动项，会卡早期 init 且无日志）。
- A17 测试走 DSU：主系统 Android 13，**绝不能刷 A17-ramdisk 包到 A13 系统**（第一屏 bootloop）；只刷 stock-ramdisk 包。
- pstore：preloader 预留 ramoops 并传 `ramoops.mem_address=0x48090000 mem_size=0xe0000 pmsg_size=0x10000 console_size=0x40000`，内核**不能覆盖**这些参数（重复参数后写的赢 → probe 失败）。
- 打补丁/跑脚本的姿势：PowerShell 会吃掉管道与引号 → 写 bash 脚本到 `/mnt/c/Users/xiaone/AppData/Local/Temp/dsh_*.sh`，再 `wsl -d Ubuntu-24.04 -e bash <script>` 执行。
- `wsl -e bash` 每次都会往 stderr 吐一段 `localhost 代理不支持` 的告警（中文乱码），**不影响执行**，忽略即可。

---

## 第 3 轮（2026-11-08）：管理器开关修好 + 宽容模式持久化 + 功能审计

### 起点：管理器的「每个应用超级用户」开关点不动
- 设备实测：管理器 KernelSU-Next **v3.2.0 (33129)**，内核 KSU 引擎 **v3.4.0-legacy (33305)**。
- 根因：`uapi/app_profile.h` 的 `KSU_APP_PROFILE_VER` 从 3 改成 4，
  `policy/allowlist.c:129 profile_valid()` 里 `if (profile->version != KSU_APP_PROFILE_VER) return false`
  → `ksu_set_app_profile` 返回 `-EINVAL` → 管理器 toast「更新 X 的 App Profile 失败」。
  GET_INFO 是 `always_allow`，所以界面能开、版本能显示，但所有写操作全废。
- 修法：装 **v3.4.0 (33294)** 管理器（`adb install -r -d`，因为比已装的 33355 低版本）。
  v3.4.2 (33355) 高于内核会显示 `Kernel update required` 并隐藏超级用户/模块 tab。
- 顺带：把设置里的「传统 SU 命令支持」打开后 `/system/bin/su` 出现，
  `su -c id` → `uid=0(root) context=u:r:ksu:s0`，adb 侧有 root 了。

### 主线：SELinux 宽容模式开关重启就失效 → 内核侧补持久化
- 那个开关只是一次性 `setenforce 0`，APK 无 BOOT_COMPLETED 接收器，内核也没有对应 feature。
- 新增 `drivers/kernelsu/kernel/selinux/permissive.c`：flag 文件 `/data/adb/ksu/.permissive`
  记录上次看到的 enforcing 值（`'0'`=宽容 / `'1'`=enforcing），开机等 `/data` 就绪后按 flag 恢复，
  之后每 3s 采样 `getenforce()`，变了就写回。`Kbuild` 加对象，`core/init.c` 加 `ksu_permissive_persist_init()`。
- 真机验证两种方向都过：
  - flag `'0'` → 重启 → `KernelSU: permissive: restoring permissive mode` → `getenforce`=Permissive
  - flag `'1'` → 重启 → `KernelSU: permissive: stored mode is enforcing` → 保持 Enforcing
- 提交：子模块 `8a901c3e`、父仓库 `a49d2ef2f`（带 `docs/permissive-persist.md`）。

### 踩到/测出的坑
- **boot 分区不能 dd 写**：`dd of=/dev/block/by-name/boot_a` 报成功但数据丢了
  （写完回读 `cmp` 报 `WRITE_LOST`，整盘 sha256 还是旧的）。只能 `fastboot flash boot_a`。
- **ADB Root 开关有害**：打开后 adbd 被 LD_PRELOAD 注入，KSU 的 setresuid hook 又把它降回 2000
  （dmesg `KernelSU: handle_setresuid from 0 to 2000`），adbd 反复被杀 → adb 完全失联，
  必须手动到管理器里关掉才恢复。已用 `ksud feature set adb_root 0` 关掉。
- **模块挂载依赖元模块**：装了测试模块（`/data/adb/modules/ksu-test-probe`）重启后
  `/system/bin/ksu_probe` 不存在、`mount | grep ksu` 空、logcat 无任何 mount 记录，
  `ksud module metamodule` 报 `Error: Unsupported` → 本版 ksud 挂载走 metamodule，未装元模块时不挂载。
- 重启后 adb 有时会掉（Windows 只剩 `USB\VID_2717&PID_FF48` 无子接口），
  让用户在通知栏把 USB 改成「传输文件」即可恢复。

## 第 4 轮（2026-11-08）：模块挂载救活 + kernel_umount 修复

### 模块挂载：必须先装元模块
- 现象：本版 ksud 的挂载走 metamodule，没装元模块时 `ksud module install` 成功但重启后
  模块文件不存在、logcat 无 mount 记录、`ksud module metamodule` 报 `Error: Unsupported`。
- 装 **meta-overlayfs v1.3.1**（`meta-overlayfs-13100-1.3.1.zip`）后重启，
  `mount | grep KSU` 出现 `KSU on /system type overlay`，探针模块 `/system/bin/ksu_probe` 可见，
  `ksud module list` 里 `"mount": "true"`。
- 顺序坑：元模块刚装完必须先重启一次，否则再装别的模块会被 `Metamodule installation blocked` 拦下。

### kernel_umount（设置里的「内核处理卸载模块」）原本无效
- 根因：内核只认 `mount_list`，条目只能由 `KSU_IOCTL_ADD_TRY_UMOUNT`（`supercall/dispatch.c:602`）
  写入，`ksu_module_mounted` 只能由 `on_module_mounted()` 置位；meta-overlayfs 整分区 overlay
  挂载，既不 add 也不 notify → `ksu_handle_umount()` 第一行就 return。
- 修法：仓库 `tools/ksu-metamount-umount`（模块 + `tools/ksu-metamount/01-ksu-umount.sh`），
  customize.sh 把脚本装到 `/data/adb/post-mount.d/`，开机扫 `/proc/mounts` 里的 overlay 分区
  逐个 `ksud kernel umount add /<part> --flags 2` 并 `notify-module-mounted`。
- 实测：冷启动后应用进程 `/proc/<pid>/root/system/bin/ksu_probe` 不存在，root shell 仍可见。

### 其余开关审计
- 可用：传统 SU 命令、SU 日志、SELinux 宽容模式（内核补丁后重启保持）。
- 钩子已装但应用侧未端到端验证：隐藏 SELinux 修改、AVC 日志伪装。
- 有害：ADB Root（adbd 被反复杀，adb 失联）。
- 内核不支持：Restrict shell root to ADB。
- 详见 `docs/ksu-feature-audit.md`。

## 第 5 轮（2026-11-08）：ADB Root 打通

### 现象
`ADB Root` 开关无任何效果：`adb root` 报 `adbd cannot run as root in production builds`，
`adb shell id` 仍是 `uid=2000(shell)`；dmesg 只有 `KernelSU: handle_setresuid from 0 to 2000`，
没有 `escape to root for adb`。

### 根因
`feature/adb_root.c` 的 handler 只有两个调用点：
`hook/hook_manager.c:358-359`（需 `CONFIG_KPROBES` + `CONFIG_KSU_KPROBES_HOOK`）与
`hook/syscall_table_hook.c:151/174`（Kconfig 要求 kernel >= 4.17）。
本内核 4.14 + `CONFIG_KSU_MANUAL_HOOK=y` + `# CONFIG_KPROBES is not set`，两条都不成立
→ 开关只翻了一个没人看的 static key，是死代码。

### 修复（已提交）
- 子模块 `625159a2 feat(adb_root): support manual-hook kernels without kprobes`
  - 拆出 `adb_root_apply(regs, envp_p)`；新增 `is_adbd_kernel_path()` 与
    `ksu_adb_root_handle_execve_kargs(const char *path, void *envp_p)`；`adb_root.h` 补原型。
- 父仓库 `a6dcb2aaf ksu: make ADB Root work with the manual exec hook`
  - `fs/exec.c` 的 `#ifdef CONFIG_KSU_MANUAL_HOOK` 分支里，`ksu_handle_execveat(...)` 之后调用
    `ksu_adb_root_handle_execve_kargs(filename->name, &envp.ptr.native)`。

### 三个坑（都记进 docs/ksu-feature-audit.md）
1. init 在 execve 前就 `setexeccon()` 改了子进程 SID → `is_init(current_cred())` 已是 false，
   必须用 `ppid == 1` 兜底。
2. `setup_ld_preload()` 原来一次 `copy_from_user` 读 16 个 envp 指针，数组尾部紧邻未映射页
   时整批失败（`truncated envp array!`）→ 改成逐指针读，fault 视为数组结束（上限 1024）。
3. 本内核 `CONFIG_COMPAT=y`，`struct user_arg_ptr { bool is_compat; union { ... } ptr; }`，
   必须传 `&envp.ptr.native`（偏移 8），传 `&envp` 读到的是 `is_compat`（0）。

### 产物与验证
- `release/boot-KsAdbRoot-20261108_150805.img`（`4.14.336-KsAdb #5 ... 15:03:52`），
  已 `fastboot flash boot_a` 刷入。
- `feature set adb_root 1` + `feature save` + 重启后：
  `adb shell id` → `uid=0(root) ... context=u:r:ksu:s0`（不经 su）；
  `adb root` → `adbd is already running as root`；
  adbd environ 含 `LD_PRELOAD=/data/adb/ksu/lib/libadbroot.so`；
  dmesg `KernelSU: escape to root for adb`。
- 反向：`feature set adb_root 0` + 重启 → `adb shell id` 回到 `uid=2000(shell)`。
- 之前「ADB Root 有害」的结论作废：当时的反复重启是 adbd 在无注入情况下被 KSU 的
  setresuid hook 降权，现在 adbd 本身就是 root，不再有降权循环。

### 注意
- 生效点是 adbd 启动时；`setprop ctl.stop/start adbd` 很容易让 adb 变 `offline`，
  推荐直接重启手机。
- user 版 ROM，`adb root` 命令本身仍被 adbd 拒绝（`not run as root in production builds`）；
  这里做到的是 adbd 进程本身是 root。


## 第 6 轮（2026-11-09）：重启菜单 → Bootloader 修好（BCB 翻译）

### 问题
管理器右上角「重启」→「重启至 Bootloader」，点了会短暂黑屏然后**回系统**，
永远进不去 fastboot。用户还报告过「重启至 Download / EDL」同样无效。

### 根因（有据可查）
- 系统写进 `misc` 的 BCB 命令是 Qualcomm 约定 `bootonce-bootloader`
  （见 `/system/lib64/libbootloader_message.so` 里只有两条串：`boot-recovery`、`bootonce-bootloader`）。
- chopin 的 `lk_a` 只认 `boot-fastboot` / `boot-recovery`
  （8388608 字节未压缩镜像里只有这几个 BCB 串，搜 `once` 无命中）。
- 所以 LK 忽略请求，照常开机。
- `recovery` 之所以一直正常：它写的 `boot-recovery` 恰好是 LK 认识的串。
- `Download` / `EDL` 在系统里**根本没有写入者**（全盘 grep 零命中），
  属于 Preloader 阶段按键，管理器那两项不可能生效——这不是 bug 能修的。

### 关键事实：`svc power reboot bootloader` 不走 reboot 系统调用
`/sys/fs/pstore/console-ramoops`：

```
init: Received sys.powerctl='reboot,bootloader' from pid: 1680 (system_server)
init: Reboot start, reason: reboot,bootloader, reboot_target: bootloader
init: Stopping 267 services by sending SIGTERM
mtk_rgu_dram_reserved: MTK_WDT_MODE(0x25)
wdt_arch_reset: disable pwrap before wdt reset
```

关完服务就被 MTK 看门狗复位，没有 "Reboot ending, jumping to kernel"。
所以只挂 `ksu_handle_sys_reboot()` 是救不了这条路的。

### 做法
新增 `drivers/kernelsu/kernel/runtime/boot_bcb.c`：把 misc 里的
`bootonce-bootloader` 改写成 `boot-fastboot`（`override_creds(ksu_cred)` + `filp_open` + `kernel_write` 32B + `fsync`）。
两条触发路径：
1. `ksu_fix_boot_bcb(cmd)` 挂在 `supercall/supercall.c` 的 `ksu_handle_sys_reboot()` 开头；
2. `ksu_boot_bcb_start()` 起一个 1 秒周期 `delayed_work` 轮询器，兜住"不走系统调用"的关机路径。

接线：`kernel/Kbuild` 加 `runtime/boot_bcb.o`；`kernel/core/init.c` 在
`ksu_permissive_persist_init();` 后调 `ksu_boot_bcb_start();`。

### 验证
- 直证（钩子）：自写 aarch64 freestanding 程序发非法 magic 的 `reboot()`，
  dmesg `KernelSU: boot_bcb: bootonce-bootloader -> boot-fastboot`。
- 端到端：`su -c sh /data/local/tmp/bt.sh`（`sleep 3; svc power reboot bootloader`）
  → USB 先 `2717:FF08`，t≈24s 断开，**t=44s 出现 `18D1:D00D`**，
  `fastboot devices` 看到设备并停留 40s 以上。
- 回归：普通 `reboot` 仍正常回系统，misc 全零，dmesg 无 `boot_bcb`。

### 提交
- 子模块 `ce8921ee feat(boot): translate the fastboot BCB command for the MTK LK`
- 父仓库 `b85d5273b ksu: make reboot-to-bootloader work on chopin`
- 文档 `docs/boot-recovery-reboot.md`
- 镜像 `release/boot-KsBcb2-20261109_014135.img`（注意 LOCALVERSION 仍是 `4.14.336-KsBcb`，
  只能靠构建文件名区分两版）

### 注意
- 带 `boot-fastboot` 的 misc 重启后会停在 fastboot 不动（期望行为），要回系统需
  再发一次 `fastboot reboot`，有时要重试 2–3 次。
- 编译只能用 `printf 'NAME\n2\n' | bash build.sh`（菜单 2）；自拼 `make` 会因为
  `CONFIG_CROSS_COMPILE` 与 env 不一致进入 `Restart config` 交互并 abort。
- 设备上现成脚本：`/data/local/tmp/bt.sh`（svc 重启到 bootloader）、
  `bcbtest`（测钩子）、`ctx.sh`（在 console-ramoops 里找 boot_bcb 行）、
  `ps.sh`（扫 pstore）。


## 文件位置
- 4.14 源码：`\\wsl.localhost\Ubuntu-24.04\home\xiaone\xiaomi_kernel_chopin`
- 6.6 主线：`\\wsl.localhost\Ubuntu-24.04\home\xiaone\linux-6.6.160`
- 刷机包输出：`F:\刷机\boot\测试\`（旧的 A17 包有 `_勿刷\` 子目录，别拿错）
- 回退用已知可开机包：`F:\刷机\boot\测试\boot-@Xiaonai-@小阮sensei_V02-20261011_221427.img`

## 第 7 轮（2026-11-09）：「重启至 Bootloader 落到 fastbootd」= 自己补丁的锅，已回退

- 现象：管理器点「重启至 Bootloader」，LK 短暂出现后交出，最终停在 **fastbootd**（`is-userspace: yes`）。
- 病因：上一轮的 `kernel/runtime/boot_bcb.c` 轮询器把 Android 标准 BCB `bootonce-bootloader`
  改写成 MTK 私有 `boot-fastboot`。LK 对二者语义不同：
  - `bootonce-bootloader` → LK 自己进 fastboot 并停住（真 fastboot，`is-userspace: no`）
  - `boot-fastboot` → LK 引导内核进 fastboot 模式 = fastbootd
- 实测（写 misc 后 4 秒回读）：`bootonce-bootloader` → `boot-fastboot`，证明改写确实发生。
- 处置：子模块 `git reset --hard ce8921ee~1`（HEAD 回到 `625159a2`），删除 `boot_bcb.c|h` 及三处引用；
  父仓库提交 `7393f688f`。新版内核 `4.14.336-KsNoBcb`，产物 `release/boot-KsNoBcb-20261109_125528.img`。
- 验证：刷入后点「重启至 Bootloader」→ t=15s `18D1:D00D`，`is-userspace: no`，
  `version-bootloader: chopin-b4b182403-20230427143113-20231102161415`，持续 169s 稳定停留。
- 文档：`docs/boot-recovery-reboot.md` 已按事实重写（含三种 BCB 串的语义表与复现命令）。
- 踩坑：用 PowerShell `Add-Content` 往 `\\wsl.localhost\...` 路径追加会把文件截断成只剩新增内容 —— 别这么干，
  要读全文再 `[IO.File]::WriteAllText()` 整体写回。
## 第 8 轮（2026-11-09 晚）：重启菜单"都回系统"是误判，真凶是并存的 adb server

- 用户报「刷 `boot-KsNoBcb-20261109_125528.img` 后，管理器点重启到 Recovery / Bootloader 都回系统」→ **未复现**。
- 干扰源：`E:\应用\搞机助手\adb.exe` 起了一个 `adb -L tcp:23973 fork-server server`，独占 USB 接口；设备管理器里 `ADB Interface` 一切正常但 `adb devices` 永远空。杀掉该进程 + `adb kill-server/start-server` 立刻恢复。
- 复测（每 2 秒采样 USB）：`svc power reboot recovery` → t=18s `18D1:4E11`（recovery，misc 里故意留 `bootonce-bootloader` 也一样）；`svc power reboot bootloader` → t=16s `18D1:D00D`，`getvar is-userspace` = `no`、`version-bootloader` = `chopin-b4b182403-...`（LK 原生 fastboot）。
- 用户亲手点 UI「重启至 Bootloader」→ logcat `PowerManagerService: Reboot reason:bootloader, calling pid:10034` → `ShutdownThread: Rebooting, reason: bootloader`，手机确实进黑底 FASTBOOT。
- 落文档：`docs/boot-recovery-reboot.md` 追加「6. 第 8 轮复核」。
- 排查口诀：**设备管理器 OK 但 adb 看不到设备 → 先查有没有第二个 adb server（`-L tcp:<port>`）**；重启类问题先确认只有一个 server、再按 VID 采样判落点（`2717:FF48` 系统 / `2717:FF08` LK 瞬时 / `18D1:D00D` fastboot 家族 / `18D1:4E11` recovery）。

## 第 9 轮（2026-11-10）：重启目标丢失的真凶 —— 关机时 ext4 sysfs 重复摘除导致内核 panic

- 用户报「点 Recovery 直接重启到系统」。现场 `/sys/fs/pstore/dmesg-ramoops-0`：
  `[561.798] init: Received sys.powerctl='reboot,recovery'` → `[561.805] Reboot start, reason: reboot,recovery, reboot_target: recovery`
  → `[566.310] Oops#1` 栈 `remove_proc_entry ← ext4_unregister_sysfs ← ext4_put_super ← generic_shutdown_super
  ← kill_block_super ← cleanup_mnt ← task_work_run` → `[568.001] wdt_arch_reset`（MTK 看门狗硬复位，reboot reason 丢了，LK 只能普通启动）。
- 成因链：`/data/adb/modules/meta-overlayfs/post-mount.sh` 调 `ksud kernel nuke-ext4-sysfs /data/adb/modules/meta-overlayfs/mnt`
  → 内核 `drivers/kernelsu/kernel/runtime/boot_event.c:79 nuke_ext4_sysfs()` → `ext4_unregister_sysfs(sb)` 释放 proc 条目
  但**不清 `sbi->s_proc`** → 关机 `ext4_put_super()`（`fs/ext4/super.c:924`）再摘一次 → UAF panic。编挂点 `/dev/block/loop33`。
- 为何时好时坏：UAF 崩不崩取决于释放后的内存有没被改写成野指针，100% 复现做不到，但机制与栈确定。
- 修法（`fs/ext4/sysfs.c`，让摘除幂等）：
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
  为什么改 ext4 不改 KSU：`nuke_ext4_sysfs()` 手里只有 `struct super_block *`，`s_proc` 是 `ext4_sb_info` 私有字段；
  幂等责任放 ext4 内部，任何"提前摘一次"的调用者都自动安全。
- 验证（`release/boot-KsExt4-20261110_001005.img`，`4.14.336-KsExt4`，**nuke 保持启用**，`/proc/fs/ext4/loop33` 确认不可见）：
  `svc power reboot recovery` → t=16.5s `18D1:4E11`；`svc power reboot bootloader` → t=16s `18D1:D00D`、
  `is-userspace: no`、`version-bootloader: chopin-b4b182403-...`，20s 后仍稳定；普通重启 ×2 正常回系统；
  `console-ramoops` 里无 `Oops#1`/`Panic#2`/`BUG:`，也无 `ext4_unregister`/`remove_proc_entry`。
- 收益：nuke（反检测、藏 `/proc/fs/ext4/loop33`）可以继续长期启用，不再需要"要稳就关 nuke"的取舍。
- 排查口诀：重启没到预期目标，先翻 `/sys/fs/pstore/`；`dmesg-ramoops-*` 有 `Oops#1`/`Panic#2` = 关机时内核崩了，
  reboot reason 必然丢失。`console-ramoops` 被截断到 256KB，完整栈常常只落在 `dmesg-ramoops-*`，两处都要看。
- 操作坑：进 recovery 后 `adb reboot` 可能被 recovery 的 adbd 判 `unauthorized`（新 adb server 密钥未授权），
  此时既没有 adb 也没有 fastboot 通道，必须在手机屏幕上点「允许 USB 调试」或长按电源键强刷回系统；recovery 不会自动退出。

## 第 10 轮（2026-11-10 下午）：Download / EDL 为什么点了回系统 —— 已定性，平台固件缺功能

- 用户问「那 Download/EDL 正常吗」，实测结论：**两个都不正常，点了只普通重启回系统**。
- 采样（每 2s 扫 USB VID/PID）：`svc power reboot download` → `2717:FF48` → 无 USB → `2717:FF08` → `2717:FF48`；
  `svc power reboot edl` 轨迹一模一样。**全程无 `0E8D`**（MTK Preloader/BROM），`misc` 始终 32 字节全零。
- 命令确实到了内核，卡在白名单：pstore 原文
  `init: Reboot start, reason: reboot,edl, reboot_target: edl` → `ARCH_RESET happen!!!` → `arch_reset: cmd = edl`
  → `wdt_arch_reset: disable pwrap before wdt reset`。
  瓶颈是 `drivers/watchdog/mediatek/wdk/wd_api.c:659` 的 `arch_reset()`，cmd 只认
  `charger` / `recovery` / `bootloader` / `dm-verity device corrupted` / `kpoc`，其余落到
  `reboot = WD_SW_RESET_BYPASS_PWR_KEY`（= 普通看门狗复位，PMIC spare register 不留标记）。
- 为什么 recovery/bootloader 能成：`rtc_mark_recovery()` 写 `RTC_FAC_RESET`、`rtc_mark_fast()` 写
  `RTC_FAST_BOOT`（`drivers/mfd/mt6358-misc.c:379/717`），LK 上电读这两个标记。`enum rtc_spare_enum`
  里根本没有 DL/EDL 项。
- LK/Preloader 侧也无入口（所以内核改不了）：
  - `lk_a`（8388608 字节，未压缩）：`edl` 0 次、`boot-edl` 0、`boot-download` 0、`downinit` 0、`bootonce` 0；
    只认 `Reason: vol down` / `reboot bootloader` / `boot menu` / `detect META Mode` / `unknown`；
    BCB 串只有 `boot-fastboot`(685732) 与 `boot-recovery`(685816)；22 条 `oem` 命令无一能进。
  - `preloader_chopin.bin`（453580 字节）：`bootonce`/`boot-fastboot`/`boot-recovery` 全 0 → **不看 misc**；
    只有 `download keys are pressed` 与 `emergency download mode(timeout: %ds)`，即只认按键/工具握手。
  - HyperOS4(A17) `images/lk.img` 对比：`boot-edl`/`boot-download`/`downinit` 同样全 0。
- 旁证：`svc power reboot download` 后 `persist.sys.boot.reason` 记成 `reboot,downinit`，
  但 `downinit` 在内核、LK、init、framework.jar、services.jar 里**一次都没出现** —— 名字有，实现没有。
- 结论：**平台固件层缺失，系统侧与内核侧都补不了**。管理器这两项是上游通用菜单
  （`svc power reboot <reason>`，`KsuCli.kt:426-438`），只在固件支持该 reason 的机型上有意义。
- 真要进：关机 → 同时按住音量+ 与音量- → 插 USB（Preloader 的 `download keys are pressed`）→
  DA 握手（`FlashROM/` 的 `MTK_AllInOne_DA.bin` + `SP_Download_tool`）；EDL 走
  `emergency download mode`（带 timeout）或短接测试点。风险：真进 EDL 只能靠 SP Flash Tool 出来。
- 文档：`docs/boot-recovery-reboot.md` 新增第 8 节（实测表、pstore 原文、白名单代码、LK/Preloader 取证、物理进入法）
  并把第 1 节速查表两行改成准确描述；`docs/kernel-feature-changelog.md` 第四章加一段、第七章「已知限制」
  那一行从"系统侧无写入者"升级为含 `arch_reset()` 白名单的完整结论。
  提交 `6e5503b31 docs: pin down why the Download/EDL reboot targets fall back to a normal boot`。
- 现场状态：设备 `4.14.336-KsExt4`、`getenforce`=Permissive、nuke 启用、元模块 Installed、adb 正常
  （注意 `E:\应用\搞机助手\adb.exe` 那个 `-L tcp:23973` 的 server 会抢总线，发现 adb 看不到设备先杀掉它）。

## 第 11 轮（2026-11-10 晚）：把 Download / EDL 重定向到 LK fastboot（已落地、已刷、已验证）

用户当场选 A（改内核重定向），不再是"平台缺功能只能认命"。

### 改动（只有一个文件）

`drivers/watchdog/mediatek/wdk/wd_api.c` 的 `void arch_reset(char mode, const char *cmd)`，
在 `bootloader` 分支之后加一支：

```c
} else if (cmd && (!strcmp(cmd, "download") || !strcmp(cmd, "edl") ||
                   !strcmp(cmd, "downinit"))) {
        pr_info("%s: %s has no firmware entry, booting LK fastboot instead\n",
                __func__, cmd);
        rtc_mark_fast();       /* 与 "bootloader" 完全同一条路 */
}
```

- 为什么收三个名字：`edl`/`download` 是管理器菜单直接传的 target，`downinit` 是 MIUI 在
  `persist.sys.boot.reason` 里用的别名。
- 为什么用 `rtc_mark_fast()`：它写 PMIC 的 `RTC_FAST_BOOT` spare 位（`drivers/mfd/mt6358-misc.c:717`），
  和第 8 轮验证过的 `reboot bootloader` 完全同一条路，落点必然是同一个界面，无需新的验证假设。
- **为什么不是写 BCB**（这条弯路本鱼走了一遍又撤了）：`lk_a` 里 `bootonce` 搜索 **0 次命中**，
  LK 根本不认 Android 标准的 `bootonce-bootloader`（也解释了 misc 残留该串时照样进 recovery/普通系统）。
  真正决定 LK 停不停在 fastboot 的是 PMIC 的 `RTC_FAST_BOOT` 位。中途写好的
  `kernel/runtime/boot_bcb.{c,h}` + Kbuild + supercall 钩子已全部删除，`git status` 干净。

### 构建与刷机

- `printf 'KsEdl\n2\n' | bash build.sh` → Image 44980240 字节，`Linux version 4.14.336-KsEdl
  (xiaone@shkm) ... #1 SMP PREEMPT Tue Nov 10 18:30:30 CST 2026`；产物里 `has no firmware entry` 命中 1 次。
- `printf 'KsEdl\n3\n' | bash build.sh` → `release/boot-KsEdl-20261110_183333.img`（134217728），
  已归档 `F:\刷机\boot\测试\boot-KsEdl-20261110_183333.img`。
- 刷机：`adb reboot bootloader`（这次 4 秒就进 fastboot）→ `fastboot flash boot_a` →
  `Sending OKAY [4.725s] / Writing OKAY [1.094s]` → `fastboot reboot` → adb 24s 起来，`uname -r` = `4.14.336-KsEdl`。

### 实测（每次测试前都把 misc 前 32 字节清零，排除残留）

| 入口 | USB 轨迹 | 落点 | 结论 |
|---|---|---|---|
| `svc power reboot edl` | `2717:FF48` → 无 → t=14s `18D1:D00D` 持续 58s+ | `is-userspace: no` | ✅ LK fastboot |
| `svc power reboot download` | `2717:FF48` → 无 → t=14s `18D1:D00D` 持续 42s+ | `is-userspace: no` | ✅ LK fastboot |
| `svc power reboot bootloader` | `2717:FF08` → `18D1:D00D` t=14s | `is-userspace: no` | ✅ 未受影响 |
| `svc power reboot recovery` | `2717:FF48` → 无 → t=18s `18D1:4E11`（复测 2 次皆中） | recovery | ✅ 未受影响 |
| 普通 `adb reboot` | 正常 | `ro.boot.bootreason=reboot` | ✅ 未受影响 |

- `version-bootloader: chopin-b4b182403-20230427143113-20231102161415`、`current-slot: a` —— LK 原生，非 fastbootd。
- **日志直证抓不到，但用背靠背 A/B 补上了因果**：
  - 采集侧三条路全废：`dmesg -w > /data/local/tmp/rec.log` 在复位前只写下
    `init: Received sys.powerctl='reboot,recovery'` 就断；`/sys/fs/pstore` 里只有 `pmsg-ramoops-0`；
    `/data/system/dropbox/` 的 26 份 `SYSTEM_LAST_KMSG` 里 `firmware entry` **命中 0 次**
    （里面有 6 份 `arch_reset: cmd = edl` / 6 份 `cmd = download`，时间戳 16:09/16:42/17:45
    全早于 KsEdl 编译时间 18:30，都是 KsExt4 时代的）。
  - 反向对照：同一次 `reboot recovery` 的 `console-ramoops` 有 262KB 且完整保留到
    `arch_reset: cmd = userrequested,recovery` → **走 fastboot 分支时 ramoops 的 DRAM 区域不被保留**。
    这是采集环境问题，再加 `printk_deferred` 也没用（所以"补直证"这个方案本身被证伪了）。
  - 改做背靠背 A/B：先刷 `boot-KsExt4.img`（无分支）→ `svc power reboot edl` → 回 Android
    （`2717:FF48` → 无 → `2717:FF08` → 系统，`ro.boot.bootreason=reboot`）；再刷 `boot-KsEdl.img`
    （有分支）→ 同命令 → t=14s `18D1:D00D`、`is-userspace: no`；再跑 `download` → t=12s 同样进 fastboot。
    两内核只差 `wd_api.c` 一个 hunk（`eae22a26d` 是唯一改 `arch_reset()` 的提交），间隔约五分钟 → 因果闭合。

### 坑（本轮新增）

- **`lk_a` 不认 `bootonce-bootloader`**：这是本轮最贵的一条认知纠正，第 6 轮的 BCB 翻译补丁就是被这条否掉的。
- **recovery 的 adbd 会 `unauthorized`**：从 recovery 里 `adb reboot` 报 `device unauthorized`，
  此时 fastboot 也看不到设备 → 只能手机上确认 USB 调试，或长按电源键。recovery 不会自己退出。
- **adb/fastboot 路径**：`F:\刷机\ROM包\RedmiNote10Pro\HyperOS1\[第3.1版]...\FlashROM\platform-tools\`
  里的那套才是对的（`F:\刷机\platform-tools` 不存在，`adb version` 会混到 41 版导致 server 版本冲突）。
- **PowerShell 引号**：`adb shell "su -c 'dmesg | grep ...'"` 里的 `|` 和引号会被 PowerShell 吃掉，
  一律写设备侧 `.sh` 再 `su -c 'sh /data/local/tmp/x.sh'`。

### 提交

- `eae22a26d watchdog: route the download/edl reboot targets to LK fastboot`
- `37f174c31 docs: record the download/edl redirect and how it was verified`
- `docs/boot-recovery-reboot.md` 新增第 9 节（改动、为什么不是 BCB、实测表、直证缺口）；
  `docs/kernel-feature-changelog.md` 第四章加「第 11 轮」小节、第七章「已知限制」那一行从
  "平台固件层缺失，内核无法补"改为"已重定向到 LK fastboot"。

### 现场状态

设备 `4.14.336-KsEdl`、`getenforce`=Permissive、nuke 启用（`/proc/fs/ext4/loop33` 不可见）、
元模块 Installed、adb 正常。`git status --short` 只剩未跟踪的 `HANDOFF-chopin-6.6-2026-11-07.md`。
