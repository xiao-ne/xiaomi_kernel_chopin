/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __ASM_STACK_POINTER_H
#define __ASM_STACK_POINTER_H

/*
 * how to get the current stack pointer from C
 */
static inline unsigned long get_current_stack_pointer(void)
{
	unsigned long sp;
	return sp;
}
#define current_stack_pointer get_current_stack_pointer()

#endif /* __ASM_STACK_POINTER_H */
