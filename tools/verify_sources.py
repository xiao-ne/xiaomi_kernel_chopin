#!/usr/bin/env python3
"""校验工作区里所有被 git 跟踪的条目（普通文件 + 符号链接）是否与 index 一致。

用途：这台构建机的 WSL 虚拟磁盘出过两次静默写入损坏——文件内容变成随机字节，
但大小和 mtime 不变，于是 `git status` 因为 stat 缓存报「干净」，只有直接比内容
才能发现。发现问题后可 `git checkout -- <file>` 从对象库恢复。

用法：
    python3 tools/verify_sources.py                    # 在仓库任意子目录执行
    python3 tools/verify_sources.py --allow a.c b.c    # 允许某些故意改过的文件

退出码：0 全部一致；1 有内容不一致或文件缺失。
"""
import argparse
import hashlib
import os
import subprocess
import sys


def repo_root():
    r = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                       capture_output=True)
    if r.returncode != 0:
        sys.exit('不在 git 仓库里')
    return r.stdout.decode().strip()


def blob_sha1(data):
    return hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--allow', nargs='*', default=[],
                    help='故意改动、可以不一致的文件（相对仓库根）')
    ap.add_argument('--quiet', action='store_true')
    args = ap.parse_args()

    repo = repo_root()
    os.chdir(repo)
    allow = set(args.allow)

    raw = subprocess.run(['git', 'ls-files', '-s', '-z'],
                         capture_output=True).stdout
    entries = []
    for rec in raw.split(b'\0'):
        if not rec:
            continue
        meta, path = rec.split(b'\t', 1)
        mode, sha, _ = meta.split(b' ')
        if mode == b'160000':          # 子模块 gitlink，跳过
            continue
        entries.append((path.decode('utf-8', 'replace'), mode.decode(),
                        sha.decode()))

    bad, missing = [], []
    for done, (path, mode, sha) in enumerate(entries, 1):
        if not args.quiet and done % 25000 == 0:
            print(f'  ... 已检查 {done}', flush=True)
        if not os.path.lexists(path):
            missing.append(path)
            continue
        if mode == '120000':           # 符号链接存的是「链接目标字符串」
            target = os.readlink(path).encode()
            if blob_sha1(target) != sha:
                bad.append((path, 'symlink'))
            continue
        if os.path.isdir(path):        # 同名目录（例如 dts/ 目录代替文件）
            continue
        try:
            with open(path, 'rb') as f:
                data = f.read()
        except OSError as e:
            bad.append((path, f'读失败 {e}'))
            continue
        if blob_sha1(data) != sha:
            bad.append((path, 'content'))

    real_bad = [(p, w) for p, w in bad if p not in allow]
    print(f'跟踪条目: {len(entries)}  不一致: {len(bad)}'
          f'（其中允许 {len(bad) - len(real_bad)}）  缺失: {len(missing)}')
    for p, why in bad:
        print(f'  {"(允许)" if p in allow else "!!!"} {p} :: {why}')
    for m in missing[:20]:
        print(f'  缺失: {m}')
    with open('/tmp/bad_sources.txt', 'w') as f:
        for p, _ in real_bad:
            f.write(p + '\n')
    return 1 if (real_bad or missing) else 0


if __name__ == '__main__':
    sys.exit(main())
