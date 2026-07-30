// SPDX-License-Identifier: GPL-2.0
/*
 * BPF filesystem object creation stub.
 * This provides a minimal implementation for BPF program and map creation.
 */

#include <linux/fs.h>
#include <linux/namei.h>
#include <linux/slab.h>

typedef int (*bpf_mknod_t)(struct inode *, struct dentry *, umode_t, dev_t);

int vfs_mkobj(struct dentry *dentry, umode_t mode,
	      bpf_mknod_t mkobj, void *data)
{
	struct inode *dir = dentry->d_parent->d_inode;
	struct inode *inode;
	int error = -EPERM;

	if (!dir || !S_ISDIR(mode))
		return -EINVAL;

	inode = new_inode(dir->i_sb);
	if (!inode)
		return -ENOMEM;

	inode->i_mode = mode;
	inode->i_uid = make_kuid(&init_user_ns, 0);
	inode->i_gid = make_kgid(&init_user_ns, 0);
	inode->i_atime = inode->i_mtime = inode->i_ctime = current_time(inode);

	error = mkobj(inode, dentry, mode, 0);
	if (error) {
		iput(inode);
		return error;
	}

	d_instantiate(dentry, inode);
	return 0;
}
EXPORT_SYMBOL_GPL(vfs_mkobj);
