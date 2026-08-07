// SPDX-License-Identifier: GPL-2.0
/*
 * Copyright (c) 2021 MediaTek Inc.
 * Author: Jie Jiang <jie.jiang@mediatek.com>
 */

#include <linux/module.h>

/*
 * Stubs for mrdump functions when CONFIG_MTK_AEE_IPANIC is not enabled.
 * These allow other parts of the AEE subsystem to reference mrdump symbols
 * without linker errors.
 */

/* Stubs are weak so they yield to real implementations in
 * mrdump_mini.o / mrdump_panic.o when both are linked.
 */

void __weak mrdump_init(void) {}
EXPORT_SYMBOL_GPL(mrdump_init);

void __weak mrdump_shutdown(void) {}
EXPORT_SYMBOL_GPL(mrdump_shutdown);

void __weak mrdump_rsvmem_init(void) {}
EXPORT_SYMBOL_GPL(mrdump_rsvmem_init);

void __weak mrdump_mini_add_misc(unsigned long addr, unsigned long size,
				  unsigned long pa, const char *name) {}
EXPORT_SYMBOL_GPL(mrdump_mini_add_misc);

void __weak mrdump_mini_add_hang_raw(unsigned long addr, unsigned long size) {}
EXPORT_SYMBOL_GPL(mrdump_mini_add_hang_raw);

void __weak mrdump_mini_add_extra_misc(unsigned long addr, unsigned long size,
				    const char *name) {}
EXPORT_SYMBOL_GPL(mrdump_mini_add_extra_misc);

void __weak mrdump_common_die(const char *msg) {}
EXPORT_SYMBOL_GPL(mrdump_common_die);
