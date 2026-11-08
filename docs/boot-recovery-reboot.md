# 重启到 Bootloader 进不去（chopin，MTK A/B）

## 现象

管理器（KernelSU-Next v3.4.0）右上角「重启」菜单里的「重启至 Bootloader」，点了之后
手机短暂黑屏、重启，最后回到 Android 系统，而不是停在 fastboot。

同样的现象也会出现在任何走「框架重启」的入口：`svc power reboot bootloader`。

## 结论（一句话）

系统写进 `misc` 分区的 BCB 命令是 Qualcomm 约定的 `bootonce-bootloader`，
而 chopin 的 MTK LK 只认 `boot-fastboot` / `boot-recovery`，于是它忽略这个请求、照常开机。

## 证据

### 1. BCB 是谁写的

`/system/lib64/libbootloader_message.so`（116040 字节）里只有两条命令串：

```
boot-recovery          <- 走恢复模式用这条，所以恢复模式一直正常
bootonce-bootloader    <- 走 fastboot/bootloader 用这条，MTK 不认
```

`/system/bin/init` 里的相关串：`reboot-bootloader: Error writing bootloader_message: `。

### 2. LK 认什么

导出 `lk_a`（8388608 字节，未压缩，13319 条 ASCII 串）后搜 BCB 命令串，
只有这五条：`boot-fastboot`、`boot-recovery`、`reboot-bootloader`、
`reboot-fastboot`、`reboot-recovery`；搜 `once` 只命中 RPMB nonce 之类的无关串，
**没有 `bootonce-bootloader`**。

### 3. 上层怎么重启的

| 入口 | 是否写 BCB | 写了什么 | 结果 |
| --- | --- | --- | --- |
| 手写 misc + `reboot` | 手动 | `boot-recovery` | 进 recovery ✅ |
| 手写 misc + `reboot` | 手动 | `boot-fastboot` | 进 fastboot 并停住 ✅ |
| `adb reboot bootloader` | 是（adbd） | `bootonce-bootloader` | 一般能进 fastboot（见下） |
| `su -c reboot bootloader`（toybox） | **否** | misc 保持全零 | 回系统 ❌ |
| `svc power reboot bootloader`（管理器同款） | 是（init） | `bootonce-bootloader` | 回系统 ❌ |

`/sys/fs/pstore/console-ramoops` 里 `svc` 那条路的样子：

```
(4)[484:init]init: Received sys.powerctl='reboot,bootloader' from pid: 1680 (system_server)
init: Reboot start, reason: reboot,bootloader, reboot_target: bootloader
init: Stopping 267 services by sending SIGTERM
mtk_rgu_dram_reserved: MTK_WDT_MODE(0x25)
wdt_arch_reset: disable pwrap before wdt reset
```

注意两点：一是**根本没有走到 reboot 系统调用**（MTK 看门狗在关服务之后直接把整机复位），
二是复位前 misc 里留下的是 `bootonce-bootloader`。

## 补丁

`drivers/kernelsu/kernel/runtime/boot_bcb.c`（新文件），做一件事：
把 `misc` 里的 `bootonce-bootloader` 改写成 `boot-fastboot`。

两条触发路径：

1. `ksu_fix_boot_bcb(cmd)`：挂在 `ksu_handle_sys_reboot()` 的开头，处理
   `LINUX_REBOOT_CMD_RESTART` / `_RESTART2`（覆盖 `adb reboot bootloader`、
   toybox `reboot` 之类会走到系统调用的路径）。
2. `ksu_boot_bcb_start()`：一个 1 秒周期的 `delayed_work` 轮询器。
   因为 `svc power reboot bootloader` 那条路**永远不会走到 reboot 系统调用**
   （见上面 pstore），只靠钩子救不了它，只能主动去盯 BCB。

接线：`kernel/Kbuild` 加 `kernelsu-objs += runtime/boot_bcb.o`；
`kernel/core/init.c` 在 `ksu_permissive_persist_init();` 后调 `ksu_boot_bcb_start();`；
`kernel/supercall/supercall.c` 在 `ksu_handle_sys_reboot()` 第一行前调 `ksu_fix_boot_bcb(cmd);`。

写盘用 `override_creds(ksu_cred)` + `filp_open("/dev/block/by-name/misc", O_WRONLY)`
+ `kernel_write()` 32 字节 + `vfs_fsync()`，语义与 allowlist 落盘一致。

## 验证

- 内核字符串（`strings -a out/arch/arm64/boot/Image`）：`bootonce-bootloader`、
  `boot-fastboot`、`KernelSU: boot_bcb: %s -> %s`、`KernelSU: boot_bcb: cannot open misc for write`。
- 钩子直证：自写 freestanding aarch64 程序 `bcbtest` 发一个非法 magic 的 `reboot()`
  系统调用，misc 由 `bootonce-bootloader` 变成 `boot-fastboot`，dmesg：

  ```
  [362.790607] (4)[8910:bcbtest]KernelSU: boot_bcb: bootonce-bootloader -> boot-fastboot
  ```

- 端到端：`su -c sh /data/local/tmp/bt.sh`（内容 `sleep 3; svc power reboot bootloader`）
  之后 USB 先 `2717:FF08`，t≈24s 断开，**t=44s 出现 `18D1:D00D`**，
  `fastboot devices` 看到设备，`fastboot getvar current-slot` → `current-slot: a`，
  停留 40s 以上不再自动回系统。
- 回归：普通 `reboot` 仍然正常回系统，misc 全零，dmesg 无 `boot_bcb` 记录。

## 注意

- 这条补丁只解决「系统层写错 BCB 字符串」的问题，不改变 LK 能力：
  Download / EDL 在系统侧**根本没有任何写入者**
  （全盘 grep `boot-download` / `boot-edl` / `download_mode` / `DOWNLOAD_BOOT` 零命中），
  管理器的这两项本来就不可能在系统里生效，那是 Preloader 阶段的按键组合。
- 设备带着 `boot-fastboot` 的 misc 重启后会停在 fastboot 不动（这是期望行为），
  要回系统得再发一次 `fastboot reboot`，必要时重试两三次。
- 轮询器每秒读一次 misc（32 字节），开销可以忽略；只在检测到
  `bootonce-bootloader` 时才写盘。