#include "cchecker.h"

CC_SHORT int next_id(void);
CC_BLOCKING int wait_for(int fd);
CC_HOT int add(int a, int b) { return a + b; }
void adopt(CC_OWNS char *name);
CC_PAIR(mask_signals, restore_signals) int guarded(void);
CC_NO_SYSCALL_UNDER(table_lock) int lookup(int key);
CC_MAY_JUMP int check_type(int value);
CC_NORETURN void fail(void);
CC_JUMPS void raise_error(int code);
CC_STOP void trace(int event);
