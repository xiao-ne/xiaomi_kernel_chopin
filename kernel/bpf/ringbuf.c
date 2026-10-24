// SPDX-License-Identifier: GPL-2.0
/*
 * BPF ring buffer — 从 Linux 5.10 回移到 4.14。
 *
 * 这一版先只包含 map 本身（分配、mmap、poll）和内核侧的 output 路径；
 * reserve/submit/discard 需要 verifier 的 PTR_TO_MEM 支持，随后再加。
 */
#include <linux/bpf.h>
#include <linux/err.h>
#include <linux/irq_work.h>
#include <linux/slab.h>
#include <linux/filter.h>
#include <linux/mm.h>
#include <linux/vmalloc.h>
#include <linux/wait.h>
#include <linux/poll.h>

#define RINGBUF_CREATE_FLAG_MASK (BPF_F_NUMA_NODE)

#define RINGBUF_PGOFF \
	(offsetof(struct bpf_ringbuf, consumer_pos) >> PAGE_SHIFT)
#define RINGBUF_POS_PAGES 2
#define RINGBUF_MAX_RECORD_SZ (UINT_MAX / 4)
#define RINGBUF_MAX_DATA_SZ \
	(((1ULL << 24) - RINGBUF_POS_PAGES - RINGBUF_PGOFF) * PAGE_SIZE)

struct bpf_ringbuf {
	wait_queue_head_t waitq;
	struct irq_work work;
	u64 mask;
	struct page **pages;
	int nr_pages;
	spinlock_t spinlock ____cacheline_aligned_in_smp;
	unsigned long consumer_pos __aligned(PAGE_SIZE);
	unsigned long producer_pos __aligned(PAGE_SIZE);
	unsigned long pending_pos;
	char data[] __aligned(PAGE_SIZE);
};

struct bpf_ringbuf_map {
	struct bpf_map map;
	struct bpf_ringbuf *rb;
};

struct bpf_ringbuf_hdr {
	u32 len;
	u32 pg_off;
};

static struct bpf_ringbuf *bpf_ringbuf_area_alloc(size_t data_sz, int numa_node)
{
	const gfp_t flags = GFP_KERNEL | __GFP_RETRY_MAYFAIL | __GFP_NOWARN |
			    __GFP_ZERO;
	int nr_meta_pages = RINGBUF_PGOFF + RINGBUF_POS_PAGES;
	int nr_data_pages = data_sz >> PAGE_SHIFT;
	int nr_pages = nr_meta_pages + nr_data_pages;
	struct page **pages, *page;
	struct bpf_ringbuf *rb;
	size_t array_size;
	int i;

	array_size = (nr_meta_pages + 2 * nr_data_pages) * sizeof(*pages);
	if (array_size > PAGE_SIZE)
		pages = vmalloc_node(array_size, numa_node);
	else
		pages = kmalloc_node(array_size, flags, numa_node);
	if (!pages)
		return NULL;

	for (i = 0; i < nr_pages; i++) {
		page = alloc_pages_node(numa_node, flags, 0);
		if (!page) {
			nr_pages = i;
			goto err_free_pages;
		}
		pages[i] = page;
		if (i >= nr_meta_pages)
			pages[nr_data_pages + i] = page;
	}

	rb = vmap(pages, nr_meta_pages + 2 * nr_data_pages,
		  VM_MAP | VM_USERMAP, PAGE_KERNEL);
	if (rb) {
		kmemleak_not_leak(pages);
		rb->pages = pages;
		rb->nr_pages = nr_pages;
		return rb;
	}

err_free_pages:
	for (i = 0; i < nr_pages; i++)
		__free_page(pages[i]);
	kvfree(pages);
	return NULL;
}

static void bpf_ringbuf_notify(struct irq_work *work)
{
	struct bpf_ringbuf *rb = container_of(work, struct bpf_ringbuf, work);

	wake_up_all(&rb->waitq);
}

static struct bpf_ringbuf *bpf_ringbuf_alloc(size_t data_sz, int numa_node)
{
	struct bpf_ringbuf *rb;

	rb = bpf_ringbuf_area_alloc(data_sz, numa_node);
	if (!rb)
		return ERR_PTR(-ENOMEM);

	spin_lock_init(&rb->spinlock);
	init_waitqueue_head(&rb->waitq);
	init_irq_work(&rb->work, bpf_ringbuf_notify);

	rb->mask = data_sz - 1;
	rb->consumer_pos = 0;
	rb->producer_pos = 0;
	rb->pending_pos = 0;

	return rb;
}

static struct bpf_map *ringbuf_map_alloc(union bpf_attr *attr)
{
	struct bpf_ringbuf_map *rb_map;

	if (attr->map_flags & ~RINGBUF_CREATE_FLAG_MASK)
		return ERR_PTR(-EINVAL);

	if (attr->key_size || attr->value_size ||
	    !is_power_of_2(attr->max_entries) ||
	    !PAGE_ALIGNED(attr->max_entries))
		return ERR_PTR(-EINVAL);

#ifdef CONFIG_64BIT
	if (attr->max_entries > RINGBUF_MAX_DATA_SZ)
		return ERR_PTR(-E2BIG);
#endif

	rb_map = kzalloc(sizeof(*rb_map), GFP_USER);
	if (!rb_map)
		return ERR_PTR(-ENOMEM);

	bpf_map_init_from_attr(&rb_map->map, attr);

	/* 4.14 的 memlock 计费在 map_create 里按 map->pages 统一做 */
	rb_map->map.pages = round_up(attr->max_entries, PAGE_SIZE) >> PAGE_SHIFT;

	rb_map->rb = bpf_ringbuf_alloc(attr->max_entries, rb_map->map.numa_node);
	if (IS_ERR(rb_map->rb)) {
		kfree(rb_map);
		return ERR_CAST(rb_map->rb);
	}

	return &rb_map->map;
}

static void bpf_ringbuf_free(struct bpf_ringbuf *rb)
{
	struct page **pages = rb->pages;
	int i, nr_pages = rb->nr_pages;

	vunmap(rb);
	for (i = 0; i < nr_pages; i++)
		__free_page(pages[i]);
	kvfree(pages);
}

static void ringbuf_map_free(struct bpf_map *map)
{
	struct bpf_ringbuf_map *rb_map;

	rb_map = container_of(map, struct bpf_ringbuf_map, map);
	bpf_ringbuf_free(rb_map->rb);
	kfree(rb_map);
}

static void *ringbuf_map_lookup_elem(struct bpf_map *map, void *key)
{
	return ERR_PTR(-ENOTSUPP);
}

static int ringbuf_map_update_elem(struct bpf_map *map, void *key, void *value,
				   u64 flags)
{
	return -ENOTSUPP;
}

static int ringbuf_map_delete_elem(struct bpf_map *map, void *key)
{
	return -ENOTSUPP;
}

static int ringbuf_map_get_next_key(struct bpf_map *map, void *key,
				    void *next_key)
{
	return -ENOTSUPP;
}

static int ringbuf_map_mmap(struct bpf_map *map, struct vm_area_struct *vma)
{
	struct bpf_ringbuf_map *rb_map;

	rb_map = container_of(map, struct bpf_ringbuf_map, map);

	if (vma->vm_flags & VM_WRITE) {
		/* allow writable mapping for the consumer_pos only */
		if (vma->vm_pgoff != 0 || vma->vm_end - vma->vm_start != PAGE_SIZE)
			return -EPERM;
	} else {
		vma->vm_flags &= ~VM_MAYWRITE;
	}
	return remap_vmalloc_range(vma, rb_map->rb,
				   vma->vm_pgoff + RINGBUF_PGOFF);
}

static unsigned long ringbuf_avail_data_sz(struct bpf_ringbuf *rb)
{
	unsigned long cons_pos, prod_pos;

	cons_pos = smp_load_acquire(&rb->consumer_pos);
	prod_pos = smp_load_acquire(&rb->producer_pos);
	return prod_pos - cons_pos;
}

static unsigned int ringbuf_map_poll(struct bpf_map *map, struct file *filp,
				     struct poll_table_struct *pts)
{
	struct bpf_ringbuf_map *rb_map;

	rb_map = container_of(map, struct bpf_ringbuf_map, map);
	poll_wait(filp, &rb_map->rb->waitq, pts);

	if (ringbuf_avail_data_sz(rb_map->rb))
		return POLLIN | POLLRDNORM;
	return 0;
}

const struct bpf_map_ops ringbuf_map_ops = {
	.map_alloc = ringbuf_map_alloc,
	.map_free = ringbuf_map_free,
	.map_mmap = ringbuf_map_mmap,
	.map_poll = ringbuf_map_poll,
	.map_lookup_elem = ringbuf_map_lookup_elem,
	.map_update_elem = ringbuf_map_update_elem,
	.map_delete_elem = ringbuf_map_delete_elem,
	.map_get_next_key = ringbuf_map_get_next_key,
};
