// SPDX-License-Identifier: GPL-2.0
/*
 * Stub elfcore.c - provides weak definitions for elf core dump functions.
 * These are needed when CONFIG_ELFCORE is enabled but the actual elfcore
 * support is not fully implemented.
 */

#include <linux/types.h>
#include <linux/mm.h>

/* Weak stubs - these will be overridden if real elfcore support exists */
Elf_Half __weak elf_core_extra_phdrs(void) { return 0; }
int __weak elf_core_write_extra_phdrs(void *cprm, loff_t offset) { return 1; }
int __weak elf_core_write_extra_data(void *cprm) { return 1; }
size_t __weak elf_core_extra_data_size(void) { return 0; }
