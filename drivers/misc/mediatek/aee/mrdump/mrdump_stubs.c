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

void mrdump_init(void) {}
EXPORT_SYMBOL_GPL(mrdump_init);

void mrdump_shutdown(void) {}
EXPORT_SYMBOL_GPL(mrdump_shutdown);

void mrdump_rsvmem_init(void) {}
EXPORT_SYMBOL_GPL(mrdump_rsvmem_init);
