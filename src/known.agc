## The library functions whose effects the rules know: those that block, allocate or make a system call. A function
## of the project is judged by its body (or by its annotation), and a library function not listed here by nothing:
## it has no effect.

## The calls that can wait without a bound: on a file, a socket, a child, a lock, a condition or the clock.
export BLOCKING = Set.new([
  "accept",
  "accept4",
  "connect",
  "recv",
  "recvfrom",
  "recvmsg",
  "send",
  "sendto",
  "sendmsg",
  "sendmmsg",
  "recvmmsg",
  "read",
  "write",
  "pread",
  "pwrite",
  "readv",
  "writev",
  "preadv",
  "pwritev",
  "open",
  "openat",
  "creat",
  "fsync",
  "fdatasync",
  "sync",
  "syncfs",
  "msync",
  "flock",
  "lockf",
  "poll",
  "ppoll",
  "select",
  "pselect",
  "epoll_wait",
  "epoll_pwait",
  "sleep",
  "usleep",
  "nanosleep",
  "clock_nanosleep",
  "pause",
  "sigsuspend",
  "sigwait",
  "sigwaitinfo",
  "sigtimedwait",
  "wait",
  "waitpid",
  "waitid",
  "wait3",
  "wait4",
  "system",
  "popen",
  "pclose",
  "fopen",
  "fdopen",
  "freopen",
  "fclose",
  "fflush",
  "fread",
  "fwrite",
  "fgets",
  "fgetc",
  "getc",
  "getchar",
  "fputs",
  "fputc",
  "putc",
  "putchar",
  "puts",
  "printf",
  "fprintf",
  "vprintf",
  "vfprintf",
  "scanf",
  "fscanf",
  "getline",
  "getdelim",
  "perror",
  "getaddrinfo",
  "gethostbyname",
  "gethostbyaddr",
  "getnameinfo",
  "dlopen",
  "msgrcv",
  "msgsnd",
  "semop",
  "semtimedop",
  "mq_receive",
  "mq_send",
  "mq_timedreceive",
  "mq_timedsend",
  "sem_wait",
  "sem_timedwait",
  "sem_clockwait",
  "pthread_join",
  "pthread_timedjoin_np",
  "pthread_mutex_lock",
  "pthread_mutex_timedlock",
  "pthread_mutex_clocklock",
  "pthread_rwlock_rdlock",
  "pthread_rwlock_wrlock",
  "pthread_rwlock_timedrdlock",
  "pthread_rwlock_timedwrlock",
  "pthread_cond_wait",
  "pthread_cond_timedwait",
  "pthread_cond_clockwait",
  "pthread_barrier_wait",
  "pthread_spin_lock",
  "pthread_once",
  "thrd_join",
  "thrd_sleep",
  "mtx_lock",
  "mtx_timedlock",
  "cnd_wait",
  "cnd_timedwait",
  "call_once",
  "uv_run",
  "uv_sleep",
  "uv_thread_join",
  "uv_mutex_lock",
  "uv_rwlock_rdlock",
  "uv_rwlock_wrlock",
  "uv_cond_wait",
  "uv_cond_timedwait",
  "uv_sem_wait",
  "uv_barrier_wait",
  "uv_once",
  "remove",
  "dprintf",
  "vdprintf",
  "fseek",
  "ftell",
  "rewind",
  "sendfile",
  "mkstemp",
  "tmpfile",
  "realpath",
  "dlsym",
  "dlclose",
  "GC_gcollect",
  # libuv's file calls run at once, on the calling thread, when they are given no callback: the rules count one as
  # blocking only when its last argument is NULL or 0.
  "uv_fs_close",
  "uv_fs_open",
  "uv_fs_read",
  "uv_fs_unlink",
  "uv_fs_write",
  "uv_fs_copyfile",
  "uv_fs_mkdir",
  "uv_fs_mkdtemp",
  "uv_fs_mkstemp",
  "uv_fs_rmdir",
  "uv_fs_opendir",
  "uv_fs_closedir",
  "uv_fs_readdir",
  "uv_fs_scandir",
  "uv_fs_stat",
  "uv_fs_fstat",
  "uv_fs_lstat",
  "uv_fs_statfs",
  "uv_fs_rename",
  "uv_fs_fsync",
  "uv_fs_fdatasync",
  "uv_fs_ftruncate",
  "uv_fs_sendfile",
  "uv_fs_access",
  "uv_fs_chmod",
  "uv_fs_fchmod",
  "uv_fs_utime",
  "uv_fs_futime",
  "uv_fs_lutime",
  "uv_fs_link",
  "uv_fs_symlink",
  "uv_fs_readlink",
  "uv_fs_realpath",
  "uv_fs_chown",
  "uv_fs_fchown",
  "uv_fs_lchown",
])

## The calls that take or give back memory of the heap.
export ALLOCATING = Set.new([
  "malloc", "calloc", "realloc", "reallocarray", "free", "aligned_alloc", "posix_memalign", "memalign", "valloc",
  "pvalloc", "strdup", "strndup", "asprintf", "vasprintf", "getline", "getdelim", "open_memstream", "GC_malloc",
  "GC_malloc_atomic", "GC_malloc_uncollectable", "GC_malloc_atomic_uncollectable", "GC_realloc", "GC_free",
  "GC_strdup", "GC_strndup", "GC_debug_malloc", "GC_debug_malloc_atomic", "GC_debug_realloc", "GC_debug_free",
  "realpath", "SSL_new", "SSL_CTX_new", "BIO_new",
])

## The calls that enter the kernel, besides the blocking ones (which all do). An unlock or a signal of a condition is
## one: it wakes a waiter with a futex call.
export SYSTEM = Set.new([
  "close", "lseek", "stat", "fstat", "lstat", "fstatat", "statx", "access", "faccessat", "readlink", "unlink",
  "unlinkat", "rename", "renameat", "mkdir", "mkdirat", "rmdir", "chdir", "fchdir", "getcwd", "truncate", "ftruncate",
  "fallocate", "chmod", "fchmod", "chown", "fchown", "utimensat", "opendir", "readdir", "closedir", "mmap", "munmap",
  "mremap", "mprotect", "madvise", "mlock", "munlock", "brk", "sbrk", "ioctl", "fcntl", "dup", "dup2", "dup3", "pipe",
  "pipe2", "socket", "socketpair", "bind", "listen", "shutdown", "setsockopt", "getsockopt", "getsockname",
  "getpeername", "epoll_create", "epoll_create1", "epoll_ctl", "eventfd", "timerfd_create", "timerfd_settime",
  "signalfd", "inotify_init", "inotify_init1", "inotify_add_watch", "kill", "tgkill", "raise", "sigaction", "signal",
  "sigprocmask", "pthread_sigmask", "sigaltstack", "fork", "vfork", "execve", "execv", "execvp", "execl", "execlp",
  "posix_spawn", "posix_spawnp", "_exit", "getpid", "getppid", "gettid", "syscall", "sched_yield", "prctl", "uname",
  "getrandom", "getrlimit", "setrlimit", "pthread_create", "pthread_kill", "pthread_cond_signal",
  "pthread_cond_broadcast", "pthread_mutex_unlock", "sem_post", "uv_thread_create", "uv_async_send", "uv_cond_signal",
  "uv_cond_broadcast", "uv_mutex_unlock",
])

## The calls that take the lock of their first argument, and wait for it.
export TAKES = Set.new([
  "pthread_mutex_lock", "pthread_spin_lock", "pthread_rwlock_rdlock", "pthread_rwlock_wrlock", "mtx_lock",
  "uv_mutex_lock", "uv_rwlock_rdlock", "uv_rwlock_wrlock", "EnterCriticalSection", "AcquireSRWLockExclusive",
  "AcquireSRWLockShared",
])

## The calls that take the lock of their first argument only when they return 0: in a condition, the lock is held on
## the branch where the call gave 0. The calls of `TAKES` that return a number count as these in a condition.
export TRIES = Set.new([
  "pthread_mutex_trylock", "pthread_spin_trylock", "pthread_rwlock_tryrdlock", "pthread_rwlock_trywrlock",
  "pthread_mutex_timedlock", "pthread_mutex_clocklock", "pthread_rwlock_timedrdlock", "pthread_rwlock_timedwrlock",
  "mtx_trylock", "mtx_timedlock", "uv_mutex_trylock", "uv_rwlock_tryrdlock", "uv_rwlock_trywrlock",
  "pthread_mutex_lock", "pthread_spin_lock", "pthread_rwlock_rdlock", "pthread_rwlock_wrlock", "mtx_lock",
])

## The calls of `TRIES` that never wait for their lock, so a trylock is never out of the lock order.
export NO_WAIT = Set.new([
  "pthread_mutex_trylock", "pthread_spin_trylock", "pthread_rwlock_tryrdlock", "pthread_rwlock_trywrlock",
  "mtx_trylock", "uv_mutex_trylock", "uv_rwlock_tryrdlock", "uv_rwlock_trywrlock",
])

## The calls that release the lock of their first argument.
export DROPS = Set.new([
  "pthread_mutex_unlock", "pthread_spin_unlock", "pthread_rwlock_unlock", "mtx_unlock", "uv_mutex_unlock",
  "uv_rwlock_rdunlock", "uv_rwlock_wrunlock", "LeaveCriticalSection", "ReleaseSRWLockExclusive",
  "ReleaseSRWLockShared",
])

## The calls that wait on a condition with the lock of their second argument, which they give back while they wait.
export WAITS = Set.new([
  "pthread_cond_wait", "pthread_cond_timedwait", "pthread_cond_clockwait", "cnd_wait", "cnd_timedwait", "uv_cond_wait",
  "uv_cond_timedwait", "SleepConditionVariableCS", "SleepConditionVariableSRW",
])

## The calls that never come back, besides those whose type says `noreturn`.
export NORETURN = Set.new([
  "abort", "exit", "_exit", "_Exit", "quick_exit", "longjmp", "siglongjmp", "_longjmp", "pthread_exit", "thrd_exit",
  "__assert_fail", "__builtin_unreachable", "__builtin_trap", "err", "errx", "verr", "verrx",
])

## The calls that return memory of the heap for the caller to free: a pointer that owns gets a new value from them.
export OWNED = Set.new([
  "malloc", "calloc", "realloc", "reallocarray", "aligned_alloc", "memalign", "valloc", "pvalloc", "strdup", "strndup",
])

## The calls that free the memory of their first argument.
export FREES = Set.new(["free"])

## The calls that move the memory of their first argument to the pointer they return; when that pointer is null, the
## first argument still owns it.
export RESIZES = Set.new(["realloc", "reallocarray"])

## The allocators of the Boehm collector whose memory it manages (not the uncollectable ones, which are roots).
export COLLECTED = Set.new([
  "GC_malloc", "GC_malloc_atomic", "GC_realloc", "GC_strdup", "GC_strndup", "GC_malloc_ignore_off_page",
  "GC_malloc_atomic_ignore_off_page", "GC_debug_malloc", "GC_debug_malloc_atomic", "GC_debug_realloc",
  "GC_debug_strdup", "GC_debug_strndup", "GC_debug_malloc_ignore_off_page", "GC_debug_malloc_atomic_ignore_off_page",
  "GC_memalign",
])
