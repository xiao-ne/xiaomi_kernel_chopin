#!/usr/bin/env python3
"""往 Android boot image (header v0/v1/v2) 的 cmdline 里追加参数。

为什么需要它：官方/原厂 boot.img 的 header cmdline 只有
    bootopt=64S3,32N2,64N2 buildvariant=user
缺少 androidboot.selinux=enforcing 这类首阶段 init 依赖的参数；
而我们自己打的 eng 底包里有。与其"换底包"，不如把缺的参数补进去。

用法:
    patch_boot_cmdline.py <boot.img> <token> [<token> ...]
"""
import sys

MAGIC = b"ANDROID!"
CMDLINE_OFF = 64
CMDLINE_LEN = 512
HEADER_VERSION_OFF = 40


def main() -> int:
    if len(sys.argv) < 3:
        print("用法: patch_boot_cmdline.py <boot.img> <token> [<token> ...]", file=sys.stderr)
        return 2
    path, tokens = sys.argv[1], sys.argv[2:]

    with open(path, "rb") as f:
        data = bytearray(f.read())

    if len(data) < 1024 or bytes(data[:8]) != MAGIC:
        print(f"不是 Android boot image: {path}", file=sys.stderr)
        return 1

    hv = int.from_bytes(data[HEADER_VERSION_OFF:HEADER_VERSION_OFF + 4], "little")
    if hv > 2:
        print(f"header v{hv} 的 cmdline 不在 header 里，跳过（本脚本只处理 v0-v2）", file=sys.stderr)
        return 0

    raw = bytes(data[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN])
    cur = raw.split(b"\x00", 1)[0].decode("latin-1")

    have = set(cur.split())
    missing = [t for t in tokens if t not in have]
    if not missing:
        print(f"cmdline 已包含所需参数: {cur}")
        return 0

    new = cur + (" " if cur else "") + " ".join(missing)
    if len(new) > CMDLINE_LEN - 1:
        print(f"cmdline 太长（{len(new)} > {CMDLINE_LEN - 1}），拒绝写回", file=sys.stderr)
        return 1

    field = new.encode("latin-1") + b"\x00" * (CMDLINE_LEN - len(new))
    data[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN] = field

    with open(path, "r+b") as f:
        f.seek(0)
        f.write(data)

    print(f"cmdline 旧: {cur}")
    print(f"cmdline 新: {new}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
