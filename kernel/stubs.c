// SPDX-License-Identifier: GPL-2.0
/* Stubs for functions missing in 4.14 backport */
#include <linux/module.h>
#include <linux/sched.h>
#include <linux/mm.h>
#include <linux/kallsyms.h>
#include <linux/pagemap.h>

void __noreturn make_task_dead(int signr)
{
	do_exit(signr);
	__builtin_unreachable();
}
EXPORT_SYMBOL(make_task_dead);

unsigned long randomize_page(unsigned long start, unsigned long range)
{
	return start;
}
EXPORT_SYMBOL(randomize_page);

pgoff_t basepage_index(struct page *page)
{
	return page->index;
}
EXPORT_SYMBOL(basepage_index);

int kallsyms_show_value(void)
{
	return 1;
}
EXPORT_SYMBOL(kallsyms_show_value);
