# 重启菜单（Recovery / Bootloader / Download / EDL）在 chopin 上的真实行为

本文件记录 `4.14.336` chopin（Redmi Note 10 Pro / MT6893，A/B 无 recovery 分区）上，
KernelSU 管理器「重启」菜单各入口的实测行为、MTK LK 的 BCB 语义，以及一次错误的修复尝试。

## 1. 结论速查

| 入口 | 底层动作 | 结果 |
|---|---|---|
| 重启至 Recovery | 管理器先切飞行模式，再 `svc power reboot recovery`；init 写 BCB=`boot-recovery` | 进 recovery（boot ramdisk 里的 `system/bin/recovery`） |
| 重启至 Bootloader | `PowerManager.reboot("bootloader")` → ShutdownThread → `Reboot reason: bootloader`；init 写 BCB=`bootonce-bootloader` | **LK 原生 fastboot**（`is-userspace: no`，`version-bootloader: chopin-b4b182403-...`），15s 到达并长期停留 |
| 重启至 Download | 系统侧没有任何实现 | 只会普通重启回系统 |
| 重启至 EDL | 系统侧没有任何实现 | 只会普通重启回系统 |

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