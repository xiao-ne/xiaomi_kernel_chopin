# Android 17 (API 37) BPF 子系统移植记录

目标：让 Android 17 GSI 在 chopin（Redmi Note 10 Pro / MT6891Z）的原厂 4.14.336 内核上
通过 `bpfloader` 阶段正常启动。A17 的 `NetBpfLoad` 是 Rust 重写版，会自己解析 ELF、
按 uname 选择 `<节名>$A_B` 变体、并用 libbpf 1.4 加载。任何**必需**程序加载失败都会
触发 `reboot,bpfloader-failed`。

## 1. 版本欺骗（前提）

`kernel/sys.c` 的 uname 伪装把 `release` 改成 `5.10.209`（SDK>=37 时），
`/proc/last_kmsg` 里 `kver:50a00d1` 证明 bpfloader 确实按 5.10 选择变体。
因此只需要覆盖 `$4_x` / `$5_x`（<=5.10）的程序变体。

## 2. BTF

* 生成：`scripts/link-vmlinux.sh` 的 `gen_btf()` 用 pahole 从 vmlinux 抽 `.BTF`，
  `DEBUG_INFO_BTF=y` 时必须有 pahole，否则构建直接失败（不再静默跳过）。
* 导出：`kernel/bpf/sysfs_btf.c` -> `/sys/kernel/btf/vmlinux`（6.9MB，12183 个类型）。
* 解析器补齐的类型：
  * `BTF_KIND_FUNC` 的连接属性存在 `vlen` 里（STATIC=1/GLOBAL=2/EXTERN=3），
    不能再要求 `vlen == 0`；
  * `BTF_KIND_TYPE_TAG` 属于 modifier，必须能被 `btf_type_is_modifier()` 识别，
    否则 `btf_type_id_size()` 会 `WARN_ON_ONCE` 后返回 NULL -> `-EINVAL`；
  * `BTF_KIND_ENUM64` 必须出现在 `btf_type_has_size()` 里，size = 8。
* 诊断：`btf: type %u (kind %u) rejected by check_meta: %d`，避免只能靠猜。

## 3. 帮助函数表与 __sk_buff 布局

* `include/uapi/linux/bpf.h` 的 `__BPF_FUNC_MAPPER` 扩到 188 项（对齐 Linux 6.1），
  A17 的对象是按 6.1 的枚举编号编译的（例如 158=get_current_task_btf、
  182=strncmp、131=ringbuf_reserve）。
* `struct __sk_buff` 补齐到现代布局（192 字节）：
  `data_meta, flow_keys, tstamp, wire_len, gso_segs, sk, gso_size, tstamp_type, hwtstamp`，
  并在 `bpf_convert_ctx_access()` 里给出对应转换；常量字段必须同时写 `*target_size`，
  否则 `convert_ctx_accesses()` 会报 `bpf verifier is misconfigured`。
* `bpf_ktime_get_boot_ns` 原来只有 `__weak` 声明、没有实现，`fixup_bpf_calls()` 会
  直接判 `kernel subsystem misconfigured`；在 `kernel/bpf/helpers.c` 用
  `ktime_to_ns(ktime_get_boottime())` 实现（4.14 没有 `ktime_get_boottime_ns`）。

## 4. ringbuf（mmap 环形缓冲）

`kernel/bpf/ringbuf.c` 从 5.10 移植：逐页分配 + 两次 `vmap()` 保证回绕记录连续，
`map_mmap`/`map_poll` 挂到 `bpf_map_ops`，`bpf_map_mmap()` 不能重复取 `mmap_sem`
（VFS 已持有）。4.14 没有 `EPOLLIN/EPOLLRDNORM`，用 `POLLIN|POLLRDNORM`。

记录级帮助函数需要 `PTR_TO_MEM`：

* 新寄存器类型 `PTR_TO_MEM` / `PTR_TO_MEM_OR_NULL`，`struct bpf_reg_state` 增加
  `u32 mem_size`；
* 新参数类型 `ARG_PTR_TO_ALLOC_MEM`、`ARG_CONST_ALLOC_SIZE_OR_ZERO`，
  返回类型 `RET_PTR_TO_ALLOC_MEM_OR_NULL`；
* 引用计数：`PTR_TO_MEM` 必须进 `type_is_refcounted()/…_or_null()`，否则
  `mark_ptr_or_null_reg()` 会清掉 `reg->id`，`submit/discard` 的
  `release_reference()` 拿不到引用 -> `check_reference_leak` 报错；
* `check_mem_access()`、`check_mem_region_access()` 负责边界检查
  （含变量偏移：`smin_value < -off || umax_value > mem_size - off - size`）；
* 五个帮助函数 `ringbuf_output/reserve/submit/discard/query` 在
  `bpf_base_func_proto()` 注册，`tc_cls_act_func_proto()` 会回落到它。

## 5. 其它 map 类型

* `BPF_F_MMAPABLE`（`1U << 10`）：array map 必须用 `__vmalloc_node_range()` 分配
  （kmalloc 的内存没法再映射），`array_map_mmap()` 用
  `remap_vmalloc_range(vma, array, vma->vm_pgoff + PAGE_ALIGN(sizeof(*array))>>PAGE_SHIFT)`。
* `BPF_MAP_TYPE_SK_STORAGE`：实现在 `net/core/bpf_sk_storage.c`，但
  `net/core/Makefile` 原来没编译它，符号来自 `kernel/bpf/cgroup_stubs.c` 里的空
  `sk_storage_map_ops`（`map_alloc == NULL` -> `-EINVAL`）。补上
  `obj-$(CONFIG_BPF_SYSCALL) += bpf_sk_storage.o` 并删掉空壳。

## 6. 验证器指令补齐

* `BPF_ARSH`：`adjust_scalar_min_max_vals()` 没有该分支，会直接
  `mark_reg_unknown()`。A17 的 CGROUP_SOCK 程序用
  `r6 &= 1; r6 <<= 32; r6 s>>= 32` 做符号扩展，于是
  `check_return_code()` 的 `tnum_in(tnum_range(0,1), var_off)` 失败：
  `At program exit the register R0 has unknown scalar value should have been in (0x0; 0x1)`。
  补 `tnum_arshift()`（5.10 原样）+ `case BPF_ARSH:`。
* `cgroup/sock` 程序：`sock_filter_func_proto()` 缺 `get_socket_cookie`(46) 与
  `sk_storage_get`(107)。ctx 就是 `struct sock *`（`bpf_sock_convert_ctx_access()`
  把字段访问改写成 `struct sock` 偏移），所以新增
  `bpf_get_socket_cookie_sock_proto`（`.arg1_type = ARG_PTR_TO_CTX`）和
  `bpf_sk_storage_get_cg_sock_proto`（复用 `bpf_sk_storage_get`，`.arg2_type = ARG_PTR_TO_CTX`）。
* `bpf_sk_storage_get/delete` 的 `.arg2_type`：4.14 原来写 `ARG_PTR_TO_SOCKET`，verifier 只认
  `PTR_TO_SOCKET`；而 SCHED_CLS 里 `skb->sk` 给的是 `PTR_TO_SOCK_COMMON`，于是
  `R2 type=sock_common expected=sock` -> `-13 (EACCES)`。5.10 用的是
  `ARG_PTR_TO_BTF_ID_SOCK_COMMON`（集合 = SOCK_COMMON/SOCKET/TCP_SOCK/XDP_SOCK/BTF_ID），
  4.14 的等价物是 `ARG_PTR_TO_SOCK_COMMON`（`type_is_sk_pointer()`）。
  放宽后实现里必须补 `sk_fullsock()` 守卫（5.10 有、我们原来没有），否则非全量
  `sock` 指针会按 `struct sock` 偏移读 `sk_bpf_storage`。

## 7. 调试手段（bring-up 期间临时保留）

* `kernel/bpf/syscall.c`：程序加载失败时把 verifier log 头尾打印到 dmesg；
* `kernel/bpf/verifier.c`：`verbose()` 每条消息同时 `pr_info("bpfv: %s", …)`；
* printk 与 `/dev/kmsg` 的限流在 bring-up 期间放宽（A17 的 `netbpfload` 一秒钟能打几十行）。

## 8. 已交付的内核包（`F:\刷机\boot\测试\`）

| 包 | 内容 | A13 | A17 |
| --- | --- | --- | --- |
| `boot-A17-funcfix-20261024_152520.img` | BTF FUNC 连接属性 | OK | 过了 BTF |
| `boot-A17-ringbuf-20261024_232545.img` | ringbuf map（5.10 版） | OK | 过 offload.o |
| `boot-A17-mmapable-20261025_000751.img` | BPF_F_MMAPABLE | OK | 过 blocked_ports_map |
| `boot-A17-skstorage-20261025_003714.img` | 真 sk_storage | OK | 过 sk_storage map |
| `boot-A17-ptrmem-20261025_015505.img` | PTR_TO_MEM + 五个 ringbuf 帮助函数 | OK | ringbuf_reserve 不再是 unknown func |
| `boot-A17-ptrmem2-20261025_020337.img` | PTR_TO_MEM 变量偏移边界 | OK | netd.o 只剩 ARSH 错误 |
| `boot-A17-arsh-20261025_100029.img` | ARSH + PTR_TO_MEM 作为帮助函数入参 | OK | netd.o 只剩 `sock_common` 错误 |
| `boot-A17-cgsock-20261025_110332.img` | 上面全部 + cgroup/sock 的 46/107 | OK | 同上（-13 `R2 type=sock_common expected=sock`） |
| `boot-A17-sockcommon-20261025_132146.img` | sk_storage 接受 sock_common + sk_fullsock 守卫 | 待测 | 待测 |

## 9. 测试方法

1. 刷 `boot-A17-cgsock-*.img`，确认 Android 13 能正常开机（回归检查）；
2. 用 DSU 启动 Android 17；
3. 失败会自动重启回 Android 13，然后取日志：

```bash
adb shell su -c 'cp /proc/last_kmsg /sdcard/lastk.txt'
adb pull /sdcard/lastk.txt
```

关注 `NetBpfLoad:` / `libbpf:` / `bpfv:` 开头的行。

## 10. 构建环境自检（重要）

这台机器（WSL2 + /home 在虚拟磁盘上）出现过**静默写入损坏**：文件内容变成随机字节，但
大小和 mtime 不变，因此 `git status` 因为 stat 缓存显示「干净」，`make` 只会报
`*** missing separator` 或 `source file is not valid UTF-8` 这类难以定位的错误。

自检脚本（对每个被跟踪文件按 git blob 规则重算 sha1 与 index 比对）：

```bash
python3 /mnt/c/Users/xiaone/AppData/Local/Temp/verify_sources.py
# 输出「不一致: N」即为损坏/未提交改动，需逐个恢复
```

踩过的坑：

* `mode 120000` 的符号链接在 git 里存的是**链接目标字符串**，按普通文件恢复会把真文件
  写成几十字节的文本（`arch/powerpc/lib/*.S`、`include/uapi/linux/input-event-codes.h` 都中过）；
* `mode 160000` 是子模块 gitlink，不能当文件处理；
* `arch/arm/boot/dts/mediatek` 在 index 里是普通文件、在工作区是目录，要跳过；
* `out/` 一旦出现损坏 `.o`/`.cmd`，最省事的做法是删掉整个 `out/` 重建。

**A17 的配置一定要在仓库里有对应文件**：`arch/arm64/configs/chopin_a17_defconfig`
（提交 `0fca3bb09`）。删 `out/` 之前它只存在于 `out/.config` 里，差点丢掉。
