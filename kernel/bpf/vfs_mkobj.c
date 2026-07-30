// SPDX-License-Identifier: GPL-2.0
/*
 * BPF filesystem object creation.
 * This provides the vfs_mkobj function for BPF program and map creation.
 */

#include <linux/fs.h>
#include <linux/namei.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

typedef int (*bpf_mknod_t)(struct inode *, struct dentry *, umode_t, dev_t);

/**
 * vfs_mkobj - create a filesystem object
 * @dentry: the dentry to create the object in
 * @mode: the mode of the new object
 * @mkobj: function to call to initialize the inode
 * @data: data to pass to mkobj
 *
 * This function creates a new object in the filesystem. It's used by BPF
 * to create BPF programs and maps as filesystem objects.
 *
 * Returns 0 on success or a negative error code on failure.
 */
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
	inode->i_uid = current_fsuid();
	inode->i_gid = current_fsgid();
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
