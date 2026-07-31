// SPDX-License-Identifier: GPL-2.0
/*
 * Minimal BPF stubs - only truly missing functions
 */
#include <linux/bpf.h>
#include <linux/filter.h>

void copy_map_value_locked(struct bpf_map *map, void *dst, void *src,
			   bool lock_src)
{
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

int ns_get_path_cb(void (*fn)(struct seq_file *, struct ns_common *),
		   struct ns_common *ns, struct seq_file *m)
{
	return -EINVAL;
}
