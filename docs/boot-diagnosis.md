# Chopin 内核开机诊断与修复说明

- **设备**：红米 Note 10 Pro（chopin / MT6891）
- **内核**：Linux 4.14.336 backport
- **分支**：`backport-4.14.336-A15-etc`
- **日期**：2026-09-24

## 背景

用户反馈自编内核**能开机的概率很低**。体检结论：核心启动符号（`mt_gpt_init` / SYSTIMER）正常，主要风险在**崩溃策略**与**打包改 fstab**。

## 本次修复内容

### 1. 关闭 oops 立即重启（defconfig + build.sh）

| 项 | 原值 | 新值 |
|----|------|------|
| `CONFIG_PANIC_ON_OOPS` | `y` | **未设置** |
| `CONFIG_PANIC_TIMEOUT` | `1`（1 秒重启） | **`0`（不自动重启）** |

**原因**：任意 Oops 都会在 1 秒内重启，pstore 往未来不及写，表现为「几乎开不了机、也无日志」。

### 2. 打包默认不注入 EROFS fstab（build.sh）

- 新增环境变量 `ENABLE_EROFS_FSTAB`，**默认 `0`**。
- `=1` 时才往 `first_stage_ramdisk/fstab.*` 插 erofs 行。
- **原因**：Android 13 若 system/vendor 仍是 ext4，强插 `erofs` 且无 `nofail` 会导致 first_stage 挂载失败 → 循环重启。

EROFS ROM 需要时：

```bash
ENABLE_EROFS_FSTAB=1 bash build.sh
```

### 3. 关闭 AEE IPANIC（defconfig + build.sh）

- `# CONFIG_MTK_AEE_IPANIC is not set`
- 编译阶段再强制 sed 一次，防止 `olddefconfig` 又打开。

### 4. ramoops / pstore（说明，未改 DTS）

- 内核已开：`CONFIG_PSTORE=y`、`CONFIG_PSTORE_RAM=y`、`CONFIG_PSTORE_CONSOLE=y`。
- **设备树侧**：chopin 为 `/plugin/` 覆盖层，`reserved-memory` 基节点多在 **bootloader 基线 DTB**；内核 DTS 中无独立 `ramoops@` 节点。
- **未随意加 ramoops 地址**：错误物理地址会覆盖关键内存，反而更难开机。待确认机型保留区后再加。

崩溃后若能进系统，尽快抓：

```bash
ls /sys/fs/pstore/
cat /sys/fs/pstore/console-ramoops-0 > /sdcard/ramoops.txt
dmesg -T > /sdcard/dmesg.txt
```

## 未改动但已知的风险点

| 项 | 说明 |
|----|------|
| `CONFIG_BPF_EVENTS=y` | 曾与启动循环相关；若仍失败可试验关掉 |
| `CONFIG_MACH_MT6893=y` | DTS 为 MT6891；历史可开机，暂不动 |
| CMDLINE 中 `slub_debug=O` | `CMDLINE_FROM_BOOTLOADER=y` 时默认不强制，以 bootloader 为准 |
| 定时器 | `mt_gpt_init` / `mtk_stmr_init` 符号齐全，条件正确 |

## 构建与刷机

```bash
cd ~/xiaomi_kernel_chopin
# 默认：诊断 panic + 不改 fstab
printf '\n1\n' | bash build.sh
# 产物：release/boot-<版本名>-<时间戳>.img
```

刷入后验证：

1. 能否稳定进桌面
2. `uname -a` 是否为 `4.14.336-*`
3. 若再崩：`/sys/fs/pstore/` 是否有 `console-ramoops*`

## 底包校验（2026-11-01 修正）

`pack_img` 选底包的判据**不再是** `strings boot.img | grep androidboot.selinux=enforcing` ——
MTK 的 `androidboot.*` 由 bootloader 在 cmdline 传入，镜像里根本不存在这些字符串，
旧判据对任何包都返回假（结果是要么 abort，要么被迫 `FORCE_BASE_IMG=1` 绕过唯一校验）。

现在改为**解包后看 ramdisk**：

```bash
magiskboot unpack <img>
zcat -f ramdisk.cpio | strings -a
# 出现 ro.build.type=user 或 ro.debuggable=0 → 判为原厂 user 包，拒绝
```

`boot/boot.img` 当前就是原厂 user 包（`ro.build.type=user`、`ro.debuggable=0`），
所以 `./build.sh pack` 会直接 abort。要打包必须：

```bash
export BASE_IMG=/path/to/eng-or-userdebug-boot.img   # ramdisk 里 ro.debuggable=1
```

`FORCE_BASE_IMG=1` 只用于已经确认能开机的底包，别拿它绕过这条检查。

## 相关文档 / 笔记

- 项目规则：`~/AGENTS.md`（中文回答、注释、commit）
- 历史启动循环根因：`.mnemon` 中 `chopin-4-14-mtk-apxgpt-bpf-backport-*`
- cgroup 随机重启：提交 `18dd15f844`
- KSU su：`dd0e4a2cf7` / 子模块 su 路径匹配

## 构建自检清单

```bash
# 关键配置
grep -E 'PANIC_ON_OOPS|PANIC_TIMEOUT|AEE_IPANIC' out/.config
# 期望：PANIC_ON_OOPS 未设置，TIMEOUT=0，AEE_IPANIC 未设置

# 启动符号
grep -E 'mt_gpt_init|__initcall_mt_gpt_init6|mtk_stmr_init' out/System.map
```

## 本次构建产物（2026-09-24）

| 项 | 值 |
|----|-----|
| 镜像 | `release/boot-DiagBoot-20260924_083357.img` |
| 内核 | `4.14.336-DiagBoot` |
| panic | `PANIC_ON_OOPS` 未开，`PANIC_TIMEOUT=0` |
| AEE_IPANIC | 关 |
| EROFS fstab | **未注入**（日志：跳过 EROFS fstab 注入） |
| 定时器符号 | `mt_gpt_init` / `mtk_stmr_init` 正常 |

续编/打包：`./build.sh compile`（仅编译，不重新 mrproper）+ `./build.sh pack`（仅打包）；
缺 `asm-generic` 包装头时 `build.sh` 会自动补。体检：`./build.sh check`。  
注意：`build.sh` 全量路径若遇 `asm/types.h` 找不到，先执行：

```bash
make -f scripts/Makefile.asm-generic src=uapi/asm obj=out/arch/arm64/include/generated/uapi/asm
make -f scripts/Makefile.asm-generic src=asm obj=out/arch/arm64/include/generated/asm
```

## pack_img() 的 ramdisk 重压 bug（2026-11-07 修复，commit 6ee78380d）

症状（用户在 `~/xiaomi_kernel_chopin` 里跑 `./build.sh` 选打包时）：

```
build.sh: line 363: cd: _rd_fix82131: No such file or directory
build.sh: line 367: /home/xiaone/xiaomi_kernel_chopin/boot/tmp_136190/ramdisk.cpio: No such file or directory
mv: cannot stat '.../ramdisk.cpio.new': No such file or directory
❌ ramdisk 重压失败：拒绝用未修改的 ramdisk 继续打包
```

两只虫子叠在一起：

1. **解包去错目录**：`mkdir -p "$rd_tmp"` 之后写的是 `cpio -idm < "$PWD/ramdisk.cpio"`，
   没有 `cd` 进 `$rd_tmp`，于是内容全解到了 `boot/tmp_$$` 根目录；后面所有检查都
   去 `$rd_tmp/first_stage_ramdisk/` 里找 → 全部空转。**这是静默失效**：日志照样
   打印「fstab 修复完成」「已补 GSI AVB 公钥」，但产物里 erofs 行与公钥根本不存在。
2. **$PWD 漂移**：三个子 shell 里先 `cd "$rd_tmp"` 再引用 `"$PWD/ramdisk.cpio"`，
   此刻 `$PWD` 已经变成临时目录 → 读不到输入，写出一个 **512 字节的空 cpio**，
   随后的 `mv` 自然落空。

修法：解包显式在 `$rd_tmp` 内执行；把 `ramdisk.cpio` 在 `cd` 之前固化成
`rd_cpio="$PWD/ramdisk.cpio"`，读取列表、重压输出、`mv` 全走这个绝对路径；
对重压产物加 `[ -s ... ]` 非空校验，宁可报错也不产出空 ramdisk。

**验证方式（必须是真跑，不是 `bash -n`）**：

```bash
printf 'TEST\n3\n' | ./build.sh          # 3 = 仅打包；底包用原厂 user boot.img
# 再看产物解开后 fstab 是否真有 erofs 行、/avb 是否有三把公钥
magiskboot unpack release/boot-*.img && cd rd && cpio -idm < ../ramdisk.cpio
grep -n erofs first_stage_ramdisk/fstab.*   # 期望 system/vendor/product/mi_ext(/system_ext) 各一行，且在 ext4 行之前
ls first_stage_ramdisk/avb/                 # 期望 q-gsi / r-gsi / s-gsi 三把
```

> 教训：上次「bash -n 通过 + 看日志说成功」就收工，结果交付的是静默失效的版本。
> 这类 shell 补丁只有**重跑一遍并解包复验产物**才算验证。
