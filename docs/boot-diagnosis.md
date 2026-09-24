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

辅助脚本：`diag_build.sh`（不 mrproper，缺包装头时自动补 `asm-generic`）。  
注意：`build.sh` 全量路径若遇 `asm/types.h` 找不到，先执行：

```bash
make -f scripts/Makefile.asm-generic src=uapi/asm obj=out/arch/arm64/include/generated/uapi/asm
make -f scripts/Makefile.asm-generic src=asm obj=out/arch/arm64/include/generated/asm
```
