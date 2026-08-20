// SPDX-License-Identifier: GPL-2.0
/*
 * Minimal BPF stubs - only truly missing functions
 */
#include <linux/bpf.h>
#include <linux/filter.h>
#include <linux/proc_ns.h>

void copy_map_value_locked(struct bpf_map *map, void *dst, void *src,
			   bool lock_src)
{
	/*
	 * Stub: simplified lock-free copy. The full 4.14.186 version in
	 * reset-to-aosp uses ____bpf_spin_lock/unlock around the copy
	 * for BPF_F_LOCK-enabled maps; chopin does not implement
	 * ____bpf_spin_lock/unlock nor BPF_CALL_1(bpf_spin_lock), so the
	 * BPF spin_lock map value path is dead code on this kernel and
	 * a bare memcpy is functionally equivalent.
	 */
	memcpy(dst, src, map->value_size);
}

/* Map ops stubs referenced from bpf_types.h */
const struct bpf_map_ops sk_storage_map_ops = {};
const struct bpf_map_ops dev_map_hash_ops = {};

int skb_flow_dissector_bpf_prog_attach(const union bpf_attr *attr,
				       struct bpf_prog *prog)
{
	return -EINVAL;
}

int skb_flow_dissector_bpf_prog_detach(const union bpf_attr *attr)
{
	return -EINVAL;
}

void *ns_get_path_cb(struct path *path, ns_get_path_helper_t ns_get_cb,
                     void *private_data)
{
	return ERR_PTR(-EINVAL);
}
